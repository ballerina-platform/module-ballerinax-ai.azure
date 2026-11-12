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
import ballerina/jballerina.java;
import ballerina/uuid;

// Session and invocation IDs, and the platform request context of a Foundry request. These functions
// don't depend on the dispatcher, so the get/cancel routes and a future WebSocket listener reuse them.

// Request and response headers of the Invocations protocol (`core/_platform_headers.py`,
// `inv/_constants.py`).
const HEADER_INVOCATION_ID = "x-agent-invocation-id";
const HEADER_SESSION_ID = "x-agent-session-id";
const HEADER_USER_ID = "x-agent-user-id";
const HEADER_FOUNDRY_CALL_ID = "x-agent-foundry-call-id";
const HEADER_ORIGINAL_SUBJECT = "x-ms-original-subject";
const HEADER_TRACESTATE = "tracestate";
const HEADER_BAGGAGE = "baggage";
const HEADER_CLIENT_REQUEST_ID = "x-ms-client-request-id";
const CLIENT_HEADER_PREFIX = "x-client-";
const QUERY_AGENT_SESSION_ID = "agent_session_id";

// The longest accepted session or invocation ID (`inv/_invocation.py:96`).
const MAX_ID_LENGTH = 256;
// The characters a session or invocation ID may contain (`inv/_invocation.py:97`).
final readonly & string:RegExp VALID_ID_PATTERN = re `[a-zA-Z0-9\-_.:]+`;

// The original-subject dictionary members (`core/_request_context.py:52`).
final readonly & string[] ORIGINAL_SUBJECT_MEMBERS = ["oid", "tid", "idtype"];

# The `x-ms-original-subject` header doesn't match the dictionary profile the platform uses. The
# message never contains the header value.
type FoundryOriginalSubjectError distinct error;

# Validates a session or invocation ID sent by the caller (`_sanitize_id`, `inv/_invocation.py:135-152`).
#
# An ID is valid when it has 1-256 characters, all of them ASCII letters, digits, `-`, `_`, `.` or `:`.
# The whole value must match: unlike the reference's `re.match` with `$`, a trailing newline is not
# accepted, so an ID can never break a response header.
#
# + value - The ID sent by the caller; `()` or `""` when none was sent
# + fallback - The value to use when the ID is missing or invalid; when it is `()`, a new UUID is used
# + return - The ID when it is valid, otherwise the fallback or a new UUID
isolated function sanitizeFoundryId(string? value, string? fallback = ()) returns string {
    if value is string && value.length() <= MAX_ID_LENGTH && VALID_ID_PATTERN.isFullMatch(value) {
        return value;
    }
    return fallback ?: uuid:createType4AsString();
}

# Resolves the invocation ID of a `POST /invocations` request: the `x-agent-invocation-id` header when
# it is valid, otherwise a new UUID (`inv/_invocation.py:542-544`).
#
# + header - The first `x-agent-invocation-id` header value, if any
# + return - The invocation ID
isolated function resolveInvokeInvocationId(string? header) returns string => sanitizeFoundryId(header);

# Resolves the session ID of a `POST /invocations` request (`inv/_invocation.py:547-550`): the
# `agent_session_id` query parameter, else the agent's configured session ID
# (`FOUNDRY_AGENT_SESSION_ID`), else a new UUID. An empty value counts as absent, and an invalid value
# is replaced by a new UUID.
#
# + queryValue - The `agent_session_id` query parameter, if any
# + configured - The configured session ID, if any
# + return - The session ID
isolated function resolveInvokeSessionId(string? queryValue, string? configured) returns string =>
    sanitizeFoundryId(firstNonEmpty(queryValue, configured));

isolated function firstNonEmpty(string? first, string? second) returns string? {
    if first is string && first != "" {
        return first;
    }
    return second is string && second != "" ? second : ();
}

