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
import ballerina/test;

// Tests of foundryPlatformHeaders: the headers a hosted agent forwards on outbound calls to Foundry
// platform services. A Foundry service calls a mock platform service with them.
const FOUNDRY_OUTBOUND_PORT = 9380;
const FOUNDRY_OUTBOUND_MOCK_PORT = 9381;

// An opaque call ID with characters a parser might trip on, to check it is forwarded unchanged.
const TEST_CALL_ID = "opaque.Call-ID:42/AbC+xyz==";

// Builds a context the way the listener does, from a request with the given platform headers.
isolated function foundryContextWithHeaders(map<string> headers) returns FoundryContext|error {
    http:Request request = new;
    foreach [string, string] [name, value] in headers.entries() {
        request.setHeader(name, value);
    }
    return foundryContextFromRequest(request, "session-1", "invocation-1", {});
}

@test:Config {}
function testFoundryPlatformHeadersWithCallId() returns error? {
    FoundryContext ctx = check foundryContextWithHeaders({"x-agent-foundry-call-id": TEST_CALL_ID});
    test:assertEquals(foundryPlatformHeaders(ctx), {"x-agent-foundry-call-id": TEST_CALL_ID});
}

@test:Config {}
function testFoundryPlatformHeadersWithoutCallId() returns error? {
    FoundryContext ctx = check foundryContextWithHeaders({});
    test:assertEquals(ctx.callId, ());
    test:assertEquals(foundryPlatformHeaders(ctx), {});
}

@test:Config {}
function testFoundryPlatformHeadersExcludeUserId() returns error? {
    FoundryContext withCallId = check foundryContextWithHeaders(
            {"x-agent-foundry-call-id": TEST_CALL_ID, "x-agent-user-id": "user-1"});
    test:assertEquals(withCallId.userId, "user-1");
    test:assertEquals(foundryPlatformHeaders(withCallId), {"x-agent-foundry-call-id": TEST_CALL_ID});

    FoundryContext userIdOnly = check foundryContextWithHeaders({"x-agent-user-id": "user-1"});
    test:assertEquals(foundryPlatformHeaders(userIdOnly), {});
}

@test:Config {}
function testFoundryPlatformHeadersFromContextRecord() returns error? {
    // A context built directly (for example in a user's own test), with only a user ID and no call ID.
    FoundryContext ctx = {
        sessionId: "session-1",
        invocationId: "invocation-1",
        userId: "user-1",
        headers: createFoundryHeaders(new http:Request())
    };
    test:assertEquals(foundryPlatformHeaders(ctx), {});
    ctx.callId = TEST_CALL_ID;
    test:assertEquals(foundryPlatformHeaders(ctx), {"x-agent-foundry-call-id": TEST_CALL_ID});
}

@test:Config {}
function testFoundryPlatformHeadersReturnsNewMap() returns error? {
    FoundryContext ctx = check foundryContextWithHeaders({"x-agent-foundry-call-id": TEST_CALL_ID});
    map<string|string[]> first = foundryPlatformHeaders(ctx);
    first["authorization"] = "Bearer token";
    // A multi-valued header can be added, as the documented usage shows.
    first["accept"] = ["application/json", "text/plain"];
    test:assertEquals(foundryPlatformHeaders(ctx), {"x-agent-foundry-call-id": TEST_CALL_ID});
    // The result is assignable to the headers parameter of the http:Client methods.
    map<string|string[]>? clientHeaders = foundryPlatformHeaders(ctx);
    test:assertEquals(clientHeaders, {"x-agent-foundry-call-id": TEST_CALL_ID});
}

// A mock Foundry platform service that echoes the identity headers it received.
service /platform on new http:Listener(FOUNDRY_OUTBOUND_MOCK_PORT) {
    resource function post items(http:Request request) returns json|error {
        json payload = check request.getJsonPayload();
        return {
            callId: mockPlatformHeader(request, "x-agent-foundry-call-id"),
            callIdCount: mockPlatformHeaderCount(request, "x-agent-foundry-call-id"),
            hasUserId: request.hasHeader("x-agent-user-id"),
            authorization: mockPlatformHeader(request, "authorization"),
            payload
        };
    }
}

isolated function mockPlatformHeader(http:Request request, string name) returns string? {
    string|http:HeaderNotFoundError value = request.getHeader(name);
    return value is string ? value : ();
}

isolated function mockPlatformHeaderCount(http:Request request, string name) returns int {
    string[]|http:HeaderNotFoundError values = request.getHeaders(name);
    return values is string[] ? values.length() : 0;
}

final http:Client foundryMockPlatformClient =
        check new (string `http://localhost:${FOUNDRY_OUTBOUND_MOCK_PORT}/platform`);

listener FoundryListener foundryOutboundListener = new (FOUNDRY_OUTBOUND_PORT, agent = testAgentInfo);

// An agent that forwards the platform headers, next to its own credentials, on an outbound call and
// returns what the platform service received.
service FoundryInvocationService on foundryOutboundListener {
    resource function post invocations(@http:Payload json payload, FoundryContext ctx) returns json|error {
        map<string|string[]> headers = foundryPlatformHeaders(ctx);
        headers["authorization"] = "Bearer agent-token";
        json received = check foundryMockPlatformClient->post("/items", payload, headers);
        return received;
    }
}

final http:Client foundryOutboundClient = check new (string `http://localhost:${FOUNDRY_OUTBOUND_PORT}`);

@test:Config {}
function testFoundryPlatformHeadersForwardedOnOutboundCall() returns error? {
    json received = check foundryOutboundClient->post("/invocations", {message: "hi"},
        {"x-agent-foundry-call-id": TEST_CALL_ID, "x-agent-user-id": "user-1"});
    test:assertEquals(received, {
        callId: TEST_CALL_ID,
        callIdCount: 1,
        hasUserId: false,
        authorization: "Bearer agent-token",
        payload: {message: "hi"}
    });
}

@test:Config {}
function testFoundryPlatformHeadersNotForwardedWithoutCallId() returns error? {
    json received = check foundryOutboundClient->post("/invocations", {message: "local"},
        {"x-agent-user-id": "user-1"});
    test:assertEquals(received, {
        callId: (),
        callIdCount: 0,
        hasUserId: false,
        authorization: "Bearer agent-token",
        payload: {message: "local"}
    });
}
