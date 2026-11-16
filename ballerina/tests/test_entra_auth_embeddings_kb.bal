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
import ballerinax/azure.ai.search;

// Entra ID (credential) and API-key authentication of `EmbeddingProvider` and `AiSearchKnowledgeBase`, against the
// recording mock of `test_entra_auth.bal`. The Azure AI Search mock below answers the four calls the knowledge base
// makes: get and create the index (service client), and search and index documents (index client).

const SEARCH_MOCK_URL = "http://localhost:8091/search";
const SEARCH_INDEX_NAME = "kb";
const UNAUTHORIZED_INDEX = "unauthorized-index";
const SEARCH_SCOPE_DEFAULT = "https://search.azure.com/.default";
const COGNITIVE_SCOPE_DEFAULT = "https://cognitiveservices.azure.com/.default";

const ROUTE_KB_GET_INDEX = "kb-get-index";
const ROUTE_KB_PUT_INDEX = "kb-put-index";
const ROUTE_KB_SEARCH = "kb-search";
const ROUTE_KB_INDEX_DOCUMENTS = "kb-index-documents";

final readonly & search:SearchIndex mockSearchIndex = {
    name: SEARCH_INDEX_NAME,
    fields: [
        {name: "id", 'type: "Edm.String", 'key: true},
        {name: "content", 'type: "Edm.String", searchable: true}
    ]
};

service /search on authMockListener {
    resource function 'default [string... path](http:Request req, string? api\-version = ())
            returns json|http:Unauthorized|http:NotFound|error {
        string rawPath = req.rawPath;
        int? queryStart = rawPath.indexOf("?");
        string route = queryStart is int ? rawPath.substring(0, queryStart) : rawPath;
        if route.endsWith("/docs/search.post.search") {
            json payload = check req.getJsonPayload();
            recordAuth(ROUTE_KB_SEARCH, req, api\-version, payload);
            return {value: [{"@search.score": 1.0, id: "doc-1", content: "Hello from the search mock"}]};
        }
        if route.endsWith("/docs/search.index") {
            json payload = check req.getJsonPayload();
            recordAuth(ROUTE_KB_INDEX_DOCUMENTS, req, api\-version, payload);
            return {value: [{'key: "doc-1", status: true, statusCode: 200}]};
        }
        if req.method == http:GET {
            recordAuth(ROUTE_KB_GET_INDEX, req, api\-version, ());
            if route.includes(UNAUTHORIZED_INDEX) {
                return <http:Unauthorized>{body: {'error: {code: "401", message: "Unauthorized"}}};
            }
            return mockSearchIndex.toJson();
        }
        if req.method == http:PUT {
            json payload = check req.getJsonPayload();
            recordAuth(ROUTE_KB_PUT_INDEX, req, api\-version, payload);
            return payload;
        }
        return <http:NotFound>{};
    }
}

function assertBearer(string route, string label, string token = MOCK_TOKEN) returns error? {
    RecordedAuth auth = check takeRecordedAuth(route);
    test:assertEquals(auth.authorization, "Bearer " + token, label);
    test:assertEquals(auth.apiKey, (), label + " must not send api-key");
}

function assertApiKey(string route, string label) returns error? {
    RecordedAuth auth = check takeRecordedAuth(route);
    test:assertEquals(auth.apiKey, API_KEY, label);
    test:assertEquals(auth.authorization, (), label + " must not send Authorization");
}

# Runs ingest, retrieve and deleteByFilter once, and checks the authentication after each one. The mock keeps only the
# last request per route, and deleteByFilter searches before it deletes, so a later check would see its requests.
#
# + kb - The knowledge base, already initialised
# + assertAuth - Checks the authentication of the last request on a route
# + return - An error if an operation fails
function exerciseKnowledgeBase(AiSearchKnowledgeBase kb,
        function (string route, string label) returns error? assertAuth) returns error? {
    check kb.ingest([<ai:TextChunk>{content: "Hello"}]);
    check assertAuth(ROUTE_KB_INDEX_DOCUMENTS, "ingest");
    ai:QueryMatch[] matches = check kb.retrieve("Hello");
    test:assertEquals(matches.length(), 1);
    test:assertEquals(matches[0].chunk.content, "Hello from the search mock");
    check assertAuth(ROUTE_KB_SEARCH, "retrieve");
    check kb.deleteByFilter({filters: [{'key: "id", value: "doc-1"}]});
    check assertAuth(ROUTE_KB_SEARCH, "deleteByFilter search");
    check assertAuth(ROUTE_KB_INDEX_DOCUMENTS, "deleteByFilter delete");
}

// ===== EmbeddingProvider: credential and API key on both routes =====

// One provider per route: `[route, serviceUrl, apiVersion]`.
function embeddingRouteCases() returns [string, string, string?][] => [
    [ROUTE_EMBEDDINGS_LEGACY, AUTH_MOCK_URL, API_VERSION],
    [ROUTE_EMBEDDINGS_V1, AUTH_MOCK_URL_V1, ()]
];

@test:Config {groups: ["entra-auth"]}
function testEmbeddingCredentialSendsBearerAndNoApiKeyOnBothRoutes() returns error? {
    foreach [string, string, string?] [route, url, apiVersion] in embeddingRouteCases() {
        MockCredential credential = new;
        EmbeddingProvider provider = check new (url, credential, apiVersion, DEPLOYMENT_ID, tokenScope = MOCK_SCOPE);

        ai:Embedding embedding = check provider->embed(<ai:TextChunk>{content: "Hello"});
        test:assertTrue(embedding is ai:Vector, route);
        check assertBearer(route, route + ": embed");
        test:assertEquals(credential.lastScopes(), [MOCK_SCOPE], route);

        ai:Embedding[] embeddings = check provider->batchEmbed([<ai:TextChunk>{content: "a"},
            <ai:TextChunk>{content: "b"}]);
        test:assertEquals(embeddings.length(), 2, route);
        check assertBearer(route, route + ": batchEmbed");
    }
}

@test:Config {groups: ["entra-auth"]}
function testEmbeddingCredentialLegacyRouteKeepsTheConnectorWireShape() returns error? {
    EmbeddingProvider provider = check new (AUTH_MOCK_URL, new MockCredential(), API_VERSION, DEPLOYMENT_ID,
        tokenScope = MOCK_SCOPE);
    _ = check provider->embed(<ai:TextChunk>{content: "Hello"});
    RecordedAuth legacy = check takeRecordedAuth(ROUTE_EMBEDDINGS_LEGACY);
    test:assertEquals(legacy.apiVersion, API_VERSION, "the api-version is forwarded on the legacy route");
    test:assertEquals(legacy.body, {input: "Hello"}, "no 'model' on the legacy route (the deployment is in the URL)");
}

@test:Config {groups: ["entra-auth"]}
function testEmbeddingApiKeySendsApiKeyAndNoAuthorizationOnBothRoutes() returns error? {
    // The mock is on localhost, which has no derivable token scope: with an API key that must not matter.
    foreach [string, string, string?] [route, url, apiVersion] in embeddingRouteCases() {
        EmbeddingProvider provider = check new (url, API_KEY, apiVersion, DEPLOYMENT_ID);
        _ = check provider->embed(<ai:TextChunk>{content: "Hello"});
        check assertApiKey(route, route + ": embed");
        _ = check provider->batchEmbed([<ai:TextChunk>{content: "a"}, <ai:TextChunk>{content: "b"}]);
        check assertApiKey(route, route + ": batchEmbed");
    }
}

// ===== AiSearchKnowledgeBase: credential and API key on every call =====

@test:Config {groups: ["entra-auth"]}
function testKnowledgeBaseCredentialSendsBearerAndNoApiKeyOnEveryCall() returns error? {
    MockCredential credential = new;
    AiSearchKnowledgeBase kb = check new (SEARCH_MOCK_URL, credential, SEARCH_INDEX_NAME, chunker = ai:DISABLE,
        tokenScope = MOCK_SCOPE);
    check assertBearer(ROUTE_KB_GET_INDEX, "get index");
    test:assertEquals(credential.lastScopes(), [MOCK_SCOPE]);

    check exerciseKnowledgeBase(kb, (route, label) => assertBearer(route, label));

    // Creating the index goes through the service client as well.
    _ = check new AiSearchKnowledgeBase(SEARCH_MOCK_URL, credential, mockSearchIndex, chunker = ai:DISABLE,
        tokenScope = MOCK_SCOPE);
    check assertBearer(ROUTE_KB_PUT_INDEX, "create index");
}

@test:Config {groups: ["entra-auth"]}
function testKnowledgeBaseApiKeySendsApiKeyAndNoAuthorizationOnEveryCall() returns error? {
    AiSearchKnowledgeBase kb = check new (SEARCH_MOCK_URL, API_KEY, SEARCH_INDEX_NAME, chunker = ai:DISABLE);
    check assertApiKey(ROUTE_KB_GET_INDEX, "get index");

    check exerciseKnowledgeBase(kb, assertApiKey);

    _ = check new AiSearchKnowledgeBase(SEARCH_MOCK_URL, API_KEY, mockSearchIndex, chunker = ai:DISABLE);
    check assertApiKey(ROUTE_KB_PUT_INDEX, "create index");
}

// ===== The `auth` parameter by name =====

@test:Config {groups: ["entra-auth"]}
function testAuthCanBePassedByName() returns error? {
    OpenAiModelProvider model = check new (serviceUrl = AUTH_MOCK_URL, auth = API_KEY, deploymentId = DEPLOYMENT_ID,
        apiVersion = API_VERSION);
    _ = check model->chat([{role: ai:USER, content: "Hi"}]);
    check assertApiKey(ROUTE_CHAT_LEGACY, "model provider");

    EmbeddingProvider embeddings = check new (serviceUrl = AUTH_MOCK_URL_V1, auth = new MockCredential(),
        apiVersion = (), deploymentId = DEPLOYMENT_ID, tokenScope = MOCK_SCOPE);
    _ = check embeddings->embed(<ai:TextChunk>{content: "Hello"});
    check assertBearer(ROUTE_EMBEDDINGS_V1, "embedding provider");

    _ = check new AiSearchKnowledgeBase(serviceUrl = SEARCH_MOCK_URL, auth = API_KEY, index = SEARCH_INDEX_NAME);
    check assertApiKey(ROUTE_KB_GET_INDEX, "knowledge base");
}

// ===== Token scope per host, and the override =====

// A credential that fails reports the scope it was asked for, and does so before any request is sent, so these
// tests can use real Azure host names without making a network call.

function tokenScopeOf(error err) returns string {
    string described = err.toString();
    string marker = "Failed to get an Entra ID token for ";
    int? index = described.indexOf(marker);
    if index is () {
        return described;
    }
    string rest = described.substring(index + marker.length());
    int end = rest.indexOf("\"") ?: rest.length();
    return rest.substring(0, end);
}

@test:Config {groups: ["entra-auth"]}
function testEmbeddingTokenScopePerHostAndOverride() returns error? {
    [string, string?, string?, string][] cases = [
        ["https://res.openai.azure.com/openai", API_VERSION, (), COGNITIVE_SCOPE_DEFAULT],
        ["https://res.openai.azure.com/openai/v1", (), (), COGNITIVE_SCOPE_DEFAULT],
        ["https://res.cognitiveservices.azure.com/openai", API_VERSION, (), COGNITIVE_SCOPE_DEFAULT],
        ["https://res.services.ai.azure.com/api/projects/demo/openai/v1", (), (), "https://ai.azure.com/.default"],
        ["https://res.openai.azure.com/openai/v1", (), MOCK_SCOPE, MOCK_SCOPE]
    ];
    foreach [string, string?, string?, string] [url, apiVersion, tokenScope, expected] in cases {
        EmbeddingProvider provider = tokenScope is string
            ? check new (url, new FailingCredential(), apiVersion, DEPLOYMENT_ID, tokenScope = tokenScope)
            : check new (url, new FailingCredential(), apiVersion, DEPLOYMENT_ID);
        ai:Embedding|ai:Error embedding = provider->embed(<ai:TextChunk>{content: "Hello"});
        if embedding !is ai:Error {
            return error(string `a failing credential must fail the request on ${url}`);
        }
        test:assertEquals(tokenScopeOf(embedding), expected, url);
    }
}

@test:Config {groups: ["entra-auth"]}
function testKnowledgeBaseTokenScopePerHostAndOverride() {
    [string?, string][] cases = [
        [(), SEARCH_SCOPE_DEFAULT],
        [MOCK_SCOPE, MOCK_SCOPE]
    ];
    foreach [string?, string] [tokenScope, expected] in cases {
        AiSearchKnowledgeBase|ai:Error kb = new ("https://svc.search.windows.net", new FailingCredential(),
            SEARCH_INDEX_NAME, tokenScope = tokenScope);
        if kb !is ai:Error {
            test:assertFail("a failing credential must fail the first request");
        }
        test:assertEquals(tokenScopeOf(kb), expected);
    }
}

@test:Config {groups: ["entra-auth"]}
function testCredentialWithoutADerivableScopeAsksForTokenScope() {
    EmbeddingProvider|ai:Error embeddings = new (AUTH_MOCK_URL, new MockCredential(), API_VERSION, DEPLOYMENT_ID);
    if embeddings !is ai:Error {
        test:assertFail("a credential on localhost without 'tokenScope' must fail");
    }
    test:assertTrue(embeddings.message().includes("tokenScope"), embeddings.message());

    // The knowledge base checks this before its first request.
    AiSearchKnowledgeBase|ai:Error kb = new (SEARCH_MOCK_URL, new MockCredential(), SEARCH_INDEX_NAME);
    if kb !is ai:Error {
        test:assertFail("a credential on localhost without 'tokenScope' must fail");
    }
    test:assertTrue(kb.message().includes("tokenScope"), kb.message());
    test:assertTrue(takeRecordedAuth(ROUTE_KB_GET_INDEX) is error, "no request without a scope");
}

// ===== Service URL scheme =====

@test:Config {groups: ["entra-auth"]}
function testEmbeddingAndKnowledgeBaseCredentialRejectHttpToARemoteHost() {
    string[] urls = ["http://res.openai.azure.com/openai", "http://user:url-s3cr3t@svc.search.windows.net",
        "http://10.0.0.5:8080/openai/v1"];
    foreach string url in urls {
        EmbeddingProvider|ai:Error embeddings = new (url, new MockCredential(), API_VERSION, DEPLOYMENT_ID,
            tokenScope = MOCK_SCOPE);
        AiSearchKnowledgeBase|ai:Error kb = new (url, {'type: "managedIdentity"}, SEARCH_INDEX_NAME,
            tokenScope = MOCK_SCOPE);
        foreach ai:Error|EmbeddingProvider|AiSearchKnowledgeBase result in [embeddings, kb] {
            if result !is ai:Error {
                test:assertFail(string `a credential on ${url} must be rejected`);
            }
            test:assertTrue(result.message().startsWith(
                "Entra ID authentication requires an 'https://' service URL"), result.message());
            test:assertFalse(result.toString().includes("url-s3cr3t"), "the URL's user info must not leak");
        }
    }
}

@test:Config {groups: ["entra-auth"]}
function testEmbeddingCredentialAcceptsHttpsAndLoopbackHttp() {
    // Initialisation makes no network call, so unreachable hosts are fine here.
    string[] urls = ["https://res.openai.azure.com/openai/v1", "http://localhost:9999/openai",
        "http://127.0.0.1:9999/openai/v1", "http://[::1]:9999/openai"];
    foreach string url in urls {
        EmbeddingProvider|ai:Error embeddings = new (url, {'type: "managedIdentity"}, API_VERSION, DEPLOYMENT_ID,
            tokenScope = MOCK_SCOPE);
        test:assertTrue(embeddings is EmbeddingProvider, string `a credential on ${url} must init`);
    }
}

@test:Config {groups: ["entra-auth"]}
function testEmbeddingApiKeyStillAcceptsHttpToARemoteHost() {
    EmbeddingProvider|ai:Error provider = new ("http://res.openai.azure.com/openai", API_KEY, API_VERSION,
        DEPLOYMENT_ID);
    test:assertTrue(provider is EmbeddingProvider, "API-key mode must not check the URL scheme");
}

// ===== No secrets in errors =====

@test:Config {groups: ["entra-auth"]}
function testEmbeddingAndKnowledgeBaseErrorsCarryNoSecrets() returns error? {
    string secretToken = "secret-token-that-must-not-leak";
    EmbeddingProvider embeddings = check new (AUTH_MOCK_URL, new MockCredential(secretToken), API_VERSION,
        UNAUTHORIZED_DEPLOYMENT, tokenScope = MOCK_SCOPE);
    ai:Embedding|ai:Error embedding = embeddings->embed(<ai:TextChunk>{content: "Hello"});
    if embedding !is ai:Error {
        return error("a 401 must fail the request");
    }
    test:assertFalse(embedding.toString().includes(secretToken), "the token must not appear in the error");
    _ = check takeRecordedAuth(ROUTE_EMBEDDINGS_LEGACY);

    AiSearchKnowledgeBase|ai:Error kb = new (SEARCH_MOCK_URL, new MockCredential(secretToken), UNAUTHORIZED_INDEX,
        tokenScope = MOCK_SCOPE);
    if kb !is ai:Error {
        return error("a 401 must fail the knowledge base");
    }
    test:assertFalse(kb.toString().includes(secretToken), "the token must not appear in the error");
    _ = check takeRecordedAuth(ROUTE_KB_GET_INDEX);

    // A failing credential is reported without sending a request.
    AiSearchKnowledgeBase|ai:Error failing = new (SEARCH_MOCK_URL, new FailingCredential(), SEARCH_INDEX_NAME,
        tokenScope = MOCK_SCOPE);
    if failing !is ai:Error {
        return error("a failing credential must fail the knowledge base");
    }
    test:assertTrue(failing.toString().includes("Failed to get an Entra ID token for " + MOCK_SCOPE),
        failing.toString());
    test:assertTrue(takeRecordedAuth(ROUTE_KB_GET_INDEX) is error, "no request without a token");
}
