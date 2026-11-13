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

// Foundry listener tests for the readiness probe, served by the service's required `get readiness`
// resource. Each readiness behaviour runs on its own listener and port.
const FOUNDRY_READY_VALUE_PORT = 9370;
const FOUNDRY_READY_NIL_PORT = 9371;
const FOUNDRY_READY_UNAVAILABLE_PORT = 9372;
const FOUNDRY_READY_ERROR_PORT = 9373;
const FOUNDRY_READY_PANIC_PORT = 9374;
const FOUNDRY_READY_STATUS_ERROR_PORT = 9375;
const FOUNDRY_READY_MISSING_PORT = 9376;
const FOUNDRY_READY_PARAMETER_PORT = 9377;
const FOUNDRY_READY_UNLINKED_PORT = 9378;
const FOUNDRY_READY_TEXT_PORT = 9379;

const READY_HEALTHY_BODY = "{\"status\":\"healthy\"}";

// How many times the readiness resources ran, so a test can check that `HEAD /readiness` calls the
// user's resource.
isolated int foundryReadinessCalls = 0;

isolated function foundryReadinessCallsCount() returns int {
    lock {
        return foundryReadinessCalls;
    }
}

isolated function countFoundryReadinessCall() {
    lock {
        foundryReadinessCalls += 1;
    }
}

// A plain `anydata` value: `200` with that body.
listener FoundryListener foundryReadyValueListener = new (FOUNDRY_READY_VALUE_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyValueListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns json {
        countFoundryReadinessCall();
        return {status: "ready", model: "loaded"};
    }
}

// An explicit `()`: the default healthy response.
listener FoundryListener foundryReadyNilListener = new (FOUNDRY_READY_NIL_PORT, agent = {}, gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyNilListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns http:Ok|error? {
        countFoundryReadinessCall();
        return;
    }
}

// Not ready yet: a status-code record passes through as it is.
listener FoundryListener foundryReadyUnavailableListener = new (FOUNDRY_READY_UNAVAILABLE_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyUnavailableListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns http:Ok|http:ServiceUnavailable {
        countFoundryReadinessCall();
        http:ServiceUnavailable unavailable = {body: {status: "starting"}, headers: {"retry-after": "5"}};
        return unavailable;
    }
}

// A returned error, a panic and an `httpscerr` status-code error.
listener FoundryListener foundryReadyErrorListener = new (FOUNDRY_READY_ERROR_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyErrorListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns json|error => error("secret readiness detail");
}

listener FoundryListener foundryReadyPanicListener = new (FOUNDRY_READY_PANIC_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyPanicListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns json {
        panic error("secret readiness panic");
    }
}

listener FoundryListener foundryReadyStatusErrorListener = new (FOUNDRY_READY_STATUS_ERROR_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyStatusErrorListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness() returns json|error =>
        error httpscerr:ServiceUnavailableError("warming up", headers = {"retry-after": "10"});
}

// No readiness resource. The compiler plugin rejects this in a user's package (it doesn't validate
// this package's own services), so this is only the listener's run-time fallback: the default healthy
// response.
listener FoundryListener foundryReadyMissingListener = new (FOUNDRY_READY_MISSING_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyMissingListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;
}

// A readiness resource with a parameter, which the compiler plugin also rejects; at run time it is a
// `500`, still not classified.
listener FoundryListener foundryReadyParameterListener = new (FOUNDRY_READY_PARAMETER_PORT, agent = {},
    gracefulStopTimeout = 0);

service FoundryInvocationService on foundryReadyParameterListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;

    resource function get readiness(FoundryContext ctx) returns json {
        countFoundryReadinessCall();
        return {sessionId: ctx.sessionId};
    }
}

// A `string` value: `200` with a `text/plain` body.
listener FoundryListener foundryReadyTextListener = new (FOUNDRY_READY_TEXT_PORT, agent = {},
    gracefulStopTimeout = 0);

isolated service FoundryInvocationService on foundryReadyTextListener {
    isolated resource function post invocations(@http:Payload json payload) returns json => payload;

    isolated resource function get readiness() returns string => "ready";
}

final http:Client foundryReadyValueClient = check new (string `http://localhost:${FOUNDRY_READY_VALUE_PORT}`);
final http:Client foundryReadyNilClient = check new (string `http://localhost:${FOUNDRY_READY_NIL_PORT}`);
final http:Client foundryReadyUnavailableClient =
    check new (string `http://localhost:${FOUNDRY_READY_UNAVAILABLE_PORT}`);
final http:Client foundryReadyErrorClient = check new (string `http://localhost:${FOUNDRY_READY_ERROR_PORT}`);
final http:Client foundryReadyPanicClient = check new (string `http://localhost:${FOUNDRY_READY_PANIC_PORT}`);
final http:Client foundryReadyStatusErrorClient =
    check new (string `http://localhost:${FOUNDRY_READY_STATUS_ERROR_PORT}`);
final http:Client foundryReadyMissingClient = check new (string `http://localhost:${FOUNDRY_READY_MISSING_PORT}`);
final http:Client foundryReadyParameterClient =
    check new (string `http://localhost:${FOUNDRY_READY_PARAMETER_PORT}`);
final http:Client foundryReadyTextClient = check new (string `http://localhost:${FOUNDRY_READY_TEXT_PORT}`);

