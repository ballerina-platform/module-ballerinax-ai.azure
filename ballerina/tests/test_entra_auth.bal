// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;
import ballerina/test;
import ballerina/time;
import ballerinax/ai.azure.identity;

// Entra ID (credential) authentication of `OpenAiModelProvider`. A recording mock on its own port captures the
// auth headers of each of the four routes (chat and responses, v1 and legacy), so the tests can assert exactly
// which headers reached the wire in each mode.

const AUTH_MOCK_URL = "http://localhost:8091/openai";
const AUTH_MOCK_URL_V1 = "http://localhost:8091/openai/v1";
const MOCK_SCOPE = "api://mock-audience/.default";
const MOCK_TOKEN = "mock-entra-token";
const UNAUTHORIZED_DEPLOYMENT = "unauthorized-deployment";

const ROUTE_CHAT_LEGACY = "chat-legacy";
const ROUTE_CHAT_V1 = "chat-v1";
const ROUTE_RESPONSES_LEGACY = "responses-legacy";
const ROUTE_RESPONSES_V1 = "responses-v1";

// The auth headers, query and body of the last request seen on one route.
type RecordedAuth record {|
    string? authorization;
    string? apiKey;
    string? apiVersion;
    json body;
|};

isolated map<RecordedAuth> lastAuthByRoute = {};

isolated function recordAuth(string route, http:Request req, string? apiVersion, json body) {
    string|http:HeaderNotFoundError authorization = req.getHeader("Authorization");
    string|http:HeaderNotFoundError apiKey = req.getHeader("api-key");
    RecordedAuth recorded = {
        authorization: authorization is string ? authorization : (),
        apiKey: apiKey is string ? apiKey : (),
        apiVersion,
        body: body.cloneReadOnly()
    };
    lock {
        lastAuthByRoute[route] = recorded.cloneReadOnly();
    }
}

isolated function takeRecordedAuth(string route) returns RecordedAuth|error {
    lock {
        RecordedAuth? recorded = lastAuthByRoute[route];
        if recorded is () {
            return error(string `no request was recorded on route '${route}'`);
        }
        _ = lastAuthByRoute.remove(route);
        return recorded.clone();
    }
}

// Answers a chat request with text, and a `generate` request (which forces the getResults tool) with `4`.
isolated function respondToAuthChat(json payload) returns json =>
    payload.tool_choice is error ? getChatCompletionContentResponse("Hello from the auth mock")
        : getChatCompletionGetResultsResponse("{\"result\": 4}");

isolated function respondToAuthResponses(json payload) returns json =>
    payload.tool_choice is error ? getTestResponsesApiChatResponse("Hello from the auth mock")
        : getResponsesGetResultsResponse("{\"result\": 4}");

listener http:Listener authMockListener = new (8091);

