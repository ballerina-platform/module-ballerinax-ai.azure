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

# Builds the platform headers a hosted agent forwards on its outbound calls to Foundry platform
# services.
#
# Add these headers to every outbound call the agent makes to a Foundry platform service, such as
# storage, the toolbox (MCP) proxy or A2A, which are reached through the project endpoint
# (`FOUNDRY_PROJECT_ENDPOINT`, also in `ctx.agent.projectEndpoint`). The service uses them to resolve
# the caller's context on its side. The listener doesn't add them to outbound calls for you.
#
# The result holds `x-agent-foundry-call-id` with the call ID of the invocation, unchanged, when
# the request carried one (`ctx.callId` is a string); otherwise it is empty, as in a local run. The
# call ID is opaque: forward it as it is and never parse it or depend on its format.
#
# The user ID (`x-agent-user-id`, `ctx.userId`) is intentionally not included. Foundry platform
# services don't accept or trust it; it is only a partition key for per-user state inside the
# container. The headers are in addition to the agent's own credentials: keep sending the
# `Authorization` header of the agent's managed identity as before.
#
# The returned map is a new, mutable map each time, and it can be passed directly as the `headers`
# argument of an `http:Client` method, or assigned to a header map and extended with more headers:
#
# ```ballerina
# resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx)
#         returns json|error {
#     map<string|string[]> headers = azure:foundryPlatformHeaders(ctx);
#     headers["Authorization"] = string `Bearer ${check getManagedIdentityToken()}`;
#     return check foundryClient->post("/storage/items", payload, headers);
# }
# ```
#
# + ctx - The platform context of the invocation that makes the outbound call
# + return - The headers to add to the outbound request, keyed by header name
public isolated function foundryPlatformHeaders(FoundryContext ctx) returns map<string|string[]> {
    // `platform_headers()` in the reference (`core/_request_context.py:221-239`): only the call ID, and
    // only when it is present. The map is built as `map<string|string[]>` so a caller can add a
    // multi-valued header to it.
    map<string|string[]> headers = {};
    string? callId = ctx.callId;
    if callId is string {
        headers[HEADER_FOUNDRY_CALL_ID] = callId;
    }
    return headers;
}
