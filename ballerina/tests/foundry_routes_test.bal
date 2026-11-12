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

import ballerina/http;
import ballerina/http.httpscerr;
import ballerina/test;

// Foundry listener tests (Milestone 4: the get, cancel and OpenAPI routes, and error classification).
const FOUNDRY_ROUTES_PORT = 9350;
const FOUNDRY_ROUTES_LOCAL_PORT = 9351;
const FOUNDRY_ROUTES_MISSING_PORT = 9352;
const FOUNDRY_ROUTES_GET_PAYLOAD_PORT = 9353;
const FOUNDRY_ROUTES_UNLINKED_PORT = 9354;
const FOUNDRY_ROUTES_INT_PATH_PORT = 9355;

const ROUTES_CONFIG_SESSION = "routes-config-session";
const UNLINKED_PLATFORM_DETAIL = "FoundryPlatformError: no FoundryInvocationService is linked with the Foundry dispatcher";
const INVALID_PATH_BODY_MESSAGE = "The request path could not be decoded.";

final readonly & map<json> ROUTES_OPENAPI_SPEC = {
    openapi: "3.0.1",
    info: {title: "Routes test agent", version: "1.0.0"},
    paths: {"/invocations": {post: {responses: {"200": {description: "OK"}}}}}
};

// How many times the get and cancel resources ran, so a test can check that a rejected request never
// reached them.
isolated int foundryRouteCalls = 0;

isolated function foundryRouteCallsCount() returns int {
    lock {
        return foundryRouteCalls;
    }
}

isolated function countFoundryRouteCall() {
    lock {
        foundryRouteCalls += 1;
    }
}

// The get and cancel resources, on a listener with a configured session ID and OpenAPI document, and on
// one with neither. The invocation ID picks the outcome.
listener FoundryListener foundryRoutesListener = new (FOUNDRY_ROUTES_PORT, agent = {sessionId: ROUTES_CONFIG_SESSION},
    openApiSpec = ROUTES_OPENAPI_SPEC, gracefulStopTimeout = 0);
listener FoundryListener foundryRoutesLocalListener = new (FOUNDRY_ROUTES_LOCAL_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryRoutesListener, foundryRoutesLocalListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get invocations/[string invocationId](FoundryContext ctx)
            returns json|http:Response|http:BadRequest|stream<json, error?>|error {
        countFoundryRouteCall();
        match invocationId {
            "fail" => {
                return error("secret get detail");
            }
            "panic" => {
                panic error("secret get panic");
            }
            "missing" => {
                return error httpscerr:NotFoundError("no such invocation");
            }
            "unavailable" => {
                return error httpscerr:ServiceUnavailableError("try again later");
            }
            "busy" => {
                http:Response response = new;
                response.statusCode = 503;
                response.setTextPayload("busy");
                return response;
            }
            "bad" => {
                http:BadRequest badRequest = {body: {reason: "bad id"}};
                return badRequest;
            }
            "tagged" => {
                http:Response response = new;
                response.statusCode = 409;
                response.setHeader("x-platform-error-source", "user");
                response.setJsonPayload({reason: "tagged by the agent"});
                return response;
            }
            "taggedError" => {
                return error httpscerr:ConflictError("tagged error", headers = {"x-platform-error-source": "user"});
            }
            "relayed" => {
                // What an http:Client call to another Foundry agent returns when that agent fails.
                return error http:RemoteServerError("the other agent failed", statusCode = 502, body = (), headers = {
                    "x-platform-error-source": ["platform"],
                    "x-platform-error-detail": ["OtherError: its internal detail"],
                    "x-agent-invocation-id": ["other-invocation"],
                    "x-agent-session-id": ["other-session"],
                    "retry-after": ["3"]
                });
            }
            "stream" => {
                // Outside the contract: only `post invocations` may return a stream.
                return [1, 2].toStream();
            }
        }
        return {route: "get", invocationId, context: foundryContextSummary(ctx)};
    }

    resource function post invocations/[string invocationId]/cancel(@http:Payload json? reason, FoundryContext ctx)
            returns json|error {
        countFoundryRouteCall();
        match invocationId {
            "fail" => {
                return error("secret cancel detail");
            }
            "panic" => {
                panic error("secret cancel panic");
            }
            "conflict" => {
                return error httpscerr:ConflictError("already cancelled");
            }
        }
        return {route: "cancel", invocationId, reason, context: foundryContextSummary(ctx)};
    }
}

