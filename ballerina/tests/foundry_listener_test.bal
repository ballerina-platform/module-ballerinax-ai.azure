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
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/lang.runtime;
import ballerina/test;

// Foundry listener tests (Milestone 2: listener, readiness and lifecycle). Ports 9300-9399 are
// reserved for the Foundry tests; each listener uses its own port.
const FOUNDRY_PORT = 9301;
const FOUNDRY_PROBE_PORT = 9303;
const FOUNDRY_SHARED_PORT = 9311;
const FOUNDRY_GRACEFUL_PORT = 9312;
const FOUNDRY_DETACH_PORT = 9313;
const FOUNDRY_CONFIG_PORT = 9314;
const FOUNDRY_GRACEFUL_ZERO_PORT = 9315;
const FOUNDRY_GRACEFUL_SHARED_PORT = 9316;
const FOUNDRY_BASE_PATH_PORT = 9317;
const FOUNDRY_TWO_FIRST_PORT = 9318;
const FOUNDRY_TWO_SECOND_PORT = 9319;
const FOUNDRY_ATTACH_TWICE_PORT = 9320;

final readonly & FoundryAgentInfo testAgentInfo = {
    projectEndpoint: "https://test.services.ai.azure.com/api/projects/test",
    projectArmId: "/subscriptions/0/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/a/projects/p",
    name: "test-agent",
    version: "7",
    id: "test-agent:7",
    sessionId: "session-from-config"
};

// A Foundry listener on an explicit port, with every platform value injected instead of read from
// the environment.
listener FoundryListener foundryTestListener = new (FOUNDRY_PORT, agent = testAgentInfo, sseKeepAliveInterval = 5,
    gracefulStopTimeout = 2);

service FoundryInvocationService on foundryTestListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;
}

// The Foundry service type used for programmatic attach.
isolated service class TestFoundryService {
    *FoundryInvocationService;

    isolated resource function post invocations(@http:Payload json payload) returns json => payload;
}

final http:Client foundryClient = check new (string `http://localhost:${FOUNDRY_PORT}`);

final regexp:RegExp PLATFORM_SERVER_PATTERN = re `ballerinax-ai\.azure/\d+\.\d+\.\d+ \(ballerina/\d+\.\d+\.\d+\)`;
final regexp:RegExp GENERATED_REQUEST_ID_PATTERN = re `[0-9a-f]{32}`;

// ===== Readiness and the catch-all route =====

// Client settings for tests that leave a listener with no attached service: such a listener answers with
// its own 404, and a kept-alive connection to it would hold up a graceful stop until its timeout.
final http:ClientConfiguration noKeepAlive = {http1Settings: {keepAlive: http:KEEPALIVE_NEVER}};

