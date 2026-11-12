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
import ballerinax/ai.azure;

listener azure:FoundryListener jsonListener = new (9101);
listener azure:FoundryListener textListener = new (9102);
listener azure:FoundryListener bytesListener = new (9103);
listener azure:FoundryListener xmlListener = new (9104);
listener azure:FoundryListener recordListener = new (9105);
listener azure:FoundryListener arrayListener = new (9106);
listener azure:FoundryListener noParamsListener = new (9107);
listener azure:FoundryListener mapListener = new (9108);

type Order record {|
    string id;
    int quantity;
|};

// A type alias of the context is still the context.
type Context azure:FoundryContext;

// A named union return type.
type InvokeResult json|http:Response|http:Created|error;

// Every resource, context after the payload, union returns with `http:Response`, a status-code record and `error?`.
service azure:FoundryInvocationService on jsonListener {
    resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx) returns json|error {
        return {reply: payload, session: ctx.sessionId};
    }

    resource function get invocations/[string invocationId](azure:FoundryContext ctx) returns http:Response|error {
        http:Response response = new;
        response.setJsonPayload({id: invocationId, session: ctx.sessionId});
        return response;
    }

    resource function post invocations/[string invocationId]/cancel(azure:FoundryContext ctx,
            @http:Payload json? reason) returns http:Accepted|http:NotFound|error? {
        if reason is () {
            return;
        }
        http:Accepted accepted = {body: {id: invocationId, session: ctx.sessionId}};
        return accepted;
    }
}

// Context before the payload, a `string` payload, `()` returns and no return type, at the `/` base path.
service azure:FoundryInvocationService / on textListener {
    resource function post invocations(azure:FoundryContext ctx, @http:Payload string text) returns string =>
        string `${ctx.invocationId}:${text}`;

    resource function get invocations/[string invocationId]() returns () {
    }

    resource function post invocations/[string invocationId]/cancel() {
    }
}

// A `byte[]` payload, at the `"/"` base path.
service azure:FoundryInvocationService "/" on bytesListener {
    resource function post invocations(@http:Payload byte[] bytes) returns byte[] => bytes;
}

// An `xml` payload.
service azure:FoundryInvocationService on xmlListener {
    resource function post invocations(@http:Payload xml document) returns xml => document;

    resource function post invocations/[string invocationId]/cancel(@http:Payload xml reason) returns xml => reason;
}

// A record payload, the context through a type alias, and status-code records.
service azure:FoundryInvocationService on recordListener {
    resource function post invocations(@http:Payload Order 'order, Context ctx)
            returns http:Created|http:BadRequest|error {
        if 'order.quantity < 1 {
            http:BadRequest badRequest = {body: {session: ctx.sessionId}};
            return badRequest;
        }
        http:Created created = {body: 'order};
        return created;
    }
}

// An array payload and a union of `anydata` types with `error?`.
service azure:FoundryInvocationService on arrayListener {
    resource function post invocations(@http:Payload Order[] orders) returns int|map<json>|error? =>
        orders.length();
}

// No parameters and a named union return type, in an isolated service.
isolated service azure:FoundryInvocationService on noParamsListener {
    isolated resource function post invocations() returns InvokeResult {
        json result = {status: "ok"};
        return result;
    }
}

// A map payload with a default value, and the `http:StatusCodeResponse` union itself.
service azure:FoundryInvocationService on mapListener {
    resource function post invocations(@http:Payload map<json> payload = {}) returns http:StatusCodeResponse =>
        <http:Ok>{body: payload};
}

listener azure:FoundryListener untypedListener = new (9109);
listener azure:FoundryListener intersectionListener = new (9110);
listener azure:FoundryListener escapedListener = new (9111);

// A service declaration without a type descriptor takes its type from the listener, and is validated (and valid).
service on untypedListener {
    resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx) returns json =>
        {reply: payload, session: ctx.sessionId};

    resource function get invocations/[string invocationId]() returns json => {id: invocationId};
}

// An untyped declaration on an inline listener, at the `/` base path.
service / on new azure:FoundryListener(9112) {
    resource function post invocations() returns string => "ok";
}

// An intersection return type that is a subtype of the supported union, though no single member category holds it.
service azure:FoundryInvocationService on intersectionListener {
    resource function post invocations(@http:Payload json payload) returns readonly & (json|error) =>
        payload.cloneReadOnly();
}

// A base path literal whose value is "/" (written with an escape).
service azure:FoundryInvocationService "\u{2F}" on escapedListener {
    resource function post invocations() returns json => {};
}