service /openai on authMockListener {
    resource function post deployments/[string deploymentId]/chat/completions(http:Request req,
            string? api\-version = ()) returns json|http:Unauthorized|error {
        json payload = check req.getJsonPayload();
        recordAuth(ROUTE_CHAT_LEGACY, req, api\-version, payload);
        if deploymentId == UNAUTHORIZED_DEPLOYMENT {
            return <http:Unauthorized>{body: {'error: {code: "401", message: "Unauthorized"}}};
        }
        return respondToAuthChat(payload);
    }

    resource function post responses(http:Request req, string? api\-version = ()) returns json|error {
        json payload = check req.getJsonPayload();
        recordAuth(ROUTE_RESPONSES_LEGACY, req, api\-version, payload);
        return respondToAuthResponses(payload);
    }

    resource function post v1/chat/completions(http:Request req, string? api\-version = ()) returns json|error {
        json payload = check req.getJsonPayload();
        recordAuth(ROUTE_CHAT_V1, req, api\-version, payload);
        return respondToAuthChat(payload);
    }

    resource function post v1/responses(http:Request req, string? api\-version = ()) returns json|error {
        json payload = check req.getJsonPayload();
        recordAuth(ROUTE_RESPONSES_V1, req, api\-version, payload);
        return respondToAuthResponses(payload);
    }
}

# A `TokenCredential` that returns a fixed token and records the scopes it was asked for.
isolated class MockCredential {
    *identity:TokenCredential;
    private final string token;
    private string[][] requestedScopes = [];

    isolated function init(string token = MOCK_TOKEN) {
        self.token = token;
    }

    public isolated function getToken(string[] scopes) returns identity:AccessToken|identity:Error {
        lock {
            self.requestedScopes.push(scopes.clone());
        }
        return {token: self.token, expiresOn: time:utcNow()[0] + 3600};
    }

    isolated function lastScopes() returns string[]? {
        lock {
            int count = self.requestedScopes.length();
            return count == 0 ? () : self.requestedScopes[count - 1].clone();
        }
    }
}

# A `TokenCredential` that always fails, the way a real one does when no identity is available.
isolated class FailingCredential {
    *identity:TokenCredential;

    public isolated function getToken(string[] scopes) returns identity:AccessToken|identity:Error =>
        error identity:CredentialUnavailableError("no managed identity endpoint is available",
            credential = "mock");
}

# One provider per route: `[route, serviceUrl, apiVersion, apiType]`.
type RouteCase [string, string, string?, ApiType];

function routeCases() returns RouteCase[] => [
    [ROUTE_CHAT_LEGACY, AUTH_MOCK_URL, API_VERSION, CHAT_COMPLETIONS],
    [ROUTE_CHAT_V1, AUTH_MOCK_URL_V1, (), CHAT_COMPLETIONS],
    [ROUTE_RESPONSES_LEGACY, AUTH_MOCK_URL, API_VERSION, RESPONSES],
    [ROUTE_RESPONSES_V1, AUTH_MOCK_URL_V1, (), RESPONSES]
];

// ===== Credential mode: Bearer on all four routes, no api-key =====

@test:Config {groups: ["entra-auth"]}
function testCredentialSendsBearerAndNoApiKeyOnAllRoutes() returns error? {
    foreach RouteCase [route, url, apiVersion, apiType] in routeCases() {
        MockCredential credential = new;
        OpenAiModelProvider provider = check new (url, credential, DEPLOYMENT_ID, apiVersion, apiType = apiType,
            tokenScope = MOCK_SCOPE);

        ai:ChatAssistantMessage reply = check provider->chat([{role: ai:USER, content: "Hi"}]);
        test:assertTrue((reply.content ?: "").includes("Hello from the auth mock"), route);
        RecordedAuth chatAuth = check takeRecordedAuth(route);
        test:assertEquals(chatAuth.authorization, "Bearer " + MOCK_TOKEN, route + ": chat");
        test:assertEquals(chatAuth.apiKey, (), route + ": chat must not send api-key");
        test:assertEquals(credential.lastScopes(), [MOCK_SCOPE], route);

        // `generate` goes through the native Generator, which reads the provider's fields by name.
        int rating = check provider->generate(`Rate this out of 10.`);
        test:assertEquals(rating, 4, route);
        RecordedAuth generateAuth = check takeRecordedAuth(route);
        test:assertEquals(generateAuth.authorization, "Bearer " + MOCK_TOKEN, route + ": generate");
        test:assertEquals(generateAuth.apiKey, (), route + ": generate must not send api-key");
    }
}

@test:Config {groups: ["entra-auth"]}
function testCredentialV1RoutesKeepTheConnectorWireShape() returns error? {
    MockCredential credential = new;
    OpenAiModelProvider chatProvider = check new (AUTH_MOCK_URL_V1, credential, DEPLOYMENT_ID, "preview",
        tokenScope = MOCK_SCOPE);
    _ = check chatProvider->chat([{role: ai:USER, content: "Hi"}]);
    RecordedAuth chat = check takeRecordedAuth(ROUTE_CHAT_V1);
    test:assertEquals(chat.apiVersion, "preview", "an opted-in v1 api-version is forwarded");
    test:assertEquals(check chat.body.model, DEPLOYMENT_ID, "the deployment is sent as 'model' on v1");
    test:assertTrue(chat.body.max_completion_tokens !is error, "v1 sends 'max_completion_tokens'");

    OpenAiModelProvider responsesProvider = check new (AUTH_MOCK_URL_V1, credential, DEPLOYMENT_ID,
        apiType = RESPONSES, tokenScope = MOCK_SCOPE);
    _ = check responsesProvider->chat([{role: ai:USER, content: "Hi"}]);
    RecordedAuth responses = check takeRecordedAuth(ROUTE_RESPONSES_V1);
    test:assertEquals(responses.apiVersion, (), "no api-version unless one is opted into");
    test:assertEquals(check responses.body.model, DEPLOYMENT_ID);
}

// ===== API-key mode: unchanged, including on hosts that have no derivable scope =====

@test:Config {groups: ["entra-auth"]}
function testApiKeySendsApiKeyAndNoAuthorizationOnAllRoutes() returns error? {
    // The mock is on localhost, which has no derivable token scope: with an API key that must not matter.
    foreach RouteCase [route, url, apiVersion, apiType] in routeCases() {
        OpenAiModelProvider provider = check new (url, API_KEY, DEPLOYMENT_ID, apiVersion, apiType = apiType);

        _ = check provider->chat([{role: ai:USER, content: "Hi"}]);
        RecordedAuth chatAuth = check takeRecordedAuth(route);
        test:assertEquals(chatAuth.apiKey, API_KEY, route + ": chat");
        test:assertEquals(chatAuth.authorization, (), route + ": chat must not send Authorization");

        int rating = check provider->generate(`Rate this out of 10.`);
        test:assertEquals(rating, 4, route);
        RecordedAuth generateAuth = check takeRecordedAuth(route);
        test:assertEquals(generateAuth.apiKey, API_KEY, route + ": generate");
        test:assertEquals(generateAuth.authorization, (), route + ": generate must not send Authorization");
    }
}

@test:Config {groups: ["entra-auth"]}
function testApiKeyInitsOnHostsWithoutADerivableScope() returns error? {
    // Initialisation makes no network call, so unreachable hosts are fine here.
    [string, string?][] urls = [
        ["https://my-gateway.azure-api.net/openai", API_VERSION],
        ["https://my-gateway.azure-api.net/openai/v1", ()],
        ["https://llm.example.com/azure-openai", API_VERSION],
        ["http://localhost:9999/openai/v1", ()]
    ];
    ApiType[] apiTypes = [CHAT_COMPLETIONS, RESPONSES];
    foreach [string, string?] [url, apiVersion] in urls {
        foreach ApiType apiType in apiTypes {
            OpenAiModelProvider|ai:Error provider = new (url, API_KEY, DEPLOYMENT_ID, apiVersion, apiType = apiType);
            test:assertTrue(provider is OpenAiModelProvider, string `API key on ${url} must init`);

            // The same URL with a credential has no default scope and must ask for 'tokenScope'.
            OpenAiModelProvider|ai:Error withCredential = new (url, new MockCredential(), DEPLOYMENT_ID,
                apiVersion, apiType = apiType);
            if withCredential !is ai:Error {
                test:assertFail(string `a credential on ${url} without 'tokenScope' must fail`);
            }
            test:assertTrue(withCredential.message().includes("tokenScope"), withCredential.message());
        }
    }
}

// ===== Token scope =====

@test:Config {groups: ["entra-auth"]}
function testDeriveTokenScope() {
    string cognitiveServices = "https://cognitiveservices.azure.com/.default";
    [string, string?][] cases = [
        ["https://res.openai.azure.com/openai/v1", cognitiveServices],
        ["https://res.openai.azure.com/openai", cognitiveServices],
        ["https://res.openai.azure.com", cognitiveServices],
        ["https://res.cognitiveservices.azure.com/", cognitiveServices],
        ["https://res.services.ai.azure.com/openai/v1", cognitiveServices],
        ["HTTPS://RES.OpenAI.Azure.COM/openai", cognitiveServices],
        ["https://res.openai.azure.com:443/openai", cognitiveServices],
        ["https://res.services.ai.azure.com/api/projects/demo/openai/v1", "https://ai.azure.com/.default"],
        ["https://res.services.ai.azure.com/API/Projects/demo", "https://ai.azure.com/.default"],
        ["https://svc.search.windows.net", "https://search.azure.com/.default"],
        ["https://res.openai.azure.us/openai", "https://cognitiveservices.azure.us/.default"],
        // No default: gateways, custom domains, local endpoints and look-alike hosts.
        ["https://my-gateway.azure-api.net/openai", ()],
        ["https://llm.example.com/openai/v1", ()],
        ["http://localhost:8080/openai/v1", ()],
        ["https://openai.azure.com.example.net/openai", ()],
        ["https://example.net/openai?host=res.openai.azure.com", ()],
        ["https://example.net/#res.openai.azure.com", ()],
        ["https://openai.azure.com/openai", ()]
    ];
    foreach [string, string?] [url, expected] in cases {
        string|ai:Error scope = deriveTokenScope(url);
        if expected is string {
            test:assertEquals(scope, expected, url);
        } else {
            test:assertTrue(scope is ai:Error, string `'${url}' must have no default scope`);
        }
    }
}

@test:Config {groups: ["entra-auth"]}
function testTokenScopeOverridesTheDerivedScope() returns error? {
    test:assertEquals(check resolveTokenScope("https://res.openai.azure.com/openai/v1", "https://ai.azure.com/.default"),
        "https://ai.azure.com/.default");
    test:assertEquals(check resolveTokenScope("https://gw.azure-api.net/openai", " api://gw/.default "),
        "api://gw/.default");
    string|ai:Error blank = resolveTokenScope("https://res.openai.azure.com/openai", " ");
    test:assertTrue(blank is ai:Error, "a blank 'tokenScope' must be rejected");
}

@test:Config {groups: ["entra-auth"]}
function testDerivedScopeIsRequestedFromTheCredential() returns error? {
    [string, string][] cases = [
        ["https://res.openai.azure.com/openai/v1", "https://cognitiveservices.azure.com/.default"],
        ["https://res.services.ai.azure.com/api/projects/demo/openai/v1", "https://ai.azure.com/.default"]
    ];
    foreach [string, string] [url, expected] in cases {
        MockCredential credential = new;
        string|BearerAuth auth = check resolveAuth(credential, url, {});
        if auth is string {
            return error("a credential must resolve to bearer authentication");
        }
        _ = check auth.headers();
        test:assertEquals(credential.lastScopes(), [expected], url);
    }
}

// ===== Credential configuration =====

@test:Config {groups: ["entra-auth"]}
function testCredentialConfigInitMakesNoNetworkCall() returns error? {
    // Nothing listens on these hosts; a credential configuration is only resolved on the first request.
    _ = check new OpenAiModelProvider("https://res.openai.azure.com/openai/v1", {'type: "managedIdentity"},
        DEPLOYMENT_ID);
    _ = check new OpenAiModelProvider("https://res.openai.azure.com/openai", {'type: "default"}, DEPLOYMENT_ID,
        API_VERSION, apiType = RESPONSES);
}

@test:Config {groups: ["entra-auth"]}
function testCredentialConfigErrorsAtInit() {
    OpenAiModelProvider|ai:Error notImplemented = new ("https://res.openai.azure.com/openai/v1",
        {'type: "azureCli"}, DEPLOYMENT_ID);
    if notImplemented !is ai:Error {
        test:assertFail("an unimplemented credential type must fail at init");
    }
    error? cause = notImplemented.cause();
    test:assertTrue(cause is error && cause.message().includes("not implemented yet"),
        notImplemented.toString());

    // TLS options that token requests can't honour are rejected, which shows `secureSocket` reaches the credential.
    OpenAiModelProvider|ai:Error insecure = new ("https://res.openai.azure.com/openai/v1", {'type: "default"},
        DEPLOYMENT_ID, secureSocket = {verifyHostName: false});
    if insecure !is ai:Error {
        test:assertFail("an unsupported secureSocket option must fail at init");
    }
    test:assertTrue(insecure.toString().includes("verifyHostName"), insecure.toString());
}

// ===== No secrets in errors =====

@test:Config {groups: ["entra-auth"]}
function testCredentialFailureIsReportedWithoutSecrets() returns error? {
    OpenAiModelProvider provider = check new (AUTH_MOCK_URL, new FailingCredential(), DEPLOYMENT_ID, API_VERSION,
        tokenScope = MOCK_SCOPE);
    ai:ChatAssistantMessage|ai:Error reply = provider->chat([{role: ai:USER, content: "Hi"}]);
    if reply !is ai:Error {
        return error("a failing credential must fail the request");
    }
    test:assertTrue(reply.toString().includes("Failed to get an Entra ID token for " + MOCK_SCOPE),
        reply.toString());
    // The request never reached the service.
    test:assertTrue(takeRecordedAuth(ROUTE_CHAT_LEGACY) is error);
}

@test:Config {groups: ["entra-auth"]}
function testRejectedTokenIsNotInTheError() returns error? {
    string secretToken = "secret-token-that-must-not-leak";
    OpenAiModelProvider provider = check new (AUTH_MOCK_URL, new MockCredential(secretToken),
        UNAUTHORIZED_DEPLOYMENT, API_VERSION, tokenScope = MOCK_SCOPE);

    ai:ChatAssistantMessage|ai:Error reply = provider->chat([{role: ai:USER, content: "Hi"}]);
    if reply !is ai:Error {
        return error("a 401 must fail the request");
    }
    test:assertFalse(reply.toString().includes(secretToken), "the token must not appear in the error");
    _ = check takeRecordedAuth(ROUTE_CHAT_LEGACY);

    int|ai:Error rating = provider->generate(`Rate this out of 10.`);
    if rating !is ai:Error {
        return error("a 401 must fail generate");
    }
    test:assertFalse(rating.toString().includes(secretToken), "the token must not appear in the error");
    _ = check takeRecordedAuth(ROUTE_CHAT_LEGACY);
}
