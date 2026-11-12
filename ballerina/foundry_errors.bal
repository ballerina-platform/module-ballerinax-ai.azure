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
import ballerina/log;

// Error classification of the protocol endpoints (`/invocations` and the routes under it), a port of
// `_classify_error` (`inv/_invocation.py:78-92`) and the platform error headers
// (`core/_platform_headers.py:106-130`).
//
// - `upstream`: the agent's code failed, or the agent returned a 4xx/5xx itself. No detail header.
// - `platform`: the listener itself failed. The detail header names the error type and message.
// - `user`: the caller's request is invalid (a body that can't be bound to the payload type, or a
//   request the http module rejects before the listener's resource runs).

// The longest `x-platform-error-detail` value, and the suffix that marks a truncated one
// (`core/_platform_headers.py`, `inv/_invocation.py:88-90`).
const MAX_ERROR_DETAIL_LENGTH = 2048;
const ERROR_DETAIL_TRUNCATION_SUFFIX = "...[truncated]";

// The `http:RequestContext` key a protocol resource sets, so the response interceptor classifies the
// 4xx/5xx responses of protocol requests, and only those.
const PROTOCOL_CONTEXT_KEY = "ballerinax.ai.azure.foundry.protocol";

const INVALID_PATH_MESSAGE = "The request path could not be decoded.";

// The headers the listener owns on a protocol response. An `http:ApplicationResponseError` (an
// `http:Client` call of the agent that got a 4xx/5xx) carries the headers of that other service's
// response, which may be another Foundry agent: these describe that service's request, not this one,
// so they are not copied onto the error response.
final readonly & string[] LISTENER_OWNED_HEADERS = [HEADER_ERROR_SOURCE, HEADER_ERROR_DETAIL, HEADER_INVOCATION_ID,
    HEADER_SESSION_ID];

# A failure of the Foundry listener itself: not of the agent's code and not of the caller's request.
# It is the counterpart of the reference's platform-tagged exceptions (`PLATFORM_ERROR_TAG`), so the
# response is a `500` with `x-platform-error-source: platform` and an `x-platform-error-detail` of
# `"<type>: <message>"`.
#
# The message ends up in a response header, so it is always text the listener writes itself: it
# never quotes the request body, a header value or any other request content, nor a secret.
type FoundryPlatformError distinct error;

# Classifies an error raised while serving a protocol request, as the reference's `_classify_error`
# does: a `FoundryPlatformError` is a `platform` error with a detail, and any other error (one the
# agent's resource returned or panicked with, or a resource the agent declared in a way the listener
# can't call) is an `upstream` error without one.
#
# + err - The error
# + return - The error source and, for a platform error, the detail
isolated function classifyFoundryError(error err) returns [string, string?] {
    if err is FoundryPlatformError {
        return [ERROR_SOURCE_PLATFORM, truncateErrorDetail(string `${errorTypeName(err)}: ${err.message()}`)];
    }
    return [ERROR_SOURCE_UPSTREAM, ()];
}

# Truncates an error detail to at most `MAX_ERROR_DETAIL_LENGTH` characters, as the reference does:
# a longer detail keeps its first `2048 - len("...[truncated]")` characters followed by
# `...[truncated]`, and a detail of at most 2048 characters is unchanged.
#
# + detail - The detail
# + return - The detail, truncated when it is too long
isolated function truncateErrorDetail(string detail) returns string {
    if detail.length() <= MAX_ERROR_DETAIL_LENGTH {
        return detail;
    }
    return detail.substring(0, MAX_ERROR_DETAIL_LENGTH - ERROR_DETAIL_TRUNCATION_SUFFIX.length())
        + ERROR_DETAIL_TRUNCATION_SUFFIX;
}

# Sets the error classification headers on a response.
#
# + response - The response
# + errorSource - The error source: `user`, `upstream` or `platform`
# + detail - The error detail, if any
isolated function setErrorSource(http:Response response, string errorSource, string? detail = ()) {
    response.setHeader(HEADER_ERROR_SOURCE, errorSource);
    if detail is string {
        response.setHeader(HEADER_ERROR_DETAIL, detail);
    }
}

# Builds the response to an error raised while a protocol resource served a request: the agent's
# resource returned or panicked with it, the agent declared the resource in a way the listener can't
# call, or the listener itself failed.
#
# - A `FoundryPlatformError` gives a `500` with `x-platform-error-source: platform` and the detail.
# - Any other error is `upstream`. Its status follows the http module's mapping, so an
#   `httpscerr` status-code error (for example `httpscerr:NotFoundError`) or an
#   `http:ApplicationResponseError` keeps its status and headers, and any other error is a `500` with
#   the generic message `Internal server error`. The error message is never sent in a header.
# - The headers of an `http:ApplicationResponseError` come from another service's response, so the
#   ones the listener owns (`LISTENER_OWNED_HEADERS`) are dropped. The headers of an `httpscerr` error
#   are the agent's choice, as those of an `http:Response` it returns are, so an
#   `x-platform-error-source` the agent set there is kept.
#
# + err - The error
# + request - The request, for logging
# + return - The classified error response
isolated function foundryErrorResponse(error err, http:Request request) returns http:Response {
    if err is FoundryPlatformError {
        log:printError("The Foundry listener failed to handle the request", err, path = request.rawPath,
                method = request.method);
        return platformErrorResponse(err);
    }
    http:Response response = errorToResponse(err, request);
    if err is http:ApplicationResponseError {
        foreach string name in LISTENER_OWNED_HEADERS {
            response.removeHeader(name);
        }
    }
    if !response.hasHeader(HEADER_ERROR_SOURCE) {
        setErrorSource(response, ERROR_SOURCE_UPSTREAM);
    }
    return response;
}

