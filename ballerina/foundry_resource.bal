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

import ballerina/data.jsondata;
import ballerina/http;
import ballerina/jballerina.java;
import ballerina/log;

// Calling the resources of the user's FoundryInvocationService: finding a resource, binding the
// request body to its payload parameter and calling it.

const INVOCATIONS_PATH = "invocations";

// Messages of the `400` error response when the request body can't be bound to the declared payload
// type. They never contain the body.
const PAYLOAD_EMPTY_MESSAGE = "The request body is empty.";
const PAYLOAD_UNREADABLE_MESSAGE = "The request body could not be read.";
const PAYLOAD_NOT_TEXT_MESSAGE = "The request body is not valid UTF-8 text.";
const PAYLOAD_NOT_XML_MESSAGE = "The request body is not valid XML.";
const PAYLOAD_NOT_JSON_MESSAGE = "The request body is not valid JSON.";
const PAYLOAD_TYPE_MISMATCH_MESSAGE = "The request body does not match the expected payload type.";

# What the dispatcher needs to know about a resource of the user's service before calling it.
#
# + payloadType - The declared type of the `@http:Payload` parameter, or `()` when the resource
# declares none
type FoundryResourceSignature record {|
    typedesc<anydata>? payloadType;
|};

# The request body can't be bound to the declared payload type. The message is safe to send to the
# caller: it never contains the body.
type FoundryPayloadBindingError distinct error;

# The values a resource of the user's service can return, other than a stream, which the http module
# turns into a response itself.
type FoundryResourceResponse anydata|http:Response|http:StatusCodeResponse;

# Binds the request body to the declared payload type.
#
# The declared type, not the `content-type` header, decides how the body is read:
# - a subtype of `string` (or `string?`): the body as UTF-8 text;
# - a subtype of `byte[]`: the body bytes;
# - a subtype of `xml`: the body parsed as XML;
# - any other `anydata` type (`json`, records, maps, arrays, unions): the body parsed as JSON straight
# to the declared type. This is strict: a closed record rejects unknown fields (as the http module's
# record binding does), a fraction is not accepted for an `int`, and constraints are validated.
# An empty body binds to `()` when the type allows it, and to `""` or `[]` for text and bytes; for any
# other type it is an error.
#
# + request - The request
# + payloadType - The declared payload type
# + return - The payload, or an error with a message that is safe to send to the caller
isolated function bindFoundryPayload(http:Request request, typedesc<anydata> payloadType)
        returns anydata|FoundryPayloadBindingError {
    byte[]|http:ClientError body = request.getBinaryPayload();
    if body is http:ClientError {
        return payloadBindingError(PAYLOAD_UNREADABLE_MESSAGE, body);
    }
    return bindFoundryPayloadBytes(body, payloadType);
}