@test:Config {groups: ["foundry"]}
function testFoundryReadinessReturnsValue() returns error? {
    int callsBefore = foundryReadinessCallsCount();
    http:Response response = check foundryReadyValueClient->get("/readiness", {"x-request-id": "ready-1"});
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getJsonPayload(), {status: "ready", model: "loaded"});
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertNotClassified(response, "readiness value");
    test:assertEquals(check response.getHeader("x-request-id"), "ready-1");
    test:assertEquals(foundryReadinessCallsCount(), callsBefore + 1);
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessReturnsText() returns error? {
    http:Response response = check foundryReadyTextClient->get("/readiness");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "ready");
    test:assertTrue((check response.getHeader("content-type")).startsWith("text/plain"));
    assertNotClassified(response, "readiness text");
    _ = assertGeneratedRequestId(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessNilIsDefaultHealthy() returns error? {
    int callsBefore = foundryReadinessCallsCount();
    http:Response response = check foundryReadyNilClient->get("/readiness");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), READY_HEALTHY_BODY);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertNotClassified(response, "readiness nil");
    _ = assertGeneratedRequestId(response);
    test:assertEquals(foundryReadinessCallsCount(), callsBefore + 1);
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessServiceUnavailablePassesThrough() returns error? {
    http:Response response = check foundryReadyUnavailableClient->get("/readiness",
        {"x-request-id": "ready-503"});
    test:assertEquals(response.statusCode, 503);
    test:assertEquals(check response.getJsonPayload(), {status: "starting"});
    test:assertEquals(check response.getHeader("retry-after"), "5");
    // Readiness is not a protocol endpoint: a 5xx the agent returns is not classified.
    assertNotClassified(response, "readiness 503");
    test:assertEquals(check response.getHeader("x-request-id"), "ready-503");
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessErrorIsInternalServerError() returns error? {
    foreach http:Client 'client in [foundryReadyErrorClient, foundryReadyPanicClient] {
        http:Response response = check 'client->get("/readiness");
        test:assertEquals(response.statusCode, 500);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "internal_error", message: "Internal server error"}});
        test:assertFalse((check response.getTextPayload()).includes("secret"));
        assertNotClassified(response, "readiness error");
        _ = assertGeneratedRequestId(response);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessStatusCodeErrorKeepsStatus() returns error? {
    http:Response response = check foundryReadyStatusErrorClient->get("/readiness");
    test:assertEquals(response.statusCode, 503);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    test:assertEquals(check response.getHeader("retry-after"), "10");
    assertNotClassified(response, "readiness status-code error");
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessHeadCallsResource() returns error? {
    int callsBefore = foundryReadinessCallsCount();
    http:Response response = check foundryReadyValueClient->head("/readiness", {"x-request-id": "ready-head"});
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
    assertNotClassified(response, "HEAD readiness");
    test:assertEquals(check response.getHeader("x-request-id"), "ready-head");
    test:assertEquals(foundryReadinessCallsCount(), callsBefore + 1);

    // HEAD gets the status the GET response has.
    response = check foundryReadyUnavailableClient->head("/readiness");
    test:assertEquals(response.statusCode, 503);
    assertNotClassified(response, "HEAD readiness 503");
    response = check foundryReadyErrorClient->head("/readiness");
    test:assertEquals(response.statusCode, 500);
    assertNotClassified(response, "HEAD readiness error");
    response = check foundryReadyNilClient->head("/readiness");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getHeader("content-type"), "application/json");
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessMissingResourceIsDefaultHealthy() returns error? {
    foreach string method in [http:HTTP_GET, http:HTTP_HEAD] {
        http:Response response = check foundryReadyMissingClient->execute(method, "/readiness", new http:Request());
        test:assertEquals(response.statusCode, 200, method);
        test:assertEquals(check response.getHeader("content-type"), "application/json", method);
        assertNotClassified(response, method);
        if method == http:HTTP_GET {
            test:assertEquals(check response.getTextPayload(), READY_HEALTHY_BODY);
        }
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessWithParameterIsNotCalled() returns error? {
    int callsBefore = foundryReadinessCallsCount();
    http:Response response = check foundryReadyParameterClient->get("/readiness");
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    assertNotClassified(response, "readiness with a parameter");
    test:assertEquals(foundryReadinessCallsCount(), callsBefore);
}

@test:Config {groups: ["foundry"]}
function testFoundryReadinessUnlinkedDispatcher() returns error? {
    // A dispatcher with no linked service (as for a probe that races a detach) can't call the readiness
    // resource: a `500`, not classified, as every readiness response.
    http:Listener httpListener = check new (FOUNDRY_READY_UNLINKED_PORT);
    check httpListener.attach(new FoundryDispatcherService(toDispatcherConfig({agent: {}})));
    check httpListener.'start();
    do {
        http:Client 'client = check new (string `http://localhost:${FOUNDRY_READY_UNLINKED_PORT}`);
        http:Response response = check 'client->get("/readiness");
        test:assertEquals(response.statusCode, 500);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "internal_error", message: "Internal server error"}});
        assertNotClassified(response, "readiness on an unlinked dispatcher");
    } on fail error e {
        check httpListener.immediateStop();
        return e;
    }
    check httpListener.immediateStop();
}