# Builds the `500` response to a failure of the listener itself.
#
# + err - The platform error
# + return - The error response, classified as a platform error with its detail
isolated function platformErrorResponse(FoundryPlatformError err) returns http:Response {
    http:Response response = errorResponse(http:STATUS_INTERNAL_SERVER_ERROR, ERROR_CODE_INTERNAL_ERROR,
            "Internal server error");
    [string, string?] [errorSource, detail] = classifyFoundryError(err);
    setErrorSource(response, errorSource, detail);
    return response;
}

# Builds the response to an error the http module raised for a protocol request before (or instead
# of) the listener's resource, for example a path segment that can't be decoded.
#
# A `4xx` is about the caller's request, so it is a `user` error. A `5xx` is a failure of the
# listener's own HTTP stack, so it is a `platform` error; its detail names only the error's type,
# because an http module message can quote the request.
#
# + err - The error
# + request - The request
# + return - The classified error response
isolated function httpModuleErrorResponse(error err, http:Request request) returns http:Response {
    if err is http:PathParameterBindingError || hasMalformedPercentEncoding(pathOf(request.rawPath)) {
        // The http module fails to decode a malformed escape in the path with a plain error (a `500`),
        // and an ID that still holds one after its first decoding (`%25zz`; http decodes a path
        // parameter twice) with a path-parameter binding error. Either way the caller sent a path
        // that can't be decoded, so it is a `400` with a fixed message (http's names the parameter).
        return invalidPathResponse();
    }
    if statusCodeOf(err) < 500 {
        http:Response response = errorToResponse(err, request);
        setErrorSource(response, ERROR_SOURCE_USER);
        return response;
    }
    log:printError("The http module failed to handle a Foundry protocol request", err, path = request.rawPath,
            method = request.method);
    return platformErrorResponse(error FoundryPlatformError(
        string `the http module failed to handle the request (${errorTypeName(err)})`));
}

# Builds the `400` response to a protocol request whose path can't be decoded. It is the caller's
# mistake, so it is classified as a `user` error.
#
# + return - The error response
isolated function invalidPathResponse() returns http:Response {
    http:Response response = errorResponse(http:STATUS_BAD_REQUEST, ERROR_CODE_INVALID_REQUEST,
            INVALID_PATH_MESSAGE);
    setErrorSource(response, ERROR_SOURCE_USER);
    return response;
}

# Returns whether a request is a protocol request: a protocol resource served it, or its path has the
# shape of a protocol route (for an error the http module raised before any resource ran).
#
# + ctx - The request context
# + request - The request
# + return - `true` for a protocol request
isolated function isProtocolRequest(http:RequestContext ctx, http:Request request) returns boolean =>
    ctx.hasKey(PROTOCOL_CONTEXT_KEY) || isProtocolPath(pathOf(request.rawPath));

# Returns whether a raw path (without the query) has the shape of a protocol route:
# `/invocations`, `/invocations/{invocationId}`, `/invocations/{invocationId}/cancel` or
# `/invocations/docs/openapi.json`.
#
# + path - The raw request path
# + return - `true` for a protocol route
isolated function isProtocolPath(string path) returns boolean {
    string trimmed = path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
    if !trimmed.startsWith("/") {
        return false;
    }
    string[] segments = re `/`.split(trimmed.substring(1));
    if segments.length() == 0 || segments.length() > 3 || segments[0] != INVOCATIONS_PATH
            || segments.indexOf("") !is () {
        return false;
    }
    return segments.length() < 3 || segments[2] == CANCEL_PATH
        || (segments[1] == DOCS_PATH && segments[2] == OPENAPI_PATH);
}

# Returns the path of a raw request target, without the query or fragment.
#
# + target - The raw request target, for example `/invocations?agent_session_id=s-1`
# + return - The path
isolated function pathOf(string target) returns string {
    int? queryStart = target.indexOf("?");
    string path = queryStart is int ? target.substring(0, queryStart) : target;
    int? fragmentStart = path.indexOf("#");
    return fragmentStart is int ? path.substring(0, fragmentStart) : path;
}

# Returns whether a raw path holds a `%` that doesn't start a two-hex-digit escape.
#
# + path - The raw path
# + return - `true` when the path is not validly percent-encoded
isolated function hasMalformedPercentEncoding(string path) returns boolean {
    int length = path.length();
    int i = 0;
    while i < length {
        if path[i] == "%" {
            if i + 2 >= length || !isHexDigit(path[i + 1]) || !isHexDigit(path[i + 2]) {
                return true;
            }
            i += 3;
            continue;
        }
        i += 1;
    }
    return false;
}