# Binds request body bytes to the declared payload type; see `bindFoundryPayload`.
#
# + body - The request body
# + payloadType - The declared payload type
# + return - The payload, or an error with a message that is safe to send to the caller
isolated function bindFoundryPayloadBytes(byte[] body, typedesc<anydata> payloadType)
        returns anydata|FoundryPayloadBindingError {
    anydata nil = ();
    if body.length() == 0 && nil.ensureType(payloadType) !is error {
        return ();
    }
    if payloadType is typedesc<string?> {
        string|error text = string:fromBytes(body);
        if text is error {
            return payloadBindingError(PAYLOAD_NOT_TEXT_MESSAGE, text);
        }
        return ensurePayloadType(text, payloadType);
    }
    if payloadType is typedesc<byte[]?> {
        return ensurePayloadType(body, payloadType);
    }
    if body.length() == 0 {
        return payloadBindingError(PAYLOAD_EMPTY_MESSAGE);
    }
    if payloadType is typedesc<xml?> {
        string|error text = string:fromBytes(body);
        if text is error {
            return payloadBindingError(PAYLOAD_NOT_XML_MESSAGE, text);
        }
        xml|error document = xml:fromString(text);
        if document is error {
            return payloadBindingError(PAYLOAD_NOT_XML_MESSAGE, document);
        }
        return ensurePayloadType(document, payloadType);
    }
    // The body is parsed straight to the declared type, which is strict: a closed record rejects
    // unknown fields (no data projection, as in the http module's record binding), a number is only
    // accepted for an `int` when it is an integer, and constraints are validated.
    // `parseBytes` is trapped: for some malformed bodies (for example a truncated document) the
    // native parser fails with an error that is not a `jsondata:Error`, which `parseBytes` then
    // panics on. An untrapped panic would leave the request without a response.
    anydata|error payload = trap jsondata:parseBytes(body, {allowDataProjection: false}, payloadType);
    if payload is error {
        // Parse again, untyped, only to tell a malformed body from a type mismatch.
        json|error document = trap jsondata:parseBytes(body);
        return payloadBindingError(document is error ? PAYLOAD_NOT_JSON_MESSAGE
            : PAYLOAD_TYPE_MISMATCH_MESSAGE, payload);
    }
    return payload;
}

isolated function ensurePayloadType(anydata value, typedesc<anydata> payloadType)
        returns anydata|FoundryPayloadBindingError {
    anydata|error payload = value.ensureType(payloadType);
    if payload is error {
        return payloadBindingError(PAYLOAD_TYPE_MISMATCH_MESSAGE, payload);
    }
    return payload;
}

# Creates a payload binding error. The message of the underlying error is neither logged nor sent:
# the parsers quote the offending value in it, and the body may hold personal data or secrets. Only
# the fixed message and the type of the underlying error are logged, at debug level.
#
# + message - The message sent to the caller
# + cause - The underlying error, if any
# + return - The payload binding error
isolated function payloadBindingError(string message, error? cause = ()) returns FoundryPayloadBindingError {
    if cause is error {
        log:printDebug("Foundry request body binding failed: " + message, causeType = errorTypeName(cause));
    }
    return error FoundryPayloadBindingError(message);
}

# Names the type of an error without reading its message or detail.
#
# + err - The error
# + return - The name of the error's type, for example `ConversionError`
isolated function errorTypeName(error err) returns string = @java:Method {
    'class: "io.ballerina.lib.ai.azure.NativeFoundryResourceInvoker"
} external;

# Describes the resource of the user's service with the given accessor and path shape.
#
# + dispatcher - The dispatcher linked with the user's service
# + accessor - The resource accessor, for example `post`
# + path - The resource path shape, with `^` for a path parameter segment
# + return - The resource signature; `()` when the service declares no such resource; or an error
# when the resource declares a parameter that is neither the `@http:Payload` parameter nor an
# `azure:FoundryContext` parameter
isolated function getFoundryResourceSignature(FoundryDispatcherService dispatcher, string accessor,
        string[] path) returns FoundryResourceSignature|error? = @java:Method {
    'class: "io.ballerina.lib.ai.azure.NativeFoundryResourceInvoker"
} external;

# Calls the resource of the user's service with the given accessor and path shape. The arguments are
# passed in the order the resource declares its parameters. A panic in the resource is returned as an
# error, so the request still gets a response.
#
# + dispatcher - The dispatcher linked with the user's service
# + accessor - The resource accessor, for example `post`
# + path - The resource path shape, with `^` for a path parameter segment
# + pathArgs - The values of the path parameters, in order
# + payload - The bound payload; ignored when the resource declares no payload parameter
# + context - The platform context of the request
# + return - The resource's return value, or an error when the resource returns or panics with one, or
# can't be called
isolated function invokeFoundryResource(FoundryDispatcherService dispatcher, string accessor, string[] path,
        string[] pathArgs, anydata payload, FoundryContext context) returns any|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.NativeFoundryResourceInvoker"
} external;