@test:Config {groups: ["foundry"]}
function testFoundryReadiness() returns error? {
    http:Response response = check foundryClient->get("/readiness");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "{\"status\":\"healthy\"}");
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessHead() returns error? {
    http:Response response = check foundryClient->head("/readiness");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertPlatformServer(response);
    _ = assertGeneratedRequestId(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryUnknownPathIsNotFound() returns error? {
    foreach string path in ["/does/not/exist", "/", "/readiness/extra"] {
        http:Response response = check foundryClient->get(path);
        test:assertEquals(response.statusCode, 404, path);
        test:assertEquals(check response.getJsonPayload(), {'error: {code: "not_found", message: "Not Found"}}, path);
        test:assertEquals(check response.getHeader("content-type"), "application/json", path);
        assertPlatformServer(response);
        _ = assertGeneratedRequestId(response);
    }
    http:Response response = check foundryClient->delete("/does/not/exist");
    test:assertEquals(response.statusCode, 404);
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryWrongMethodOnKnownPath() returns error? {
    http:Response response = check foundryClient->post("/readiness", {});
    test:assertEquals(response.statusCode, 405);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "method_not_allowed", message: "Method Not Allowed"}});
    test:assertEquals(check response.getHeader("allow"), "GET, HEAD");
    assertPlatformServer(response);
    _ = assertGeneratedRequestId(response);
}

// ===== x-platform-server =====

@test:Config {groups: ["foundry"]}
function testFoundryPlatformServerMatchesPackageVersion() returns error? {
    http:Response response = check foundryClient->get("/readiness");
    string platformServer = check response.getHeader("x-platform-server");
    test:assertTrue(PLATFORM_SERVER_PATTERN.isFullMatch(platformServer), platformServer);
    string packageVersion = check packageVersionFromBallerinaToml();
    test:assertTrue(platformServer.startsWith(string `ballerinax-ai.azure/${packageVersion} (ballerina/`),
            string `'${platformServer}' does not carry the package version ${packageVersion}`);
    test:assertEquals(platformServer, FOUNDRY_SERVER_VERSION);
}

// ===== x-request-id =====

@test:Config {groups: ["foundry"]}
function testFoundryRequestIdEchoed() returns error? {
    http:Response response = check foundryClient->get("/readiness", {"x-request-id": "client-request-42"});
    test:assertEquals(check response.getHeader("x-request-id"), "client-request-42");
    response = check foundryClient->get("/does/not/exist", {"x-request-id": "client-request-43"});
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getHeader("x-request-id"), "client-request-43");
    response = check foundryClient->post("/readiness", {}, {"x-request-id": "client-request-44"});
    test:assertEquals(response.statusCode, 405);
    test:assertEquals(check response.getHeader("x-request-id"), "client-request-44");
}

@test:Config {groups: ["foundry"]}
function testFoundryRequestIdFromTraceparent() returns error? {
    string traceId = "4bf92f3577b34da6a3ce929d0e0e4736";
    // A valid traceparent wins over an incoming x-request-id, on success and error responses.
    http:Response response = check foundryClient->get("/readiness",
        {"traceparent": string `00-${traceId}-00f067aa0ba902b7-01`, "x-request-id": "client-request-45"});
    test:assertEquals(check response.getHeader("x-request-id"), traceId);
    response = check foundryClient->get("/does/not/exist", {"traceparent": string `00-${traceId}-00f067aa0ba902b7-01`});
    test:assertEquals(response.statusCode, 404);
    test:assertEquals(check response.getHeader("x-request-id"), traceId);

    // An unusable traceparent falls back to x-request-id, then to a generated ID.
    foreach string traceparent in ["00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            string `00-${traceId}-00f067aa0ba902b7`, "00-abc-00f067aa0ba902b7-01", "garbage", ""] {
        response = check foundryClient->get("/readiness",
            {"traceparent": traceparent, "x-request-id": "client-request-46"});
        test:assertEquals(check response.getHeader("x-request-id"), "client-request-46", traceparent);
    }
    response = check foundryClient->get("/readiness", {"traceparent": "garbage"});
    _ = assertGeneratedRequestId(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryTraceIdFromTraceparent() {
    string traceId = "4bf92f3577b34da6a3ce929d0e0e4736";
    test:assertEquals(traceIdFromTraceparent(string `00-${traceId}-00f067aa0ba902b7-01`), traceId);
    test:assertEquals(traceIdFromTraceparent(string `  00-${traceId}-00f067aa0ba902b7-01  `), traceId);
    // At least four fields are needed; extra fields are accepted, as in the reference.
    test:assertEquals(traceIdFromTraceparent(string `00-${traceId}-00f067aa0ba902b7-01-extra`), traceId);
    test:assertEquals(traceIdFromTraceparent(string `00-${traceId}-00f067aa0ba902b7`), ());
    test:assertEquals(traceIdFromTraceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01"), ());
    test:assertEquals(traceIdFromTraceparent("00-4bf92f3577b34da6-00f067aa0ba902b7-01"), ());
    test:assertEquals(traceIdFromTraceparent(""), ());
}

@test:Config {groups: ["foundry"]}
function testFoundryRequestIdGenerated() returns error? {
    http:Response first = check foundryClient->get("/readiness");
    http:Response second = check foundryClient->get("/readiness", {"x-request-id": ""});
    string firstId = assertGeneratedRequestId(first);
    string secondId = assertGeneratedRequestId(second);
    test:assertNotEquals(firstId, secondId);
}

// ===== Errors generated by the http module =====

// The M2 dispatcher has no resource that binds a payload, query or header, so the errors the http
// module generates itself are exercised on a probe service that runs the dispatcher's own
// interceptor pipeline.
listener http:Listener foundryProbeListener = new (FOUNDRY_PROBE_PORT);

service http:InterceptableService /probe on foundryProbeListener {
    public function createInterceptors() returns http:Interceptor[] =>
        (new FoundryDispatcherService(toDispatcherConfig({agent: {}}))).createInterceptors();

    resource function post bind(@http:Payload record {|int count;|} payload) returns json => payload;

    resource function get query(int count) returns int => count;

    resource function get failure() returns error => error("internal detail that must not leak");

    resource function get notimplemented() returns error =>
        error httpscerr:NotImplementedError("not here", headers = {"x-extra": "kept"});

    resource function get duplicate() returns error => error httpscerr:ConflictError("already there");

    // A status-code error without a status code takes it from its cause, as in the http module.
    resource function get wrapped() returns error =>
        error httpscerr:DefaultStatusCodeError("wrapped", error httpscerr:ConflictError("inner"));

    // An http:Client call that gets a 4xx returns an http:ApplicationResponseError carrying the
    // upstream response's headers.
    resource function get upstream() returns json|error {
        json body = check foundryUpstreamClient->get("/limited");
        return body;
    }
}

// A plain upstream service (no Foundry interceptors) that rate-limits every call.
service /upstream on foundryProbeListener {
    resource function get limited() returns http:TooManyRequests =>
        {headers: {"retry-after": "7"}, body: "slow down"};
}

final http:Client foundryProbeClient = check new (string `http://localhost:${FOUNDRY_PROBE_PORT}/probe`);
final http:Client foundryUpstreamClient = check new (string `http://localhost:${FOUNDRY_PROBE_PORT}/upstream`);

@test:Config {groups: ["foundry"]}
function testFoundryPayloadBindingErrorHasPlatformHeaders() returns error? {
    http:Response response = check foundryProbeClient->post("/bind", {other: "x"}, {"x-request-id": "probe-1"});
    test:assertEquals(response.statusCode, 400);
    json body = check response.getJsonPayload();
    test:assertEquals(check body.'error.code, "invalid_request");
    test:assertTrue((check body.'error.message).toString().startsWith("data binding failed"), body.toString());
    assertPlatformServer(response);
    test:assertEquals(check response.getHeader("x-request-id"), "probe-1");
}

@test:Config {groups: ["foundry"]}
function testFoundryQueryBindingErrorHasPlatformHeaders() returns error? {
    http:Response response = check foundryProbeClient->get("/query?count=abc");
    test:assertEquals(response.statusCode, 400);
    assertPlatformServer(response);
    _ = assertGeneratedRequestId(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnedErrorsHavePlatformHeaders() returns error? {
    http:Response response = check foundryProbeClient->get("/failure");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertPlatformServer(response);
    _ = assertGeneratedRequestId(response);

    response = check foundryProbeClient->get("/notimplemented");
    test:assertEquals(response.statusCode, 501);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "not_implemented", message: "Internal server error"}});
    test:assertEquals(check response.getHeader("x-extra"), "kept");
    assertPlatformServer(response);

    response = check foundryProbeClient->get("/duplicate");
    test:assertEquals(response.statusCode, 409);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "invalid_request", message: "already there"}});
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryStatusCodeErrorUsesCauseStatus() returns error? {
    http:Response response = check foundryProbeClient->get("/wrapped");
    test:assertEquals(response.statusCode, 409);
    test:assertEquals(check response.getJsonPayload(), {'error: {code: "invalid_request", message: "wrapped"}});
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryApplicationResponseErrorKeepsHeaders() returns error? {
    http:Response response = check foundryProbeClient->get("/upstream", {"x-request-id": "probe-upstream"});
    test:assertEquals(response.statusCode, 429);
    test:assertEquals(check response.getHeader("retry-after"), "7");
    // The upstream's body headers are not copied: the body is the Foundry error envelope.
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    json body = check response.getJsonPayload();
    test:assertEquals(check body.'error.code, "invalid_request");
    assertPlatformServer(response);
    test:assertEquals(check response.getHeader("x-request-id"), "probe-upstream");
}

// ===== Shared http:Listener =====

@test:Config {groups: ["foundry"]}
function testFoundryOnSharedHttpListener() returns error? {
    http:Listener httpListener = check new (FOUNDRY_SHARED_PORT);
    FoundryListener foundryListener = check new (httpListener);
    check foundryListener.attach(new TestFoundryService());
    check httpListener.attach(plainService, "/plain");
    check foundryListener.'start();
    do {
        http:Client 'client = check new (string `http://localhost:${FOUNDRY_SHARED_PORT}`);

        http:Response readiness = check 'client->get("/readiness");
        test:assertEquals(readiness.statusCode, 200);
        test:assertEquals(check readiness.getTextPayload(), "{\"status\":\"healthy\"}");
        assertPlatformServer(readiness);

        http:Response notFound = check 'client->get("/nothing/here", {"x-request-id": "shared-1"});
        test:assertEquals(notFound.statusCode, 404);
        assertPlatformServer(notFound);
        test:assertEquals(check notFound.getHeader("x-request-id"), "shared-1");

        // The plain service keeps working, and the dispatcher's interceptors don't touch it.
        http:Response hello = check 'client->get("/plain/hello");
        test:assertEquals(hello.statusCode, 200);
        test:assertEquals(check hello.getTextPayload(), "hello");
        test:assertFalse(hello.hasHeader("x-platform-server"));
        test:assertFalse(hello.hasHeader("x-request-id"));
    } on fail error e {
        check foundryListener.gracefulStop();
        return e;
    }
    check foundryListener.gracefulStop();
}

// ===== Lifecycle =====

// A plain `http:Listener` defaults to `gracefulStopTimeout = 0`, which cuts in-flight requests, so
// these tests also show that the listener applies the Foundry timeout to the `http:Listener` it
// creates, and uses a given `http:Listener` as it is.
@test:Config {groups: ["foundry"]}
function testFoundryGracefulStopLetsInFlightRequestFinish() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_GRACEFUL_PORT, gracefulStopTimeout = 10);
    check foundryListener.attach(new TestFoundryService());
    check foundryListener.getHttpListener().attach(plainService, "/plain");
    check foundryListener.'start();

    http:Response|error response = callSlowThenStop(foundryListener, FOUNDRY_GRACEFUL_PORT);
    if response is error {
        test:assertFail(string `the in-flight request failed: ${response.message()}`);
    }
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "done");
    assertStopped(FOUNDRY_GRACEFUL_PORT);
}

@test:Config {groups: ["foundry"]}
function testFoundryGracefulStopTimeoutIsApplied() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_GRACEFUL_ZERO_PORT, gracefulStopTimeout = 0);
    check foundryListener.attach(new TestFoundryService());
    check foundryListener.getHttpListener().attach(plainService, "/plain");
    check foundryListener.'start();

    http:Response|error response = callSlowThenStop(foundryListener, FOUNDRY_GRACEFUL_ZERO_PORT);
    test:assertTrue(response is error, "a zero graceful-stop timeout let the in-flight request finish");
    assertStopped(FOUNDRY_GRACEFUL_ZERO_PORT);
}

@test:Config {groups: ["foundry"]}
function testFoundryGracefulStopOnSharedHttpListener() returns error? {
    http:Listener httpListener = check new (FOUNDRY_GRACEFUL_SHARED_PORT, gracefulStopTimeout = 10);
    // The Foundry timeout doesn't replace the configuration of a given http:Listener.
    FoundryListener foundryListener = check new (httpListener, gracefulStopTimeout = 0);
    check foundryListener.attach(new TestFoundryService());
    check httpListener.attach(plainService, "/plain");
    check foundryListener.'start();

    http:Response|error response = callSlowThenStop(foundryListener, FOUNDRY_GRACEFUL_SHARED_PORT);
    if response is error {
        test:assertFail(string `the in-flight request failed: ${response.message()}`);
    }
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "done");
    assertStopped(FOUNDRY_GRACEFUL_SHARED_PORT);
}

@test:Config {groups: ["foundry"]}
function testFoundryDetach() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_DETACH_PORT);
    TestFoundryService foundryService = new;
    check foundryListener.attach(foundryService);
    check foundryListener.'start();
    do {
        // No keep-alive: after detach the listener answers with its own 404, and a kept-alive connection
        // would make the graceful stop below wait out its whole timeout.
        http:Client 'client = check new (string `http://localhost:${FOUNDRY_DETACH_PORT}`, noKeepAlive);
        http:Response response = check 'client->get("/readiness");
        test:assertEquals(response.statusCode, 200);
        test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) is FoundryDispatcherService);

        check foundryListener.detach(foundryService);
        test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) is ());

        response = check 'client->get("/readiness");
        test:assertEquals(response.statusCode, 404);
        test:assertNotEquals(check response.getTextPayload(), "{\"status\":\"healthy\"}");
        test:assertFalse(response.hasHeader("x-platform-server"));

        // Detaching a service that is not attached is a no-op.
        check foundryListener.detach(foundryService);
    } on fail error e {
        check foundryListener.immediateStop();
        return e;
    }
    check foundryListener.gracefulStop();
}