// A service with only the required resource, and no OpenAPI document.
listener FoundryListener foundryRoutesMissingListener = new (FOUNDRY_ROUTES_MISSING_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryRoutesMissingListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;
}

// A get resource with a payload parameter, which a GET request can't supply.
listener FoundryListener foundryRoutesGetPayloadListener = new (FOUNDRY_ROUTES_GET_PAYLOAD_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryRoutesGetPayloadListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get invocations/[string invocationId](@http:Payload json payload) returns json {
        countFoundryRouteCall();
        return payload;
    }
}

// A get resource whose path parameter is not a string, which the dispatcher can't supply.
listener FoundryListener foundryRoutesIntPathListener = new (FOUNDRY_ROUTES_INT_PATH_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryRoutesIntPathListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get invocations/[int invocationId]() returns json {
        countFoundryRouteCall();
        return {invocationId};
    }
}

final http:Client foundryRoutesClient = check new (string `http://localhost:${FOUNDRY_ROUTES_PORT}`);
final http:Client foundryRoutesLocalClient = check new (string `http://localhost:${FOUNDRY_ROUTES_LOCAL_PORT}`);
final http:Client foundryRoutesMissingClient = check new (string `http://localhost:${FOUNDRY_ROUTES_MISSING_PORT}`);
final http:Client foundryRoutesGetPayloadClient =
    check new (string `http://localhost:${FOUNDRY_ROUTES_GET_PAYLOAD_PORT}`);
final http:Client foundryRoutesIntPathClient = check new (string `http://localhost:${FOUNDRY_ROUTES_INT_PATH_PORT}`);

// ===== Get and cancel =====

@test:Config {groups: ["foundry"]}
function testFoundryGetInvocation() returns error? {
    http:Response response = check foundryRoutesClient->get("/invocations/inv-1?agent_session_id=query-session",
        {"x-agent-user-id": "user-1", "x-test-header": "seen"});
    test:assertEquals(response.statusCode, 200);
    json body = check response.getJsonPayload();
    test:assertEquals(check body.route, "get");
    test:assertEquals(check body.invocationId, "inv-1");
    map<json> context = check contextOf(response);
    test:assertEquals(context["invocationId"], "inv-1");
    test:assertEquals(context["sessionId"], "query-session");
    test:assertEquals(context["userId"], "user-1");
    test:assertEquals(context["testHeader"], "seen");
    map<json> agent = check context["agent"].ensureType();
    test:assertEquals(agent["sessionId"], ROUTES_CONFIG_SESSION);
    assertGetOrCancelHeaders(response, "inv-1");
    test:assertFalse(response.hasHeader("x-platform-error-source"));
}

@test:Config {groups: ["foundry"]}
function testFoundryCancelInvocation() returns error? {
    http:Response response = check foundryRoutesClient->post("/invocations/inv-2/cancel?agent_session_id=query-session",
        {why: "user asked"});
    test:assertEquals(response.statusCode, 200);
    json body = check response.getJsonPayload();
    test:assertEquals(check body.route, "cancel");
    test:assertEquals(check body.invocationId, "inv-2");
    test:assertEquals(check body.reason, {why: "user asked"});
    map<json> context = check contextOf(response);
    test:assertEquals(context["invocationId"], "inv-2");
    test:assertEquals(context["sessionId"], "query-session");
    assertGetOrCancelHeaders(response, "inv-2");
    test:assertFalse(response.hasHeader("x-platform-error-source"));

    // The payload parameter is optional (`json?`): an empty body binds to nil.
    response = check foundryRoutesClient->post("/invocations/inv-3/cancel", new http:Request());
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check (check response.getJsonPayload()).reason, ());
    assertGetOrCancelHeaders(response, "inv-3");
}

