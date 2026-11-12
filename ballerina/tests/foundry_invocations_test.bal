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
import ballerina/lang.regexp;
import ballerina/lang.runtime;
import ballerina/test;

// Foundry listener tests (Milestone 3: POST /invocations dispatch, IDs, platform context, payload
// binding and result mapping). Each service signature runs on its own listener and port.
const FOUNDRY_INV_PORT = 9330;
const FOUNDRY_INV_LOCAL_PORT = 9331;
const FOUNDRY_INV_RECORD_PORT = 9332;
const FOUNDRY_INV_TEXT_PORT = 9333;
const FOUNDRY_INV_BYTES_PORT = 9334;
const FOUNDRY_INV_XML_PORT = 9335;
const FOUNDRY_INV_ARRAY_PORT = 9336;
const FOUNDRY_INV_RETURNS_PORT = 9337;
const FOUNDRY_INV_MISSING_PORT = 9338;
const FOUNDRY_INV_UNSUPPORTED_PORT = 9339;
const FOUNDRY_INV_GRACEFUL_PORT = 9340;
const FOUNDRY_INV_NON_ISOLATED_PORT = 9341;

final regexp:RegExp UUID_PATTERN = re `[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`;

type FoundryTestOrder record {|
    string id;
    int quantity;
|};

// How many times the context-echo resources ran, so a test can check that a rejected request never
// reached the user's resource.
isolated int foundryInvocationsCalled = 0;

isolated function foundryInvocationsCalledCount() returns int {
    lock {
        return foundryInvocationsCalled;
    }
}

isolated function countFoundryInvocation() {
    lock {
        foundryInvocationsCalled += 1;
    }
}

// Summarizes a FoundryContext as JSON, so a test can check what the resource received.
isolated function foundryContextSummary(FoundryContext ctx) returns json {
    string|http:HeaderNotFoundError testHeader = ctx.headers.getHeader("x-test-header");
    return {
        sessionId: ctx.sessionId,
        invocationId: ctx.invocationId,
        userId: ctx.userId,
        callId: ctx.callId,
        originalSubject: ctx.originalSubject.toJson(),
        clientHeaders: ctx.clientHeaders,
        trace: ctx.trace.toJson(),
        agent: ctx.agent.toJson(),
        testHeader: testHeader is string ? testHeader : ()
    };
}

// A: payload then context, with the agent information injected (including a configured session ID).
listener FoundryListener foundryInvListener = new (FOUNDRY_INV_PORT, agent = testAgentInfo);

service FoundryInvocationService on foundryInvListener {
    resource function post invocations(@http:Payload json payload, FoundryContext ctx) returns json {
        countFoundryInvocation();
        return {payload, context: foundryContextSummary(ctx)};
    }
}

// B: a local run: no agent information, no payload parameter, context only.
listener FoundryListener foundryInvLocalListener = new (FOUNDRY_INV_LOCAL_PORT, agent = {});

service FoundryInvocationService on foundryInvLocalListener {
    resource function post invocations(FoundryContext ctx) returns json {
        countFoundryInvocation();
        return foundryContextSummary(ctx);
    }
}

// C: context before payload, with a closed record payload.
listener FoundryListener foundryInvRecordListener = new (FOUNDRY_INV_RECORD_PORT, agent = {});