@test:Config {groups: ["foundry"]}
function testFoundryAttachLinksServiceAndDispatcher() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_CONFIG_PORT, agent = testAgentInfo, sseKeepAliveInterval = 0,
        openApiSpec = {openapi: "3.0.1"});
    TestFoundryService foundryService = new;
    check foundryListener.attach(foundryService);
    FoundryDispatcherService? dispatcher = getFoundryDispatcher(foundryService, foundryListener);
    if dispatcher is () {
        test:assertFail("the dispatcher is not linked with the attached service");
    }
    test:assertTrue(getFoundryService(dispatcher) === foundryService);
    FoundryDispatcherConfig expected = {agent: testAgentInfo, sseKeepAliveInterval: 0, openApiSpec: {openapi: "3.0.1"}};
    test:assertEquals(dispatcher.getConfig(), expected);
    check foundryListener.detach(foundryService);
    test:assertTrue(getFoundryService(dispatcher) is ());
    test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) is ());
}

@test:Config {groups: ["foundry"]}
function testFoundryAttachRequiresRootBasePath() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_BASE_PATH_PORT);
    TestFoundryService foundryService = new;
    foreach string[]|string name in ["agent", "/agent", ["agent"], ["", "agent"]] {
        error? result = foundryListener.attach(foundryService, name);
        if result !is error {
            test:assertFail(string `a non-root base path was accepted: ${name.toString()}`);
        }
        test:assertTrue(result.message().startsWith("A FoundryInvocationService must be attached at the root base path"),
                result.message());
        test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) is ());
    }
    // The root base path, in any spelling.
    check foundryListener.attach(foundryService, "/");
    check foundryListener.detach(foundryService);

    foreach string[]|string? name in [(), "", "/", " / ", "//", [], [""], ["/"]] {
        test:assertTrue(isRootBasePath(name), name.toString());
    }
    test:assertFalse(isRootBasePath("a"));
    test:assertFalse(isRootBasePath(["", "a"]));
}