# Returns the first value of a request header, as the reference's `request.headers.get` does.
#
# + request - The request
# + name - The header name
# + return - The first value, or `()` when the header is absent
isolated function firstHeaderValue(http:Request request, string name) returns string? {
    string|http:HeaderNotFoundError value = request.getHeader(name);
    return value is string ? value : ();
}

# Returns the first value of a request header, or `()` when the header is absent or empty (the
# reference's `request.headers.get(name, "") or None`).
#
# + request - The request
# + name - The header name
# + return - The non-empty first value, or `()`
isolated function nonEmptyHeaderValue(http:Request request, string name) returns string? {
    string? value = firstHeaderValue(request, name);
    return value == "" ? () : value;
}

# Returns the value of a query parameter as the reference reads it: Starlette's
# `request.query_params.get`, which parses the raw query with
# `urllib.parse.parse_qsl(query, keep_blank_values=True)` and keeps the last value of a repeated
# parameter.
#
# The raw query is parsed here rather than read through `http:Request.getQueryParamValues`, which
# splits a value on commas, trims it and doesn't decode the name: there `agent_session_id=a,b` would
# resolve to the valid ID `b` instead of being rejected as a whole.
#
# + request - The request
# + name - The query parameter name
# + return - The last value of the parameter (`""` when it has no value), or `()` when it is absent
isolated function lastQueryParamValue(http:Request request, string name) returns string? =>
    lastRawQueryParamValue(request.rawPath, name);

# Returns the last value of a query parameter of a raw request target, as `parse_qsl` with
# `keep_blank_values=True` reads it: the query is split on `&` only, an empty pair is skipped, a pair
# is split on its first `=` (a pair without one has the value `""`), and the name and the value are
# both decoded (`+` as a space, then `%XX` escapes as UTF-8) before the name is compared.
#
# + target - The raw request target, for example `/invocations?agent_session_id=s-1`
# + name - The query parameter name
# + return - The last value of the parameter, or `()` when it is absent
isolated function lastRawQueryParamValue(string target, string name) returns string? {
    int? queryStart = target.indexOf("?");
    if queryStart is () {
        return ();
    }
    string query = target.substring(queryStart + 1);
    // A client never sends a fragment, but if one is there it is not part of the query.
    int? fragmentStart = query.indexOf("#");
    if fragmentStart is int {
        query = query.substring(0, fragmentStart);
    }
    string? value = ();
    foreach string pair in re `&`.split(query) {
        if pair == "" {
            continue;
        }
        int? separator = pair.indexOf("=");
        string rawName = separator is int ? pair.substring(0, separator) : pair;
        if decodeQueryComponent(rawName) == name {
            value = separator is int ? decodeQueryComponent(pair.substring(separator + 1)) : "";
        }
    }
    return value;
}

# Decodes a query name or value as `parse_qsl` does: `+` becomes a space, then each `%XX` escape (two
# hexadecimal digits) is a byte, and each run of bytes is decoded as UTF-8. A `%` that doesn't start
# an escape is kept as it is.
#
# Where Python replaces each invalid UTF-8 sequence with U+FFFD, the whole run of bytes becomes a single
# U+FFFD here. Either way the result is not ASCII, so it is never a valid ID and never equals a
# parameter name, which is all the result is used for.
#
# + text - The raw name or value
# + return - The decoded text
isolated function decodeQueryComponent(string text) returns string {
    string plusDecoded = re `\+`.replaceAll(text, " ");
    if !plusDecoded.includes("%") {
        return plusDecoded;
    }
    string[] parts = [];
    byte[] pending = [];
    int i = 0;
    int length = plusDecoded.length();
    while i < length {
        if plusDecoded[i] == "%" && i + 2 < length && isHexDigit(plusDecoded[i + 1])
                && isHexDigit(plusDecoded[i + 2]) {
            int|error octet = int:fromHexString(plusDecoded.substring(i + 1, i + 3));
            if octet is byte {
                pending.push(octet);
                i += 3;
                continue;
            }
        }
        if pending.length() > 0 {
            parts.push(utf8OrReplacement(pending));
            pending = [];
        }
        parts.push(plusDecoded[i]);
        i += 1;
    }
    if pending.length() > 0 {
        parts.push(utf8OrReplacement(pending));
    }
    return string:'concat(...parts);
}