service FoundryInvocationService on foundryInvRecordListener {
    resource function post invocations(FoundryContext ctx, @http:Payload FoundryTestOrder 'order) returns json {
        countFoundryInvocation();
        return {'order, sessionId: ctx.sessionId};
    }
}

// D, E, F, G: payload only, of type string, byte[], xml and an array of records.
listener FoundryListener foundryInvTextListener = new (FOUNDRY_INV_TEXT_PORT, agent = {});

service FoundryInvocationService on foundryInvTextListener {
    resource function post invocations(@http:Payload string text) returns string => string `got:${text}`;
}

listener FoundryListener foundryInvBytesListener = new (FOUNDRY_INV_BYTES_PORT, agent = {});

service FoundryInvocationService on foundryInvBytesListener {
    resource function post invocations(@http:Payload byte[] bytes) returns byte[] => [...bytes, 0];
}

listener FoundryListener foundryInvXmlListener = new (FOUNDRY_INV_XML_PORT, agent = {});

service FoundryInvocationService on foundryInvXmlListener {
    resource function post invocations(@http:Payload xml document) returns xml => xml `<got>${document}</got>`;
}

listener FoundryListener foundryInvArrayListener = new (FOUNDRY_INV_ARRAY_PORT, agent = {});

service FoundryInvocationService on foundryInvArrayListener {
    resource function post invocations(@http:Payload FoundryTestOrder[] orders) returns int => orders.length();
}

// H: every kind of return value, chosen by the payload's `kind`.
listener FoundryListener foundryInvReturnsListener = new (FOUNDRY_INV_RETURNS_PORT, agent = {});

service FoundryInvocationService on foundryInvReturnsListener {
    resource function post invocations(@http:Payload record {|string kind;|} payload)
            returns json|string|byte[]|xml|FoundryTestOrder|http:Response|http:Created|http:BadRequest
                |stream<string, error?>|error {
        match payload.kind {
            "json" => {
                return {ok: true};
            }
            "string" => {
                return "plain text";
            }
            "record" => {
                FoundryTestOrder result = {id: "r1", quantity: 1};
                return result;
            }
            "bytes" => {
                byte[] bytes = [1, 2, 3];
                return bytes;
            }
            "xml" => {
                return xml `<result>ok</result>`;
            }
            "nil" => {
                return ();
            }
            "response" => {
                http:Response response = new;
                response.statusCode = 207;
                response.setHeader("x-custom", "kept");
                // The listener replaces a session header the user sets.
                response.setHeader("x-agent-session-id", "user-value");
                response.setTextPayload("multi");
                return response;
            }
            "created" => {
                http:Created created = {
                    body: {id: "c1"},
                    headers: {"location": "/invocations/c1", "x-custom": "c"},
                    mediaType: "application/vnd.test+json"
                };
                return created;
            }
            "badRequest" => {
                http:BadRequest badRequest = {body: {reason: "bad"}};
                return badRequest;
            }
            "error" => {
                return error("secret internal detail");
            }
            "panic" => {
                panic error("secret panic detail");
            }
            "stream" => {
                return ["a", "b"].toStream();
            }
        }
        return error("unknown kind");
    }
}

// I: a service without a `post invocations` resource.
listener FoundryListener foundryInvMissingListener = new (FOUNDRY_INV_MISSING_PORT, agent = {});

service FoundryInvocationService on foundryInvMissingListener {
    resource function get invocations/[string invocationId]() returns json => {invocationId};
}

// J: a `post invocations` resource with a parameter the listener can't supply.
listener FoundryListener foundryInvUnsupportedListener = new (FOUNDRY_INV_UNSUPPORTED_PORT, agent = {});

service FoundryInvocationService on foundryInvUnsupportedListener {
    resource function post invocations(@http:Payload json payload, string extra) returns json {
        countFoundryInvocation();
        return payload;
    }
}

// A slow service for the graceful-stop test. It counts the slow requests that reach it with the
// counter of the Milestone 2 graceful-stop tests.
isolated service class SlowFoundryInvocationService {
    *FoundryInvocationService;

    isolated resource function post invocations(FoundryContext ctx) returns string {
        lock {
            slowRequestsStarted += 1;
        }
        runtime:sleep(2);
        return "done:" + ctx.sessionId;
    }
}

// K: a service that is not isolated. It changes module-level state without a lock, which is safe
// only because the runtime's global lock lets one request run in it at a time, as on an http:Listener.
int foundryNonIsolatedActive = 0;
int foundryNonIsolatedMaxActive = 0;
int foundryNonIsolatedCalls = 0;

listener FoundryListener foundryInvNonIsolatedListener = new (FOUNDRY_INV_NON_ISOLATED_PORT, agent = {});

service FoundryInvocationService on foundryInvNonIsolatedListener {
    resource function post invocations(FoundryContext ctx) returns json {
        foundryNonIsolatedActive += 1;
        if foundryNonIsolatedActive > foundryNonIsolatedMaxActive {
            foundryNonIsolatedMaxActive = foundryNonIsolatedActive;
        }
        // Busy work with no yield point, so requests running at the same time would overlap here.
        int sum = 0;
        foreach int i in 0 ..< 3000000 {
            sum += i % 7;
        }
        foundryNonIsolatedCalls += 1;
        foundryNonIsolatedActive -= 1;
        return {sum, sessionId: ctx.sessionId};
    }
}

final http:Client foundryInvClient = check new (string `http://localhost:${FOUNDRY_INV_PORT}`);
final http:Client foundryInvLocalClient = check new (string `http://localhost:${FOUNDRY_INV_LOCAL_PORT}`);
final http:Client foundryInvRecordClient = check new (string `http://localhost:${FOUNDRY_INV_RECORD_PORT}`);
final http:Client foundryInvTextClient = check new (string `http://localhost:${FOUNDRY_INV_TEXT_PORT}`);
final http:Client foundryInvBytesClient = check new (string `http://localhost:${FOUNDRY_INV_BYTES_PORT}`);
final http:Client foundryInvXmlClient = check new (string `http://localhost:${FOUNDRY_INV_XML_PORT}`);
final http:Client foundryInvArrayClient = check new (string `http://localhost:${FOUNDRY_INV_ARRAY_PORT}`);
final http:Client foundryInvReturnsClient = check new (string `http://localhost:${FOUNDRY_INV_RETURNS_PORT}`);
final http:Client foundryInvMissingClient = check new (string `http://localhost:${FOUNDRY_INV_MISSING_PORT}`);
final http:Client foundryInvUnsupportedClient =
    check new (string `http://localhost:${FOUNDRY_INV_UNSUPPORTED_PORT}`);
final http:Client foundryInvNonIsolatedClient =
    check new (string `http://localhost:${FOUNDRY_INV_NON_ISOLATED_PORT}`);

// ===== Session ID =====

@test:Config {groups: ["foundry"]}
function testFoundrySessionIdFromQuery() returns error? {
    http:Response response = check foundryInvClient->post("/invocations?agent_session_id=session-from-query", {});
    test:assertEquals(response.statusCode, 200);
    [string, string] [_, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(sessionId, "session-from-query");
    test:assertEquals((check contextOf(response)).sessionId, "session-from-query");
}

@test:Config {groups: ["foundry"]}
function testFoundrySessionIdFromConfig() returns error? {
    // No query parameter, and an empty one, both fall through to the configured session ID.
    foreach string path in ["/invocations", "/invocations?agent_session_id=", "/invocations?other=1"] {
        http:Response response = check foundryInvClient->post(path, {});
        test:assertEquals(response.statusCode, 200, path);
        [string, string] [_, sessionId] = assertInvocationHeaders(response);
        test:assertEquals(sessionId, "session-from-config", path);
        test:assertEquals((check contextOf(response)).sessionId, "session-from-config", path);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundrySessionIdLastQueryValueWins() returns error? {
    // As Starlette's `query_params.get`, a repeated parameter resolves to its last value.
    http:Response response = check foundryInvClient->post(
        "/invocations?agent_session_id=first&agent_session_id=second", {});
    [string, string] [_, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(sessionId, "second");
}

@test:Config {groups: ["foundry"]}
function testFoundrySessionIdQueryParsing() returns error? {
    // The raw query is parsed as `parse_qsl` does: a comma is part of the value, so `a,b` and `,` are
    // invalid and replaced by a new UUID (not by "b", and not by the configured session ID).
    foreach string query in ["agent_session_id=a,b", "agent_session_id=,", "agent_session_id=%20abc",
            "agent_session_id=a+b", "agent_session_id=%FF"] {
        http:Response response = check foundryInvClient->post("/invocations?" + query, {});
        [string, string] [_, sessionId] = assertInvocationHeaders(response);
        test:assertTrue(UUID_PATTERN.isFullMatch(sessionId), string `${query}: ${sessionId}`);
    }
    // The name and the value are both percent-decoded.
    map<string> decoded = {
        "agent%5Fsession%5Fid=enc-key": "enc-key",
        "agent_session_id=%61bc%3A1": "abc:1",
        "x=1&&agent_session_id=s-2&y": "s-2"
    };
    foreach [string, string] [query, expected] in decoded.entries() {
        http:Response response = check foundryInvClient->post("/invocations?" + query, {});
        [string, string] [_, sessionId] = assertInvocationHeaders(response);
        test:assertEquals(sessionId, expected, query);
    }
    // A last occurrence with no value counts as absent, so the configured session ID is used.
    http:Response response = check foundryInvClient->post("/invocations?agent_session_id=x&agent_session_id", {});
    [string, string] [_, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(sessionId, "session-from-config");
}

@test:Config {groups: ["foundry"]}
function testFoundryRawQueryParamValue() {
    string name = "agent_session_id";
    test:assertEquals(lastRawQueryParamValue("/invocations", name), ());
    test:assertEquals(lastRawQueryParamValue("/invocations?", name), ());
    test:assertEquals(lastRawQueryParamValue("/invocations?other=1", name), ());
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id", name), "");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=", name), "");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=a,b", name), "a,b");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=,", name), ",");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=a&agent_session_id=b", name), "b");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=a=b", name), "a=b");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=+a+", name), " a ");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=%2B", name), "+");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent%5fsession_id=k", name), "k");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=caf%C3%A9", name), "café");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=%zz%4", name), "%zz%4");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=a%FFb", name), "a\u{FFFD}b");
    test:assertEquals(lastRawQueryParamValue("/invocations?agent_session_id=s#frag", name), "s");
    test:assertEquals(lastRawQueryParamValue("/invocations?%20agent_session_id=s", name), ());
}