@test:Config {groups: ["foundry"]}
function testFoundryAttachTwiceIsRejected() returns error? {
    FoundryListener foundryListener = check new (FOUNDRY_ATTACH_TWICE_PORT);
    TestFoundryService foundryService = new;
    check foundryListener.attach(foundryService);
    FoundryDispatcherService? dispatcher = getFoundryDispatcher(foundryService, foundryListener);
    error? result = foundryListener.attach(foundryService);
    if result !is error {
        test:assertFail("attaching the same service twice was accepted");
    }
    test:assertEquals(result.message(), "The FoundryInvocationService is already attached to this FoundryListener");
    // The first attachment is untouched.
    test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) === dispatcher);
    if dispatcher is FoundryDispatcherService {
        test:assertTrue(getFoundryService(dispatcher) === foundryService);
    }
    check foundryListener.detach(foundryService);
    test:assertTrue(getFoundryDispatcher(foundryService, foundryListener) is ());
}

@test:Config {groups: ["foundry"]}
function testFoundryServiceOnTwoListeners() returns error? {
    FoundryListener first = check new (FOUNDRY_TWO_FIRST_PORT);
    FoundryListener second = check new (FOUNDRY_TWO_SECOND_PORT);
    TestFoundryService foundryService = new;
    check first.attach(foundryService);
    check second.attach(foundryService);
    check first.'start();
    check second.'start();
    do {
        FoundryDispatcherService? firstDispatcher = getFoundryDispatcher(foundryService, first);
        FoundryDispatcherService? secondDispatcher = getFoundryDispatcher(foundryService, second);
        if firstDispatcher is () || secondDispatcher is () {
            test:assertFail("the service is not linked with a dispatcher on each listener");
        }
        test:assertFalse(firstDispatcher === secondDispatcher);

        http:Client firstClient = check new (string `http://localhost:${FOUNDRY_TWO_FIRST_PORT}`, noKeepAlive);
        http:Client secondClient = check new (string `http://localhost:${FOUNDRY_TWO_SECOND_PORT}`, noKeepAlive);

        // Detaching from the first listener leaves the second one fully working.
        check first.detach(foundryService);
        http:Response response = check firstClient->get("/readiness");
        test:assertEquals(response.statusCode, 404);
        response = check secondClient->get("/readiness");
        test:assertEquals(response.statusCode, 200);
        test:assertTrue(getFoundryService(secondDispatcher) === foundryService);
        test:assertTrue(getFoundryService(firstDispatcher) is ());
        test:assertTrue(getFoundryDispatcher(foundryService, second) === secondDispatcher);

        // Detaching again from the first listener does nothing to the second.
        check first.detach(foundryService);
        response = check secondClient->get("/readiness");
        test:assertEquals(response.statusCode, 200);

        check second.detach(foundryService);
        response = check secondClient->get("/readiness");
        test:assertEquals(response.statusCode, 404);
        test:assertTrue(getFoundryService(secondDispatcher) is ());
    } on fail error e {
        check first.immediateStop();
        check second.immediateStop();
        return e;
    }
    check first.gracefulStop();
    check second.gracefulStop();
}