isolated function utf8OrReplacement(byte[] bytes) returns string {
    string|error text = string:fromBytes(bytes);
    return text is string ? text : "\u{FFFD}";
}

isolated function isHexDigit(string char) returns boolean =>
    (char >= "0" && char <= "9") || (char >= "a" && char <= "f") || (char >= "A" && char <= "F");

# Builds the platform context of a request.
#
# + request - The request
# + sessionId - The resolved session ID
# + invocationId - The resolved invocation ID
# + agent - Information about the hosted agent
# + return - The context, or an error when the `x-ms-original-subject` header is invalid
isolated function foundryContextFromRequest(http:Request request, string sessionId, string invocationId,
        FoundryAgentInfo agent) returns FoundryContext|FoundryOriginalSubjectError {
    string[]|http:HeaderNotFoundError subjectFields = request.getHeaders(HEADER_ORIGINAL_SUBJECT);
    FoundryOriginalSubject? originalSubject =
        check parseOriginalSubject(subjectFields is string[] ? subjectFields : []);
    return {
        sessionId,
        invocationId,
        userId: nonEmptyHeaderValue(request, HEADER_USER_ID),
        callId: nonEmptyHeaderValue(request, HEADER_FOUNDRY_CALL_ID),
        originalSubject,
        clientHeaders: clientHeadersOf(request),
        trace: {
            traceparent: nonEmptyHeaderValue(request, HEADER_TRACEPARENT),
            tracestate: nonEmptyHeaderValue(request, HEADER_TRACESTATE),
            baggage: nonEmptyHeaderValue(request, HEADER_BAGGAGE),
            requestId: nonEmptyHeaderValue(request, HEADER_REQUEST_ID),
            clientRequestId: nonEmptyHeaderValue(request, HEADER_CLIENT_REQUEST_ID)
        },
        agent,
        headers: createFoundryHeaders(request)
    };
}

# Collects the `x-client-*` pass-through headers (`core/_platform_headers.py:80-85`), keyed by
# lower-case name. A header sent more than once keeps all its values, joined with `", "` in the order
# received, which is how HTTP combines repeated header fields (RFC 9110, section 5.3).
#
# + request - The request
# + return - The client headers
isolated function clientHeadersOf(http:Request request) returns map<string> {
    map<string> clientHeaders = {};
    foreach string name in request.getHeaderNames() {
        string key = name.toLowerAscii();
        if !key.startsWith(CLIENT_HEADER_PREFIX) || clientHeaders.hasKey(key) {
            continue;
        }
        string[]|http:HeaderNotFoundError values = request.getHeaders(key);
        if values is string[] {
            clientHeaders[key] = string:'join(", ", ...values);
        }
    }
    return clientHeaders;
}

