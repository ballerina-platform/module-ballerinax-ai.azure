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

// Guards for the parts of `NativeFoundryResourceInvoker` that depend on internals of the http module, for
// which the http module has no public API. Each test fails when the http module changes the internal it
// relies on, so an http upgrade that breaks the listener fails the build instead of a request at run time:
// - `createFoundryHeaders` sets the private `request` field of `http:Headers` (it has no public `init`).
// - Payload detection reads the parameter annotations the compiler stores on a resource under
//   `$param$.<parameter name>`, and recognizes `@http:Payload` by its key `ballerina/http:<major>:Payload`.

@test:Config {groups: ["foundry"]}
function testFoundryHeadersBackedByRequest() returns error? {
    http:Request request = new;
    request.setHeader("x-test-header", "value-1");
    request.addHeader("x-test-header", "value-2");
    request.setHeader("x-other", "other");

    http:Headers headers = createFoundryHeaders(request);
    test:assertTrue(headers.hasHeader("x-test-header"));
    test:assertEquals(check headers.getHeader("x-test-header"), "value-1");
    test:assertEquals(check headers.getHeaders("x-test-header"), ["value-1", "value-2"]);
    test:assertEquals(check headers.getHeader("x-other"), "other");
    test:assertTrue(headers.getHeader("x-missing") is http:HeaderNotFoundError);
    string[] names = headers.getHeaderNames();
    test:assertTrue(names.indexOf("x-test-header") !is (), names.toString());
    test:assertTrue(names.indexOf("x-other") !is (), names.toString());
}

type FoundryInternalsPayload record {|
    string message;
|};

@test:Config {groups: ["foundry"]}
function testFoundryPayloadAnnotationDetected() returns error? {
    FoundryInvocationService foundryService = service object {
        resource function get readiness() returns json => {status: "healthy"};

        resource function post invocations(FoundryContext ctx, @http:Payload FoundryInternalsPayload payload)
                returns json => payload.message;

        resource function get invocations/[string invocationId](@http:Payload json payload) returns json
            => invocationId;

        resource function post invocations/[string invocationId]/cancel(FoundryContext ctx) returns json
            => invocationId;
    };
    FoundryDispatcherService dispatcher = new ({agent: {}, openApiSpec: ()});
    setFoundryService(dispatcher, foundryService);

    // The `@http:Payload` parameter is found after the context parameter, with its declared type.
    FoundryResourceSignature signature = check foundryResourceSignature(dispatcher, "post", ["invocations"]);
    assertFoundryPayloadType(signature, FoundryInternalsPayload);
    test:assertTrue(signature.hasContext);

    // After a path parameter.
    signature = check foundryResourceSignature(dispatcher, "get", ["invocations", "^"]);
    assertFoundryPayloadType(signature, json);
    test:assertFalse(signature.hasContext);

    // A resource without `@http:Payload` reports none.
    signature = check foundryResourceSignature(dispatcher, "post", ["invocations", "^", "cancel"]);
    test:assertEquals(signature.payloadType, ());
    test:assertTrue(signature.hasContext);

    unlinkFoundryService(dispatcher);
}

@test:Config {groups: ["foundry"]}
function testFoundryUnannotatedParameterRejected() returns error? {
    // Without the annotation, a payload-typed parameter is neither the payload nor the context.
    FoundryInvocationService foundryService = service object {
        resource function get readiness() returns json => {status: "healthy"};

        resource function post invocations(json payload) returns json => payload;
    };
    FoundryDispatcherService dispatcher = new ({agent: {}, openApiSpec: ()});
    setFoundryService(dispatcher, foundryService);
    FoundryResourceSignature|error? signature = getFoundryResourceSignature(dispatcher, "post", ["invocations"]);
    test:assertTrue(signature is error, "expected an error for a parameter without '@http:Payload'");
    unlinkFoundryService(dispatcher);
}

isolated function foundryResourceSignature(FoundryDispatcherService dispatcher, string accessor, string[] path)
        returns FoundryResourceSignature|error {
    FoundryResourceSignature|error? signature = getFoundryResourceSignature(dispatcher, accessor, path);
    if signature is () {
        return error(string `no resource '${accessor} ${string:'join("/", ...path)}'`);
    }
    return signature;
}

// typedesc values are not anydata, so they are compared by the type they describe.
isolated function assertFoundryPayloadType(FoundryResourceSignature signature, typedesc<anydata> expected) {
    typedesc<anydata>? actual = signature.payloadType;
    if actual is () {
        test:assertFail(string `expected payload type ${expected.toString()}, got none`);
    }
    test:assertEquals(actual.toString(), expected.toString());
}