@test:Config {groups: ["foundry"]}
function testFoundryCancelPayloadBindingError() returns error? {
    int callsBefore = foundryRouteCallsCount();
    http:Response response = check foundryRoutesClient->post("/invocations/inv-4/cancel", "not json");
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "invalid_request", message: "The request body is not valid JSON."}});
    test:assertEquals(check response.getHeader("x-platform-error-source"), "user");
    test:assertFalse(response.hasHeader("x-platform-error-detail"));
    assertGetOrCancelHeaders(response, "inv-4");
    test:assertEquals(foundryRouteCallsCount(), callsBefore, "the cancel resource was called");
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelSessionId() returns error? {
    // The query parameter, else the configured session ID, else "".
    test:assertEquals(check getContextSessionId(foundryRoutesClient, "/invocations/s1?agent_session_id=q-1"), "q-1");
    test:assertEquals(check getContextSessionId(foundryRoutesClient, "/invocations/s1"), ROUTES_CONFIG_SESSION);
    test:assertEquals(check getContextSessionId(foundryRoutesClient, "/invocations/s1?agent_session_id="),
            ROUTES_CONFIG_SESSION);
    test:assertEquals(check getContextSessionId(foundryRoutesLocalClient, "/invocations/s1"), "");
    test:assertEquals(check getContextSessionId(foundryRoutesLocalClient, "/invocations/s1?agent_session_id=q-2"),
            "q-2");
    // An invalid value becomes "", without falling back to the configured session ID or a new UUID.
    test:assertEquals(check getContextSessionId(foundryRoutesClient, "/invocations/s1?agent_session_id=bad%21id"), "");
    test:assertEquals(check getContextSessionId(foundryRoutesLocalClient, "/invocations/s1?agent_session_id=a,b"), "");

    http:Response response = check foundryRoutesLocalClient->post("/invocations/s2/cancel", {});
    test:assertEquals((check contextOf(response))["sessionId"], "");
    assertGetOrCancelHeaders(response, "s2");
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelInvalidButSafeInvocationId() returns error? {
    // An ID that fails validation is still the invocation ID (`_sanitize_id(raw, raw)`), and it is sent
    // back unchanged when it is a valid header value.
    string tooLong = string:'join("", ...from int i in 0 ..< 300 select "a");
    foreach [string, string] [path, expected] in [["inv!1", "inv!1"], ["inv%20one", "inv one"], [tooLong, tooLong]] {
        http:Response response = check foundryRoutesClient->get("/invocations/" + path);
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals(check (check response.getJsonPayload()).invocationId, expected, path);
        test:assertEquals((check contextOf(response))["invocationId"], expected, path);
        assertGetOrCancelHeaders(response, expected);

        response = check foundryRoutesClient->post(string `/invocations/${path}/cancel`, {});
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals((check contextOf(response))["invocationId"], expected, path);
        assertGetOrCancelHeaders(response, expected);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelUnsafeInvocationId() returns error? {
    // A path value that can't be a header value reaches the resource unchanged, but is left out of the
    // response headers, so it can't inject a header.
    foreach [string, string] [path, expected] in [
            ["a%0D%0Ax-injected:%20yes", "a\r\nx-injected: yes"],
            ["line%0Abreak", "line\nbreak"],
            ["%E6%97%A5%E6%9C%AC", "日本"],
            ["tab%09", "tab\t"]
        ] {
        http:Response response = check foundryRoutesClient->get("/invocations/" + path);
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals(check (check response.getJsonPayload()).invocationId, expected, path);
        test:assertEquals((check contextOf(response))["invocationId"], expected, path);
        test:assertFalse(response.hasHeader("x-agent-invocation-id"), path);
        test:assertFalse(response.hasHeader("x-injected"), path);
        test:assertFalse(response.hasHeader("x-agent-session-id"), path);
        assertPlatformServer(response);

        response = check foundryRoutesClient->post(string `/invocations/${path}/cancel`, {});
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals((check contextOf(response))["invocationId"], expected, path);
        test:assertFalse(response.hasHeader("x-agent-invocation-id"), path);
        test:assertFalse(response.hasHeader("x-injected"), path);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelIdDecodedOnce() returns error? {
    // The ID is the path value percent-decoded once, as the reference's ASGI server decodes it, for
    // GET, HEAD and cancel alike: `+` stays `+`, and an escaped `%` stays an escape.
    foreach [string, string] [path, expected] in [["abc%2541", "abc%41"], ["a+b", "a+b"], ["%2525zz", "%25zz"],
            ["inv%2Done", "inv-one"]] {
        http:Response response = check foundryRoutesClient->get("/invocations/" + path);
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals(check (check response.getJsonPayload()).invocationId, expected, path);
        test:assertEquals((check contextOf(response))["invocationId"], expected, path);
        assertGetOrCancelHeaders(response, expected);

        response = check foundryRoutesClient->head("/invocations/" + path);
        test:assertEquals(response.statusCode, 200, path);
        assertGetOrCancelHeaders(response, expected);

        response = check foundryRoutesClient->post(string `/invocations/${path}/cancel`, {});
        test:assertEquals(response.statusCode, 200, path);
        test:assertEquals(check (check response.getJsonPayload()).invocationId, expected, path);
        assertGetOrCancelHeaders(response, expected);
    }
    test:assertEquals(decodePathSegment("a+b%20c%2Fd"), "a+b c/d");
    test:assertEquals(decodePathSegment("%E6%97%A5%zz%4"), "日%zz%4");
    test:assertEquals(decodePathSegment("%FFx"), "\u{FFFD}x");
    test:assertEquals(decodePathSegment("plain"), "plain");
}

@test:Config {groups: ["foundry"]}
function testFoundryUndecodablePath() returns error? {
    // A protocol path that can't be decoded is the caller's mistake: a malformed escape (`%zz`), or an
    // ID that still holds one after its first decoding (`%25zz`, which http decodes twice). HEAD is
    // answered as GET is. The resources are not called.
    int callsBefore = foundryRouteCallsCount();
    foreach [string, string] [method, path] in [["GET", "/invocations/%zz"], ["GET", "/invocations/%25zz"],
            ["POST", "/invocations/%zz/cancel"], ["POST", "/invocations/%25zz/cancel"], ["HEAD", "/invocations/%zz"],
            ["HEAD", "/invocations/%25zz"]] {
        string description = string `${method} ${path}`;
        http:Request request = new;
        request.setHeader("x-request-id", "undecodable");
        http:Response response = check foundryRoutesClient->execute(method, path, request);
        test:assertEquals(response.statusCode, 400, description);
        if method != "HEAD" {
            test:assertEquals(check response.getJsonPayload(),
                    {'error: {code: "invalid_request", message: INVALID_PATH_BODY_MESSAGE}}, description);
        }
        test:assertEquals(check response.getHeader("x-platform-error-source"), "user", description);
        test:assertFalse(response.hasHeader("x-platform-error-detail"), description);
        test:assertFalse(response.hasHeader("x-agent-invocation-id"), description);
        test:assertFalse(response.hasHeader("x-agent-session-id"), description);
        test:assertEquals(check response.getHeader("x-request-id"), "undecodable", description);
        assertPlatformServer(response);
    }
    test:assertEquals(foundryRouteCallsCount(), callsBefore, "a get or cancel resource was called");

    // Another path that can't be decoded names no route, so it is the catch-all's unclassified 404.
    foreach string path in ["/foo/%zz", "/invocations/a/%zz", "/invocations/%zz/other"] {
        http:Response response = check foundryRoutesClient->get(path);
        test:assertEquals(response.statusCode, 404, path);
        test:assertEquals(check response.getJsonPayload(), {'error: {code: "not_found", message: "Not Found"}}, path);
        assertNotClassified(response, path);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelIdHelpers() {
    test:assertEquals(resolveGetOrCancelInvocationId("inv-1"), "inv-1");
    test:assertEquals(resolveGetOrCancelInvocationId("not valid!"), "not valid!");
    test:assertEquals(resolveGetOrCancelSessionId("q", "c"), "q");
    test:assertEquals(resolveGetOrCancelSessionId((), "c"), "c");
    test:assertEquals(resolveGetOrCancelSessionId("", "c"), "c");
    test:assertEquals(resolveGetOrCancelSessionId((), ()), "");
    test:assertEquals(resolveGetOrCancelSessionId("", ""), "");
    test:assertEquals(resolveGetOrCancelSessionId("bad id", "c"), "");
    test:assertEquals(resolveGetOrCancelSessionId((), "bad id"), "");

    foreach string value in ["inv-1", "a b", "x!y", "~"] {
        test:assertTrue(isHeaderSafe(value), value);
    }
    foreach string value in ["", " a", "a ", "\ta", "a\r\nb", "a\nb", "a\u{0}b", "a\u{7F}b", "é", "日本"] {
        test:assertFalse(isHeaderSafe(value), value);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelNotImplemented() returns error? {
    http:Response response = check foundryRoutesMissingClient->get("/invocations/inv-5?agent_session_id=s");
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "not_found", message: "get_invocation not implemented"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "inv-5");

    response = check foundryRoutesMissingClient->post("/invocations/inv-6/cancel", {});
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "not_found", message: "cancel_invocation not implemented"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "inv-6");
}

@test:Config {groups: ["foundry"]}
function testFoundryGetOrCancelInvalidOriginalSubject() returns error? {
    int callsBefore = foundryRouteCallsCount();
    map<string> headers = {"x-ms-original-subject": "oid=unquoted"};
    http:Response getResponse = check foundryRoutesClient->get("/invocations/inv-7?agent_session_id=s", headers);
    http:Response cancelResponse = check foundryRoutesClient->post("/invocations/inv-7/cancel", {}, headers);
    foreach http:Response response in [getResponse, cancelResponse] {
        test:assertEquals(response.statusCode, 400);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "invalid_request", message: "Invalid original-subject platform header."}});
        test:assertEquals(check response.getHeader("x-platform-error-source"), "platform");
        test:assertEquals(check response.getHeader("x-platform-error-detail"), "invalid_original_subject");
        assertGetOrCancelHeaders(response, "inv-7");
    }
    test:assertEquals(foundryRouteCallsCount(), callsBefore, "a get or cancel resource was called");
}

@test:Config {groups: ["foundry"]}
function testFoundryGetWithPayloadParameterIsUnsupported() returns error? {
    int callsBefore = foundryRouteCallsCount();
    http:Response response = check foundryRoutesGetPayloadClient->get("/invocations/inv-8");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "inv-8");
    test:assertEquals(foundryRouteCallsCount(), callsBefore, "the get resource was called");
}

// ===== Routing =====

@test:Config {groups: ["foundry"]}
function testFoundryOpenApiSpec() returns error? {
    http:Response response = check foundryRoutesClient->get("/invocations/docs/openapi.json");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getJsonPayload(), ROUTES_OPENAPI_SPEC);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    test:assertFalse(response.hasHeader("x-agent-invocation-id"));
    test:assertFalse(response.hasHeader("x-agent-session-id"));
    test:assertFalse(response.hasHeader("x-platform-error-source"));
    assertPlatformServer(response);

    response = check foundryRoutesClient->head("/invocations/docs/openapi.json");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertNotClassified(response, "HEAD /invocations/docs/openapi.json");

    response = check foundryRoutesMissingClient->get("/invocations/docs/openapi.json");
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "not_found", message: "No OpenAPI spec registered"}});
    assertUpstreamError(response);
    test:assertFalse(response.hasHeader("x-agent-invocation-id"));
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryDocsPathReachesGetInvocation() returns error? {
    // As in Starlette's route order: only the literal openapi.json path is the OpenAPI route.
    http:Response response = check foundryRoutesClient->get("/invocations/docs");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check (check response.getJsonPayload()).invocationId, "docs");
    assertGetOrCancelHeaders(response, "docs");

    response = check foundryRoutesClient->post("/invocations/docs/cancel", {});
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check (check response.getJsonPayload()).invocationId, "docs");
}

@test:Config {groups: ["foundry"]}
function testFoundryHeadOnGetInvocation() returns error? {
    // Starlette serves HEAD on a GET route by calling the GET endpoint.
    int callsBefore = foundryRouteCallsCount();
    http:Response response = check foundryRoutesClient->head("/invocations/inv-head");
    test:assertEquals(response.statusCode, 200);
    assertGetOrCancelHeaders(response, "inv-head");
    test:assertEquals(foundryRouteCallsCount(), callsBefore + 1);
}

@test:Config {groups: ["foundry"]}
function testFoundryRoutesWrongMethod() returns error? {
    [string, string, string][] cases = [
        ["PUT", "/invocations/inv-9", "GET, HEAD"],
        ["DELETE", "/invocations/inv-9", "GET, HEAD"],
        ["GET", "/invocations/inv-9/cancel", "POST"],
        ["POST", "/invocations/docs/openapi.json", "GET, HEAD"],
        ["GET", "/invocations", "POST"],
        ["POST", "/readiness", "GET, HEAD"]
    ];
    foreach [string, string, string] [method, path, allow] in cases {
        http:Response response = check foundryRoutesClient->execute(method, path, new http:Request());
        test:assertEquals(response.statusCode, 405, string `${method} ${path}`);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "method_not_allowed", message: "Method Not Allowed"}});
        test:assertEquals(check response.getHeader("allow"), allow, string `${method} ${path}`);
        assertNotClassified(response, string `${method} ${path}`);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryNonProtocolNotFoundIsNotClassified() returns error? {
    foreach string path in ["/nothing", "/invocations/a/b", "/invocations/a/b/c/d", "/invocations/docs/other.json/x"] {
        http:Response response = check foundryRoutesClient->get(path);
        test:assertEquals(response.statusCode, 404, path);
        test:assertEquals(check response.getJsonPayload(), {'error: {code: "not_found", message: "Not Found"}}, path);
        assertNotClassified(response, path);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryAllowedMethods() {
    test:assertEquals(allowedMethods(["readiness"]), ["GET", "HEAD"]);
    test:assertEquals(allowedMethods(["invocations"]), ["POST"]);
    test:assertEquals(allowedMethods(["invocations", "x"]), ["GET", "HEAD"]);
    test:assertEquals(allowedMethods(["invocations", "x", "cancel"]), ["POST"]);
    test:assertEquals(allowedMethods(["invocations", "docs", "openapi.json"]), ["GET", "HEAD"]);
    test:assertEquals(allowedMethods(["invocations", "docs", "cancel"]), ["POST"]);
    test:assertEquals(allowedMethods(["invocations", "x", "other"]), ());
    test:assertEquals(allowedMethods(["invocations", "x", "cancel", "y"]), ());
    test:assertEquals(allowedMethods([]), ());
    test:assertEquals(allowedMethods(["other"]), ());
}

// ===== Error classification =====

@test:Config {groups: ["foundry"]}
function testFoundryUserErrorsAreUpstream() returns error? {
    // POST /invocations: an error the resource returns or panics with.
    foreach string kind in ["error", "panic"] {
        http:Response response = check postKind(kind);
        test:assertEquals(response.statusCode, 500, kind);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "internal_error", message: "Internal server error"}}, kind);
        assertUpstreamError(response, kind);
    }
    // Get and cancel.
    foreach string id in ["fail", "panic"] {
        http:Response getResponse = check foundryRoutesClient->get("/invocations/" + id);
        http:Response cancelResponse = check foundryRoutesClient->post(string `/invocations/${id}/cancel`, {});
        foreach http:Response response in [getResponse, cancelResponse] {
            test:assertEquals(response.statusCode, 500, id);
            test:assertEquals(check response.getJsonPayload(),
                    {'error: {code: "internal_error", message: "Internal server error"}}, id);
            test:assertFalse((check response.getTextPayload()).includes("secret"), id);
            assertUpstreamError(response, id);
            assertGetOrCancelHeaders(response, id);
        }
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryStatusCodeErrorsKeepStatus() returns error? {
    http:Response response = check foundryRoutesClient->get("/invocations/missing");
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getJsonPayload(), {'error: {code: "not_found", message: "no such invocation"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "missing");

    response = check foundryRoutesClient->get("/invocations/unavailable");
    test:assertEquals(response.statusCode, 503);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "unavailable");

    response = check foundryRoutesClient->post("/invocations/conflict/cancel", {});
    test:assertEquals(response.statusCode, 409);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "invalid_request", message: "already cancelled"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "conflict");
}

@test:Config {groups: ["foundry"]}
function testFoundryUserErrorResponsesAreUpstream() returns error? {
    // An http:Response and a status-code record the agent returns with a 4xx/5xx status.
    http:Response response = check foundryRoutesClient->get("/invocations/busy");
    test:assertEquals(response.statusCode, 503);
    test:assertEquals(check response.getTextPayload(), "busy");
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "busy");

    response = check foundryRoutesClient->get("/invocations/bad");
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getJsonPayload(), {reason: "bad id"});
    assertUpstreamError(response);

    response = check postKind("badRequest");
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getJsonPayload(), {reason: "bad"});
    assertUpstreamError(response);

    // An error source the agent set is kept.
    response = check foundryRoutesClient->get("/invocations/tagged");
    test:assertEquals(response.statusCode, 409);
    test:assertEquals(check response.getHeaders("x-platform-error-source"), ["user"]);
    test:assertFalse(response.hasHeader("x-platform-error-detail"));

    // An error source the agent set on an httpscerr error is kept too.
    response = check foundryRoutesClient->get("/invocations/taggedError");
    test:assertEquals(response.statusCode, 409);
    test:assertEquals(check response.getHeaders("x-platform-error-source"), ["user"]);
    test:assertFalse(response.hasHeader("x-platform-error-detail"));
    assertGetOrCancelHeaders(response, "taggedError");

    // A success status is not classified.
    response = check postKind("response");
    test:assertEquals(response.statusCode, 207);
    test:assertFalse(response.hasHeader("x-platform-error-source"));
}

@test:Config {groups: ["foundry"]}
function testFoundryRelayedErrorDropsListenerHeaders() returns error? {
    // The classification and ID headers of another service's response (here another Foundry agent's)
    // describe that service's request, so they are not copied; its other headers are.
    http:Response response = check foundryRoutesClient->get("/invocations/relayed");
    test:assertEquals(response.statusCode, 502);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    test:assertEquals(check response.getHeaders("x-platform-error-source"), ["upstream"]);
    assertGetOrCancelHeaders(response, "relayed");
    test:assertEquals(check response.getHeaders("x-agent-invocation-id"), ["relayed"]);
    test:assertEquals(check response.getHeader("retry-after"), "3");
}

@test:Config {groups: ["foundry"]}
function testFoundryNotImplementedInvokeIsUpstream() returns error? {
    http:Response response = check foundryInvMissingClient->post("/invocations?agent_session_id=s-501", {},
        {"x-agent-invocation-id": "inv-501"});
    test:assertEquals(response.statusCode, 501);
    assertUpstreamError(response);
    [string, string] [invocationId, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(invocationId, "inv-501");
    test:assertEquals(sessionId, "s-501");
}

@test:Config {groups: ["foundry"]}
function testFoundryUnsupportedParameterIsUpstream() returns error? {
    // An unsupported parameter is the agent author's mistake, not a failure of the listener.
    http:Response response = check foundryInvUnsupportedClient->post("/invocations?extra=1", {});
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    _ = assertInvocationHeaders(response);

    // A path parameter that is not a string.
    int callsBefore = foundryRouteCallsCount();
    response = check foundryRoutesIntPathClient->get("/invocations/42");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "42");
    test:assertEquals(foundryRouteCallsCount(), callsBefore, "the get resource was called");
}

@test:Config {groups: ["foundry"]}
function testFoundryStreamIsUpstreamError() returns error? {
    // The listener sends no streaming responses, so a stream is outside the resource contract: the
    // agent's mistake. `postKind` also checks both ID headers.
    http:Response response = check postKind("stream");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);

    // The same on the get resource.
    response = check foundryRoutesClient->get("/invocations/stream");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertUpstreamError(response);
    assertGetOrCancelHeaders(response, "stream");
}

@test:Config {groups: ["foundry"]}
function testFoundryUnlinkedDispatcherIsPlatformError() returns error? {
    // A dispatcher with no linked service (as for a request that races a detach) is a listener failure.
    http:Listener httpListener = check new (FOUNDRY_ROUTES_UNLINKED_PORT);
    check httpListener.attach(new FoundryDispatcherService(toDispatcherConfig({agent: {}})));
    check httpListener.'start();
    do {
        http:Client 'client = check new (string `http://localhost:${FOUNDRY_ROUTES_UNLINKED_PORT}`);
        http:Response invokeResponse = check 'client->post("/invocations", {}, {"x-agent-invocation-id": "inv-u"});
        http:Response getResponse = check 'client->get("/invocations/inv-u");
        http:Response cancelResponse = check 'client->post("/invocations/inv-u/cancel", {});
        foreach http:Response response in [invokeResponse, getResponse, cancelResponse] {
            test:assertEquals(response.statusCode, 500);
            test:assertEquals(check response.getJsonPayload(),
                    {'error: {code: "internal_error", message: "Internal server error"}});
            test:assertEquals(check response.getHeader("x-platform-error-source"), "platform");
            test:assertEquals(check response.getHeader("x-platform-error-detail"), UNLINKED_PLATFORM_DETAIL);
            test:assertEquals(check response.getHeader("x-agent-invocation-id"), "inv-u");
            assertPlatformServer(response);
        }
        test:assertTrue(invokeResponse.hasHeader("x-agent-session-id"));
        test:assertFalse(getResponse.hasHeader("x-agent-session-id"));
        test:assertFalse(cancelResponse.hasHeader("x-agent-session-id"));
    } on fail error e {
        check httpListener.immediateStop();
        return e;
    }
    check httpListener.immediateStop();
}

@test:Config {groups: ["foundry"]}
function testFoundryClassifyError() {
    test:assertEquals(classifyFoundryError(error FoundryPlatformError("listener broke")),
            ["platform", "FoundryPlatformError: listener broke"]);
    test:assertEquals(classifyFoundryError(error("agent broke")), ["upstream", ()]);
    test:assertEquals(classifyFoundryError(error httpscerr:NotFoundError("gone")), ["upstream", ()]);

    // A long platform detail is truncated to 2048 characters.
    string message = repeatChar("m", 3000);
    [string, string?] [errorSource, detail] = classifyFoundryError(error FoundryPlatformError(message));
    test:assertEquals(errorSource, "platform");
    if detail is () {
        test:assertFail("a platform error has no detail");
    }
    test:assertEquals(detail.length(), 2048);
    test:assertTrue(detail.startsWith("FoundryPlatformError: mmm"));
    test:assertTrue(detail.endsWith("m...[truncated]"));
}

@test:Config {groups: ["foundry"]}
function testFoundryTruncateErrorDetail() {
    string suffix = "...[truncated]";
    foreach int length in [0, 10, 2047, 2048] {
        string detail = repeatChar("d", length);
        test:assertEquals(truncateErrorDetail(detail), detail, length.toString());
    }
    foreach int length in [2049, 5000] {
        string detail = string `${repeatChar("a", 2034)}${repeatChar("b", length - 2034)}`;
        string truncated = truncateErrorDetail(detail);
        test:assertEquals(truncated.length(), 2048, length.toString());
        // detail[:2048 - len(suffix)] + suffix, as in the reference.
        test:assertEquals(truncated, repeatChar("a", 2048 - suffix.length()) + suffix, length.toString());
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryHttpModuleErrors() returns error? {
    // A path segment the http module can't decode is the caller's mistake.
    http:Request request = new;
    request.rawPath = "/invocations/%zz/cancel";
    http:Response response = httpModuleErrorResponse(error("URLDecoder: Illegal hex characters"), request);
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "invalid_request", message: INVALID_PATH_BODY_MESSAGE}});
    test:assertEquals(check response.getHeader("x-platform-error-source"), "user");
    test:assertFalse(response.hasHeader("x-platform-error-detail"));

    // Another 4xx of the http module is a user error.
    request.rawPath = "/invocations/inv-1";
    response = httpModuleErrorResponse(error httpscerr:BadRequestError("bad request line"), request);
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getHeader("x-platform-error-source"), "user");

    // A 5xx of the http module is a failure of the listener's HTTP stack. The detail names only the
    // error type, never its message.
    response = httpModuleErrorResponse(error("secret from the request"), request);
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getHeader("x-platform-error-source"), "platform");
    string detail = check response.getHeader("x-platform-error-detail");
    test:assertEquals(detail, "FoundryPlatformError: the http module failed to handle the request (error)");
    test:assertFalse((check response.getTextPayload()).includes("secret"));
}