// ===== Helpers =====

final http:Service plainService = service object {
    resource function get hello() returns string => "hello";

    resource function get slow() returns string {
        lock {
            slowRequestsStarted += 1;
        }
        runtime:sleep(2);
        return "done";
    }
};

// How many slow requests have reached the resource, so a test stops the listener only once its
// request is really in flight.
isolated int slowRequestsStarted = 0;

isolated function slowRequestsStartedCount() returns int {
    lock {
        return slowRequestsStarted;
    }
}

function getSlow(http:Client 'client) returns http:Response|error {
    return 'client->get("/plain/slow");
}

// Starts a slow request, waits until it is running in the resource, stops the listener gracefully
// while it is in flight, and returns the request's outcome. Because the request is known to have
// reached the resource, an error outcome means the stop cut it, not that it was refused. A setup
// failure, or a request that never reaches the resource within 10 seconds, panics, which fails the
// test.
function callSlowThenStop(FoundryListener foundryListener, int port) returns http:Response|error {
    http:Client 'client = checkpanic new (string `http://localhost:${port}`, timeout = 30);
    int startedBefore = slowRequestsStartedCount();
    future<http:Response|error> inFlight = start getSlow('client);
    int polls = 0;
    while slowRequestsStartedCount() == startedBefore {
        if polls >= 200 {
            panic error("the slow request did not reach the resource within 10 seconds");
        }
        runtime:sleep(0.05);
        polls += 1;
    }
    checkpanic foundryListener.gracefulStop();
    return wait inFlight;
}

function assertStopped(int port) {
    http:Client|error 'client = new (string `http://localhost:${port}`, timeout = 5);
    if 'client is error {
        test:assertFail('client.message());
    }
    http:Response|error response = 'client->get("/readiness");
    test:assertTrue(response is error, "the listener still serves requests after gracefulStop");
}

function assertPlatformServer(http:Response response) {
    string|error platformServer = response.getHeader("x-platform-server");
    if platformServer is error {
        test:assertFail("x-platform-server header is missing");
    }
    test:assertTrue(PLATFORM_SERVER_PATTERN.isFullMatch(platformServer), platformServer);
}

function assertGeneratedRequestId(http:Response response) returns string {
    string|error requestId = response.getHeader("x-request-id");
    if requestId is error {
        test:assertFail("x-request-id header is missing");
    }
    test:assertTrue(GENERATED_REQUEST_ID_PATTERN.isFullMatch(requestId), requestId);
    return requestId;
}

// Reads the package version from the `[package]` table of Ballerina.toml.
function packageVersionFromBallerinaToml() returns string|error {
    string toml = check io:fileReadString("Ballerina.toml");
    int? packageTable = toml.indexOf("[package]");
    if packageTable is () {
        return error("no [package] table in Ballerina.toml");
    }
    regexp:Groups? groups = re `\nversion\s*=\s*"([^"]+)"`.findGroups(toml, packageTable);
    if groups is () || groups.length() < 2 {
        return error("no package version in Ballerina.toml");
    }
    regexp:Span? version = groups[1];
    if version is () {
        return error("no package version in Ballerina.toml");
    }
    return version.substring();
}