# Parses the `x-ms-original-subject` header, a port of `FoundryOriginalSubject.from_headers`
# (`core/_request_context.py:76-111`).
#
# The header is a draft RFC 9651 dictionary with only the string members `oid`, `tid` and `idtype`,
# each at most once and in any order, separated by commas with optional spaces and tabs. A member
# value is a quoted string of printable ASCII characters in which a double quote or a backslash is
# escaped with a backslash.
# Parameters, other members, other value types, an empty dictionary and a repeated header field are
# all invalid.
#
# + fields - Every `x-ms-original-subject` header field of the request, in order
# + return - The parsed subject, `()` when the header is absent, or an error when it is invalid. The
# error never contains the header value
isolated function parseOriginalSubject(string[] fields) returns FoundryOriginalSubject|FoundryOriginalSubjectError? {
    if fields.length() == 0 {
        return ();
    }
    if fields.length() != 1 {
        return error FoundryOriginalSubjectError("Original-subject attribution requires a single header field.");
    }
    string remaining = trimSpacesAndTabs(fields[0], true, true);
    map<string> values = {};
    while remaining != "" {
        [string, string, string]? member = matchOriginalSubjectMember(remaining);
        if member is () || values.hasKey(member[0]) {
            return error FoundryOriginalSubjectError(
                "Original-subject attribution requires unique oid/tid/idtype string members.");
        }
        values[member[0]] = member[1];
        remaining = trimSpacesAndTabs(member[2], true, false);
        if remaining == "" {
            break;
        }
        if !remaining.startsWith(",") || trimSpacesAndTabs(remaining.substring(1), true, true) == "" {
            return error FoundryOriginalSubjectError(
                "Original-subject attribution requires comma-separated dictionary members.");
        }
        remaining = trimSpacesAndTabs(remaining.substring(1), true, false);
    }
    if values.length() == 0 {
        return error FoundryOriginalSubjectError("Original-subject attribution requires a nonempty dictionary.");
    }
    return {oid: values["oid"], tid: values["tid"], idtype: values["idtype"]};
}

# Matches one dictionary member at the start of `text`, as the reference's regular expression
# `(oid|tid|idtype)="((?:[\x20-\x21\x23-\x5b\x5d-\x7e]|\\["\\])*)"` does with `re.match`.
#
# + text - The remaining header text
# + return - The member name, its unescaped value and the text after the member, or `()` when the
# text doesn't start with a valid member
isolated function matchOriginalSubjectMember(string text) returns [string, string, string]? {
    foreach string name in ORIGINAL_SUBJECT_MEMBERS {
        string prefix = name + "=\"";
        if !text.startsWith(prefix) {
            continue;
        }
        int[] codePoints = text.substring(prefix.length()).toCodePointInts();
        int[] value = [];
        int i = 0;
        while i < codePoints.length() {
            int c = codePoints[i];
            if c == 0x22 {
                // The closing quote.
                string|error unescaped = string:fromCodePointInts(value);
                if unescaped is error {
                    return ();
                }
                string|error rest = string:fromCodePointInts(codePoints.slice(i + 1));
                if rest is error {
                    return ();
                }
                return [name, unescaped, rest];
            }
            if c == 0x5c {
                // Only an escaped double quote or backslash is valid.
                if i + 1 < codePoints.length() && (codePoints[i + 1] == 0x22 || codePoints[i + 1] == 0x5c) {
                    value.push(codePoints[i + 1]);
                    i += 2;
                    continue;
                }
                return ();
            }
            if c < 0x20 || c > 0x7e {
                return ();
            }
            value.push(c);
            i += 1;
        }
        // No closing quote.
        return ();
    }
    return ();
}

# Removes spaces and tabs (only those, as Python's `str.strip(" \t")`) from the ends of a string.
#
# + text - The string
# + leading - Whether to remove them from the start
# + trailing - Whether to remove them from the end
# + return - The trimmed string
isolated function trimSpacesAndTabs(string text, boolean leading, boolean trailing) returns string {
    int startIndex = 0;
    int endIndex = text.length();
    if leading {
        while startIndex < endIndex && isSpaceOrTab(text[startIndex]) {
            startIndex += 1;
        }
    }
    if trailing {
        while endIndex > startIndex && isSpaceOrTab(text[endIndex - 1]) {
            endIndex -= 1;
        }
    }
    return text.substring(startIndex, endIndex);
}

isolated function isSpaceOrTab(string char) returns boolean => char == " " || char == "\t";

# Creates the `http:Headers` object of a request, as the http module does for an `http:Headers`
# resource parameter.
#
# + request - The request
# + return - The headers of the request
isolated function createFoundryHeaders(http:Request request) returns http:Headers = @java:Method {
    'class: "io.ballerina.lib.ai.azure.NativeFoundryResourceInvoker"
} external;