@test:Config {groups: ["foundry"]}
function testFoundryProtocolPathAndPercentEncoding() {
    foreach string path in ["/invocations", "/invocations/", "/invocations/x", "/invocations/x/cancel",
            "/invocations/docs/openapi.json", "/invocations/%zz"] {
        test:assertTrue(isProtocolPath(path), path);
    }
    foreach string path in ["/", "/readiness", "/invocationsx", "/invocations/x/y", "/invocations/x/cancel/y",
            "/invocations//cancel", "/other/invocations"] {
        test:assertFalse(isProtocolPath(path), path);
    }
    test:assertEquals(pathOf("/invocations/x?agent_session_id=s#f"), "/invocations/x");
    test:assertEquals(pathOf("/invocations"), "/invocations");
    foreach string path in ["/invocations/%zz", "/a%", "/a%2", "/a%g0"] {
        test:assertTrue(hasMalformedPercentEncoding(path), path);
    }
    foreach string path in ["/invocations/a%20b", "/a%2F", "/plain", "/%E6%97%A5"] {
        test:assertFalse(hasMalformedPercentEncoding(path), path);
    }
}

// ===== Helpers =====

function getContextSessionId(http:Client 'client, string path) returns json|error {
    http:Response response = check 'client->get(path);
    test:assertEquals(response.statusCode, 200, path);
    test:assertFalse(response.hasHeader("x-agent-session-id"), path);
    return (check contextOf(response))["sessionId"];
}

// Asserts the headers of a get or cancel response: the invocation ID and no session ID.
function assertGetOrCancelHeaders(http:Response response, string invocationId) {
    string|error header = response.getHeader("x-agent-invocation-id");
    test:assertEquals(header, invocationId);
    test:assertFalse(response.hasHeader("x-agent-session-id"),
            string `x-agent-session-id on a ${response.statusCode} get or cancel response`);
    assertPlatformServer(response);
}

function assertUpstreamError(http:Response response, string description = "") {
    string|error errorSource = response.getHeader("x-platform-error-source");
    test:assertEquals(errorSource, "upstream", description);
    test:assertFalse(response.hasHeader("x-platform-error-detail"), description);
}

function assertNotClassified(http:Response response, string description) {
    test:assertFalse(response.hasHeader("x-platform-error-source"), description);
    test:assertFalse(response.hasHeader("x-platform-error-detail"), description);
    test:assertFalse(response.hasHeader("x-agent-invocation-id"), description);
    test:assertFalse(response.hasHeader("x-agent-session-id"), description);
    assertPlatformServer(response);
}

function repeatChar(string char, int count) returns string =>
    string:'join("", ...from int i in 0 ..< count select char);