@test:Config {groups: ["foundry"]}
function testFoundrySessionIdGenerated() returns error? {
    http:Response first = check foundryInvLocalClient->post("/invocations", {});
    test:assertEquals(first.statusCode, 200);
    [string, string] [_, firstSession] = assertInvocationHeaders(first);
    test:assertTrue(UUID_PATTERN.isFullMatch(firstSession), firstSession);
    test:assertEquals((check contextOf(first, nested = false)).sessionId, firstSession);

    http:Response second = check foundryInvLocalClient->post("/invocations?agent_session_id=", {});
    [string, string] [_, secondSession] = assertInvocationHeaders(second);
    test:assertTrue(UUID_PATTERN.isFullMatch(secondSession), secondSession);
    test:assertNotEquals(firstSession, secondSession);
}

@test:Config {groups: ["foundry"]}
function testFoundryInvalidSessionIdReplaced() returns error? {
    string tooLong = string:'join("", ...from int i in 0 ..< 257 select "a");
    foreach string query in [tooLong, "bad%20id", "bad%21id", "bad/id", "caf%C3%A9"] {
        http:Response response = check foundryInvClient->post("/invocations?agent_session_id=" + query, {});
        test:assertEquals(response.statusCode, 200, query);
        [string, string] [_, sessionId] = assertInvocationHeaders(response);
        // An invalid query value is replaced by a new UUID, not by the configured session ID.
        test:assertTrue(UUID_PATTERN.isFullMatch(sessionId), string `${query}: ${sessionId}`);
        test:assertEquals((check contextOf(response)).sessionId, sessionId);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryValidSessionIdKept() returns error? {
    string longest = string:'join("", ...from int i in 0 ..< 256 select "b");
    foreach string sessionId in [longest, "Az09-_.:x", "a", "conversation:42.7_b-c"] {
        http:Response response = check foundryInvClient->post("/invocations?agent_session_id=" + sessionId, {});
        [string, string] [_, actual] = assertInvocationHeaders(response);
        test:assertEquals(actual, sessionId);
    }
}

// ===== Invocation ID =====

@test:Config {groups: ["foundry"]}
function testFoundryInvocationIdFromHeader() returns error? {
    string longest = string:'join("", ...from int i in 0 ..< 256 select "c");
    foreach string invocationId in ["inv-123:abc.def_X", longest] {
        http:Response response = check foundryInvClient->post("/invocations", {},
            {"x-agent-invocation-id": invocationId});
        test:assertEquals(response.statusCode, 200);
        [string, string] [actual, _] = assertInvocationHeaders(response);
        test:assertEquals(actual, invocationId);
        test:assertEquals((check contextOf(response)).invocationId, invocationId);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryInvalidInvocationIdReplaced() returns error? {
    string tooLong = string:'join("", ...from int i in 0 ..< 257 select "d");
    map<string>[] headerSets = [{}, {"x-agent-invocation-id": ""}, {"x-agent-invocation-id": "bad id"},
        {"x-agent-invocation-id": "bad/id"}, {"x-agent-invocation-id": tooLong}];
    string[] seen = [];
    foreach map<string> headers in headerSets {
        http:Response response = check foundryInvClient->post("/invocations", {}, headers);
        test:assertEquals(response.statusCode, 200);
        [string, string] [invocationId, _] = assertInvocationHeaders(response);
        test:assertTrue(UUID_PATTERN.isFullMatch(invocationId), invocationId);
        test:assertEquals((check contextOf(response)).invocationId, invocationId);
        test:assertTrue(seen.indexOf(invocationId) is (), "a generated invocation ID was reused");
        seen.push(invocationId);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryIdHelpers() {
    test:assertEquals(sanitizeFoundryId("abc"), "abc");
    test:assertEquals(sanitizeFoundryId("a-b_c.d:e"), "a-b_c.d:e");
    test:assertEquals(sanitizeFoundryId("bad id", "fallback"), "fallback");
    test:assertEquals(sanitizeFoundryId("", "fallback"), "fallback");
    test:assertEquals(sanitizeFoundryId((), "fallback"), "fallback");
    // A trailing newline is rejected (Python's `$` would accept it).
    test:assertEquals(sanitizeFoundryId("abc\n", "fallback"), "fallback");
    test:assertTrue(UUID_PATTERN.isFullMatch(sanitizeFoundryId("bad id")));
    test:assertTrue(UUID_PATTERN.isFullMatch(sanitizeFoundryId(())));

    test:assertEquals(resolveInvokeSessionId("query", "config"), "query");
    test:assertEquals(resolveInvokeSessionId("", "config"), "config");
    test:assertEquals(resolveInvokeSessionId((), "config"), "config");
    test:assertTrue(UUID_PATTERN.isFullMatch(resolveInvokeSessionId((), "")));
    test:assertTrue(UUID_PATTERN.isFullMatch(resolveInvokeSessionId((), ())));
    // An invalid configured session ID is replaced by a UUID too.
    test:assertTrue(UUID_PATTERN.isFullMatch(resolveInvokeSessionId((), "bad id")));

    test:assertEquals(resolveInvokeInvocationId("inv-1"), "inv-1");
    test:assertTrue(UUID_PATTERN.isFullMatch(resolveInvokeInvocationId("inv 1")));
}

// ===== Platform context =====

@test:Config {groups: ["foundry"]}
function testFoundryUserAndCallIds() returns error? {
    http:Response response = check foundryInvClient->post("/invocations", {},
        {"x-agent-user-id": "user-1", "x-agent-foundry-call-id": "opaque.call/id==", "x-test-header": "raw"});
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    map<json> context = check contextOf(response);
    test:assertEquals(context.userId, "user-1");
    test:assertEquals(context.callId, "opaque.call/id==");
    test:assertEquals(context.testHeader, "raw");
    test:assertEquals(context.agent, testAgentInfo.toJson());

    // Empty values are treated as absent.
    response = check foundryInvClient->post("/invocations", {},
        {"x-agent-user-id": "", "x-agent-foundry-call-id": ""});
    context = check contextOf(response);
    test:assertEquals(context.userId, ());
    test:assertEquals(context.callId, ());

    response = check foundryInvClient->post("/invocations", {});
    context = check contextOf(response);
    test:assertEquals(context.userId, ());
    test:assertEquals(context.callId, ());
    test:assertEquals(context.testHeader, ());
}

@test:Config {groups: ["foundry"]}
function testFoundryClientHeaders() returns error? {
    http:Response response = check foundryInvClient->post("/invocations", {}, {
        "X-Client-Foo": "a",
        "x-client-bar": "b",
        "X-CLIENT-Baz-Qux": "c",
        "x-client-multi": ["1", "2"],
        "x-clientless": "not a client header",
        "x-other": "z"
    });
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    map<json> context = check contextOf(response);
    test:assertEquals(context.clientHeaders, {
        "x-client-foo": "a",
        "x-client-bar": "b",
        "x-client-baz-qux": "c",
        "x-client-multi": "1, 2"
    });

    response = check foundryInvClient->post("/invocations", {});
    context = check contextOf(response);
    test:assertEquals(context.clientHeaders, {});
}

@test:Config {groups: ["foundry"]}
function testFoundryTraceHeaders() returns error? {
    string traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    http:Response response = check foundryInvClient->post("/invocations", {}, {
        "traceparent": traceparent,
        "tracestate": "vendor=value",
        "baggage": "key=value",
        "x-request-id": "request-1",
        "x-ms-client-request-id": "client-request-1"
    });
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    map<json> context = check contextOf(response);
    test:assertEquals(context.trace, {
        traceparent,
        tracestate: "vendor=value",
        baggage: "key=value",
        requestId: "request-1",
        clientRequestId: "client-request-1"
    });

    response = check foundryInvClient->post("/invocations", {});
    context = check contextOf(response);
    test:assertEquals(context.trace,
            {traceparent: (), tracestate: (), baggage: (), requestId: (), clientRequestId: ()});
}

@test:Config {groups: ["foundry"]}
function testFoundryLocalRunWithoutPlatformHeaders() returns error? {
    http:Response response = check foundryInvLocalClient->post("/invocations", "ignored body");
    test:assertEquals(response.statusCode, 200);
    [string, string] [invocationId, sessionId] = assertInvocationHeaders(response);
    test:assertTrue(UUID_PATTERN.isFullMatch(invocationId), invocationId);
    test:assertTrue(UUID_PATTERN.isFullMatch(sessionId), sessionId);
    assertPlatformServer(response);
    _ = assertGeneratedRequestId(response);
    test:assertEquals(check response.getJsonPayload(), {
        sessionId,
        invocationId,
        userId: (),
        callId: (),
        originalSubject: (),
        clientHeaders: {},
        trace: {traceparent: (), tracestate: (), baggage: (), requestId: (), clientRequestId: ()},
        agent: {projectEndpoint: (), projectArmId: (), name: (), version: (), id: (), sessionId: ()},
        testHeader: ()
    });
}

// ===== Original subject =====

@test:Config {groups: ["foundry"]}
function testFoundryOriginalSubjectValid() returns error? {
    [string, json][] cases = [
        ["oid=\"o1\", tid=\"t1\", idtype=\"user\"", {oid: "o1", tid: "t1", idtype: "user"}],
        ["tid=\"t1\"", {oid: (), tid: "t1", idtype: ()}],
        ["idtype=\"app\",oid=\"o2\"", {oid: "o2", tid: (), idtype: "app"}],
        ["oid=\"a\\\"b\\\\c\"", {oid: "a\"b\\c", tid: (), idtype: ()}],
        ["oid=\"\"", {oid: "", tid: (), idtype: ()}],
        ["oid=\"x\" ,\ttid=\"y\"", {oid: "x", tid: "y", idtype: ()}]
    ];
    foreach [string, json] [header, expected] in cases {
        http:Response response = check foundryInvClient->post("/invocations", {},
            {"x-ms-original-subject": header});
        test:assertEquals(response.statusCode, 200, header);
        _ = assertInvocationHeaders(response);
        test:assertEquals((check contextOf(response)).originalSubject, expected, header);
    }
    http:Response response = check foundryInvClient->post("/invocations", {});
    test:assertEquals((check contextOf(response)).originalSubject, ());
}

@test:Config {groups: ["foundry"]}
function testFoundryOriginalSubjectInvalid() returns error? {
    (string|string[])[] cases = [
        "foo=\"x\"",
        "oid=\"a\", oid=\"b\"",
        "oid=\"a\" tid=\"b\"",
        "oid=\"a\",",
        "oid=\"a\", ",
        "",
        "oid=\"a\";p=1",
        "oid=a",
        "oid=\"a\\x\"",
        "oid=\"unterminated",
        ",oid=\"a\"",
        ["oid=\"a\"", "tid=\"b\""]
    ];
    foreach string|string[] header in cases {
        int calledBefore = foundryInvocationsCalledCount();
        http:Response response = check foundryInvClient->post("/invocations?agent_session_id=sess-os", {},
            {"x-ms-original-subject": header, "x-agent-invocation-id": "inv-os"});
        test:assertEquals(response.statusCode, 400, header.toString());
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "invalid_request", message: "Invalid original-subject platform header."}},
                header.toString());
        test:assertEquals(check response.getHeader("x-platform-error-source"), "platform");
        test:assertEquals(check response.getHeader("x-platform-error-detail"), "invalid_original_subject");
        test:assertEquals(check response.getHeader("x-agent-invocation-id"), "inv-os");
        test:assertEquals(check response.getHeader("x-agent-session-id"), "sess-os");
        assertPlatformServer(response);
        test:assertEquals(foundryInvocationsCalledCount(), calledBefore, "the user resource was called");
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryParseOriginalSubject() {
    test:assertEquals(parseOriginalSubject([]), ());
    FoundryOriginalSubject all = {oid: "o", tid: "t", idtype: "i"};
    test:assertEquals(parseOriginalSubject(["oid=\"o\",tid=\"t\",idtype=\"i\""]), all);
    FoundryOriginalSubject expected = {oid: "o"};
    test:assertEquals(parseOriginalSubject([" \toid=\"o\"\t "]), expected);
    expected = {oid: " !#[]~"};
    test:assertEquals(parseOriginalSubject(["oid=\" !#[]~\""]), expected);
    foreach string header in ["", " ", "oid=\"é\"", "oid=\"a\tb\"", "OID=\"a\"", "oid =\"a\"", "oid=\"a\",,tid=\"b\"",
            "oid=\"a\" , ", "oid=\"a\"x", "oid=\"a\\\""] {
        FoundryOriginalSubject|FoundryOriginalSubjectError? result = parseOriginalSubject([header]);
        if result !is FoundryOriginalSubjectError {
            test:assertFail(string `'${header}' was accepted`);
        }
        // The error never quotes the header.
        test:assertFalse(header.trim().length() > 2 && result.message().includes(header), result.message());
    }
    test:assertTrue(parseOriginalSubject(["oid=\"a\"", "oid=\"a\""]) is FoundryOriginalSubjectError);
}

// ===== Payload binding =====

@test:Config {groups: ["foundry"]}
function testFoundryJsonPayload() returns error? {
    http:Response response = check foundryInvClient->post("/invocations", {message: "hi", count: 2});
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    json body = check response.getJsonPayload();
    test:assertEquals(check body.payload, {message: "hi", count: 2});

    // An empty body binds to () for a json payload, which accepts nil.
    response = check foundryInvClient->post("/invocations", ());
    test:assertEquals(response.statusCode, 200);
    body = check response.getJsonPayload();
    test:assertEquals(check body.payload, ());

    response = check foundryInvClient->post("/invocations", "{not json", mediaType = "application/json");
    assertPayloadRejected(response, "The request body is not valid JSON.");
}

@test:Config {groups: ["foundry"]}
function testFoundryRecordPayload() returns error? {
    http:Response response = check foundryInvRecordClient->post("/invocations?agent_session_id=s-1",
        {id: "o1", quantity: 2});
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    test:assertEquals(check response.getJsonPayload(), {'order: {id: "o1", quantity: 2}, sessionId: "s-1"});

    int calledBefore = foundryInvocationsCalledCount();
    // A closed record rejects an unknown field, a wrong type, a missing field and a fraction for an int.
    foreach json payload in [{id: "o1", quantity: 2, extra: true}, {id: "o1", quantity: "two"}, {id: "o1"},
            {id: "o1", quantity: 1.5}, [1, 2], "text"] {
        response = check foundryInvRecordClient->post("/invocations", payload.toJsonString(),
            mediaType = "application/json");
        assertPayloadRejected(response, "The request body does not match the expected payload type.",
                payload.toJsonString());
    }
    response = check foundryInvRecordClient->post("/invocations", ());
    assertPayloadRejected(response, "The request body is empty.");
    response = check foundryInvRecordClient->post("/invocations", "{\"id\": ", mediaType = "application/json");
    assertPayloadRejected(response, "The request body is not valid JSON.");
    test:assertEquals(foundryInvocationsCalledCount(), calledBefore, "the user resource was called");
}

@test:Config {groups: ["foundry"]}
function testFoundryArrayPayload() returns error? {
    http:Response response = check foundryInvArrayClient->post("/invocations",
        [{id: "a", quantity: 1}, {id: "b", quantity: 2}]);
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    test:assertEquals(check response.getJsonPayload(), 2);

    response = check foundryInvArrayClient->post("/invocations", [{id: "a"}]);
    assertPayloadRejected(response, "The request body does not match the expected payload type.");
}

@test:Config {groups: ["foundry"]}
function testFoundryStringPayload() returns error? {
    http:Response response = check foundryInvTextClient->post("/invocations", "hello");
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    test:assertEquals(check response.getTextPayload(), "got:hello");
    test:assertTrue((check response.getHeader("content-type")).startsWith("text/plain"));

    // The declared type decides how the body is read, not the content type.
    response = check foundryInvTextClient->post("/invocations", {a: 1});
    test:assertEquals(check response.getTextPayload(), "got:{\"a\":1}");

    response = check foundryInvTextClient->post("/invocations", ());
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "got:");

    byte[] invalidUtf8 = [0xff, 0xfe, 0x41];
    response = check foundryInvTextClient->post("/invocations", invalidUtf8);
    assertPayloadRejected(response, "The request body is not valid UTF-8 text.");
}

@test:Config {groups: ["foundry"]}
function testFoundryBytesPayload() returns error? {
    byte[] payload = [1, 2, 3, 0xff];
    http:Response response = check foundryInvBytesClient->post("/invocations", payload);
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    test:assertEquals(check response.getBinaryPayload(), <byte[]>[1, 2, 3, 0xff, 0]);
    test:assertEquals(check response.getHeader("content-type"), "application/octet-stream");

    response = check foundryInvBytesClient->post("/invocations", ());
    test:assertEquals(check response.getBinaryPayload(), <byte[]>[0]);
}

@test:Config {groups: ["foundry"]}
function testFoundryXmlPayload() returns error? {
    http:Response response = check foundryInvXmlClient->post("/invocations", xml `<a>1</a>`);
    test:assertEquals(response.statusCode, 200);
    _ = assertInvocationHeaders(response);
    test:assertEquals(check response.getXmlPayload(), xml `<got><a>1</a></got>`);
    test:assertTrue((check response.getHeader("content-type")).startsWith("application/xml"));

    response = check foundryInvXmlClient->post("/invocations", "<a>", mediaType = "application/xml");
    assertPayloadRejected(response, "The request body is not valid XML.");
    response = check foundryInvXmlClient->post("/invocations", ());
    assertPayloadRejected(response, "The request body is empty.");
}

@test:Config {groups: ["foundry"]}
function testFoundryBindPayloadBytes() returns error? {
    test:assertEquals(check bindFoundryPayloadBytes("hi".toBytes(), string), "hi");
    test:assertEquals(check bindFoundryPayloadBytes([], string), "");
    test:assertEquals(check bindFoundryPayloadBytes([], StringOrNil), ());
    test:assertEquals(check bindFoundryPayloadBytes([], json), ());
    test:assertEquals(check bindFoundryPayloadBytes("null".toBytes(), json), ());
    test:assertEquals(check bindFoundryPayloadBytes("{\"a\":[1,2]}".toBytes(), IntArrayMap), {a: [1, 2]});
    test:assertEquals(check bindFoundryPayloadBytes("{\"a\":1}".toBytes(), JsonMap), {a: 1});
    test:assertEquals(check bindFoundryPayloadBytes("{\"id\":\"x\",\"quantity\":3}".toBytes(), FoundryTestOrder),
            {id: "x", quantity: 3});
    test:assertTrue(bindFoundryPayloadBytes("x".toBytes(), Choice) is FoundryPayloadBindingError);
    test:assertEquals(check bindFoundryPayloadBytes("yes".toBytes(), Choice), "yes");
    test:assertTrue(bindFoundryPayloadBytes([], FoundryTestOrder) is FoundryPayloadBindingError);
    FoundryPayloadBindingError|anydata fraction = bindFoundryPayloadBytes("{\"id\":\"x\",\"quantity\":1.5}".toBytes(),
            FoundryTestOrder);
    test:assertTrue(fraction is FoundryPayloadBindingError);
    if fraction is FoundryPayloadBindingError {
        test:assertEquals(fraction.message(), "The request body does not match the expected payload type.");
    }
    FoundryPayloadBindingError|anydata malformed = bindFoundryPayloadBytes("{\"id\":".toBytes(), FoundryTestOrder);
    if malformed !is FoundryPayloadBindingError {
        test:assertFail("a malformed body was bound");
    }
    test:assertEquals(malformed.message(), "The request body is not valid JSON.");
    test:assertTrue(bindFoundryPayloadBytes("{\"id\":\"x\",\"quantity\":1,\"x\":1}".toBytes(), FoundryTestOrder)
        is FoundryPayloadBindingError);
    test:assertTrue(bindFoundryPayloadBytes("{\"a\":\"b\"}".toBytes(), IntMap) is FoundryPayloadBindingError);
    test:assertTrue(bindFoundryPayloadBytes("1".toBytes(), StringArray) is FoundryPayloadBindingError);
}

type StringOrNil string?;

type IntArrayMap map<int[]>;

type JsonMap map<json>;

type IntMap map<int>;

type StringArray string[];

type Choice "yes"|"no";

// ===== Results =====

@test:Config {groups: ["foundry"]}
function testFoundryReturnJson() returns error? {
    http:Response response = check postKind("json");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getJsonPayload(), {ok: true});
    test:assertEquals(check response.getHeader("content-type"), "application/json");
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnString() returns error? {
    http:Response response = check postKind("string");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "plain text");
    test:assertTrue((check response.getHeader("content-type")).startsWith("text/plain"));
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnRecord() returns error? {
    http:Response response = check postKind("record");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getJsonPayload(), {id: "r1", quantity: 1});
    test:assertEquals(check response.getHeader("content-type"), "application/json");
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnBytes() returns error? {
    http:Response response = check postKind("bytes");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getBinaryPayload(), <byte[]>[1, 2, 3]);
    test:assertEquals(check response.getHeader("content-type"), "application/octet-stream");
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnXml() returns error? {
    http:Response response = check postKind("xml");
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getXmlPayload(), xml `<result>ok</result>`);
    test:assertTrue((check response.getHeader("content-type")).startsWith("application/xml"));
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnNil() returns error? {
    // As the http module does for a resource without a caller that returns ().
    http:Response response = check postKind("nil");
    test:assertEquals(response.statusCode, 202);
    byte[]|error body = response.getBinaryPayload();
    test:assertTrue(body is error || body.length() == 0);
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnResponse() returns error? {
    http:Response response = check postKind("response", "session-r");
    test:assertEquals(response.statusCode, 207);
    test:assertEquals(check response.getTextPayload(), "multi");
    test:assertEquals(check response.getHeader("x-custom"), "kept");
    // The listener's session ID replaces the one the user set.
    test:assertEquals(check response.getHeaders("x-agent-session-id"), ["session-r"]);
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnCreated() returns error? {
    http:Response response = check postKind("created");
    test:assertEquals(response.statusCode, 201);
    test:assertEquals((check response.getTextPayload()).fromJsonString(), {id: "c1"});
    test:assertEquals(check response.getHeader("location"), "/invocations/c1");
    test:assertEquals(check response.getHeader("x-custom"), "c");
    test:assertEquals(check response.getHeader("content-type"), "application/vnd.test+json");
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnBadRequest() returns error? {
    http:Response response = check postKind("badRequest");
    test:assertEquals(response.statusCode, 400);
    test:assertEquals(check response.getJsonPayload(), {reason: "bad"});
    test:assertEquals(check response.getHeader("content-type"), "application/json");
}

@test:Config {groups: ["foundry"]}
function testFoundryReturnError() returns error? {
    foreach string kind in ["error", "panic", "stream"] {
        http:Response response = check postKind(kind);
        test:assertEquals(response.statusCode, 500, kind);
        test:assertEquals(check response.getJsonPayload(),
                {'error: {code: "internal_error", message: "Internal server error"}}, kind);
        test:assertFalse((check response.getTextPayload()).includes("secret"), kind);
    }
}

@test:Config {groups: ["foundry"]}
function testFoundryMissingInvokeResource() returns error? {
    http:Response response = check foundryInvMissingClient->post("/invocations", {},
        {"x-agent-invocation-id": "inv-missing"});
    test:assertEquals(response.statusCode, 501);
    test:assertEquals(check response.getJsonPayload(), {
        'error: {
            code: "not_implemented",
            message: "The FoundryInvocationService declares no 'post invocations' resource."
        }
    });
    [string, string] [invocationId, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(invocationId, "inv-missing");
    test:assertTrue(UUID_PATTERN.isFullMatch(sessionId), sessionId);
    assertPlatformServer(response);
}

@test:Config {groups: ["foundry"]}
function testFoundryUnsupportedResourceParameter() returns error? {
    int calledBefore = foundryInvocationsCalledCount();
    http:Response response = check foundryInvUnsupportedClient->post("/invocations?extra=1", {});
    test:assertEquals(response.statusCode, 500);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "internal_error", message: "Internal server error"}});
    _ = assertInvocationHeaders(response);
    assertPlatformServer(response);
    test:assertEquals(foundryInvocationsCalledCount(), calledBefore, "the user resource was called");
}

@test:Config {groups: ["foundry"]}
function testFoundryInvocationsWrongMethod() returns error? {
    http:Response response = check foundryInvClient->get("/invocations");
    test:assertEquals(response.statusCode, 405);
    test:assertEquals(check response.getJsonPayload(),
            {'error: {code: "method_not_allowed", message: "Method Not Allowed"}});
    test:assertEquals(check response.getHeader("allow"), "POST");
    assertPlatformServer(response);
    // Only POST /invocations carries the invocation headers.
    test:assertFalse(response.hasHeader("x-agent-invocation-id"));
    test:assertFalse(response.hasHeader("x-agent-session-id"));

    response = check foundryInvClient->put("/invocations", {});
    test:assertEquals(response.statusCode, 405);
    test:assertEquals(check response.getHeader("allow"), "POST");
}

// ===== Concurrency =====

@test:Config {groups: ["foundry"]}
function testFoundryNonIsolatedServiceRunsUnderGlobalLock() returns error? {
    future<http:Response|error>[] inFlight = [];
    foreach int i in 0 ..< 8 {
        future<http:Response|error> request = start postNonIsolatedInvocation(i);
        inFlight.push(request);
    }
    foreach future<http:Response|error> request in inFlight {
        http:Response response = check wait request;
        test:assertEquals(response.statusCode, 200);
    }
    test:assertEquals(foundryNonIsolatedCalls, 8);
    test:assertEquals(foundryNonIsolatedMaxActive, 1, "requests ran in a non-isolated service at the same time");
}

function postNonIsolatedInvocation(int i) returns http:Response|error {
    return foundryInvNonIsolatedClient->post(string `/invocations?agent_session_id=ni-${i}`, {});
}

// ===== Lifecycle =====

@test:Config {groups: ["foundry"]}
function testFoundryGracefulStopLetsInFlightInvocationFinish() returns error? {
    // A short timeout: the http transport's graceful stop always waits the whole timeout.
    FoundryListener foundryListener = check new (FOUNDRY_INV_GRACEFUL_PORT, gracefulStopTimeout = 5, agent = {});
    check foundryListener.attach(new SlowFoundryInvocationService());
    check foundryListener.'start();

    http:Response|error response = postSlowInvocationThenStop(foundryListener, FOUNDRY_INV_GRACEFUL_PORT);
    if response is error {
        test:assertFail(string `the in-flight invocation failed: ${response.message()}`);
    }
    test:assertEquals(response.statusCode, 200);
    test:assertEquals(check response.getTextPayload(), "done:slow-session");
    [string, string] [invocationId, sessionId] = assertInvocationHeaders(response);
    test:assertEquals(invocationId, "slow-invocation");
    test:assertEquals(sessionId, "slow-session");
    assertStopped(FOUNDRY_INV_GRACEFUL_PORT);
}

// ===== Helpers =====

function postKind(string kind, string sessionId = "session-k") returns http:Response|error {
    http:Response response = check foundryInvReturnsClient->post(
        string `/invocations?agent_session_id=${sessionId}`, {kind}, {"x-agent-invocation-id": "inv-" + kind});
    [string, string] [invocationId, actualSession] = assertInvocationHeaders(response);
    test:assertEquals(invocationId, "inv-" + kind);
    test:assertEquals(actualSession, sessionId);
    assertPlatformServer(response);
    return response;
}

function postSlowInvocation(http:Client 'client) returns http:Response|error {
    return 'client->post("/invocations?agent_session_id=slow-session", {},
        {"x-agent-invocation-id": "slow-invocation"});
}

// As `callSlowThenStop`, for a slow `POST /invocations`: stops the listener gracefully once the
// request is known to be running in the user's resource, and returns the request's outcome.
function postSlowInvocationThenStop(FoundryListener foundryListener, int port) returns http:Response|error {
    http:Client 'client = checkpanic new (string `http://localhost:${port}`, timeout = 30);
    int startedBefore = slowRequestsStartedCount();
    future<http:Response|error> inFlight = start postSlowInvocation('client);
    int polls = 0;
    while slowRequestsStartedCount() == startedBefore {
        if polls >= 200 {
            panic error("the slow invocation did not reach the resource within 10 seconds");
        }
        runtime:sleep(0.05);
        polls += 1;
    }
    checkpanic foundryListener.gracefulStop();
    return wait inFlight;
}

// Asserts that a response carries both invocation headers, and returns them.
function assertInvocationHeaders(http:Response response) returns [string, string] {
    string|error invocationId = response.getHeader("x-agent-invocation-id");
    string|error sessionId = response.getHeader("x-agent-session-id");
    if invocationId is error || sessionId is error {
        test:assertFail(string `invocation headers missing on a ${response.statusCode} response`);
    }
    return [invocationId, sessionId];
}

// Returns the context summary of a context-echo response.
function contextOf(http:Response response, boolean nested = true) returns map<json>|error {
    json body = check response.getJsonPayload();
    json context = nested ? check body.context : body;
    map<json> summary = check context.ensureType();
    return summary;
}

function assertPayloadRejected(http:Response response, string message, string description = "") {
    test:assertEquals(response.statusCode, 400, string `${message} ${description}`);
    json|error body = response.getJsonPayload();
    test:assertEquals(body, {'error: {code: "invalid_request", message}});
    string|error errorSource = response.getHeader("x-platform-error-source");
    test:assertEquals(errorSource, "user");
    test:assertFalse(response.hasHeader("x-platform-error-detail"));
    _ = assertInvocationHeaders(response);
    assertPlatformServer(response);
}
