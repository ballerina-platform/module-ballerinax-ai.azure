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
import ballerina/os;

# A service that runs as a Microsoft Foundry hosted agent using the Invocations protocol.
#
# Attach it to an `azure:FoundryListener`. The service declares the required
# `resource function post invocations` and, optionally,
# `resource function get invocations/[string invocationId]` and
# `resource function post invocations/[string invocationId]/cancel`. The listener handles the
# platform contract (readiness, session and invocation IDs, platform headers, error
# classification and streaming), so the resources contain only agent logic.
public type FoundryInvocationService distinct service object {
    *http:Service;
};

# The configuration of an `azure:FoundryListener`.
#
# The platform values default to the matching environment variables that Foundry sets on the
# container, so a hosted agent needs no configuration. Tests and local runs can pass the values
# explicitly instead of setting environment variables.
#
# + gracefulStopTimeout - Seconds to let in-flight requests finish when the listener stops
# gracefully. Defaults to the `AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` environment
# variable, or 30
# + sseKeepAliveInterval - Seconds of inactivity on a server-sent event stream before a
# keep-alive comment is sent. `0` disables keep-alive comments. Defaults to the
# `SSE_KEEPALIVE_INTERVAL` environment variable, or 15
# + agent - Information about the hosted agent. Defaults to the `FOUNDRY_*` environment variables
# + openApiSpec - An OpenAPI document served at `GET /invocations/docs/openapi.json`. When it is
# not set, that path returns `404`
public type FoundryListenerConfiguration record {|
    *http:ListenerConfiguration;
    decimal gracefulStopTimeout = foundryGracefulStopTimeoutFromEnv();
    int sseKeepAliveInterval = foundrySseKeepAliveIntervalFromEnv();
    FoundryAgentInfo agent = foundryAgentInfoFromEnv();
    map<json>? openApiSpec = ();
|};

# Information about the hosted agent, read from the environment variables Foundry sets on the
# container. Every field is `()` when the variable is not set, as in a local run.
#
# + projectEndpoint - The Foundry project endpoint (`FOUNDRY_PROJECT_ENDPOINT`)
# + projectArmId - The Azure Resource Manager ID of the Foundry project (`FOUNDRY_PROJECT_ARM_ID`)
# + name - The agent name (`FOUNDRY_AGENT_NAME`)
# + version - The agent version (`FOUNDRY_AGENT_VERSION`)
# + id - The stable agent identifier (`FOUNDRY_AGENT_ID`)
# + sessionId - The default session ID for this container (`FOUNDRY_AGENT_SESSION_ID`)
public type FoundryAgentInfo record {|
    string? projectEndpoint = ();
    string? projectArmId = ();
    string? name = ();
    string? version = ();
    string? id = ();
    string? sessionId = ();
|};

# The original-subject assertions from the `x-ms-original-subject` platform header.
#
# These values are not proof of identity. They identify the subject on whose behalf the
# invocation runs, separately from the agent's own identity.
#
# + oid - The object ID of the original subject
# + tid - The tenant ID of the original subject
# + idtype - The classification of the original subject, as sent by the platform
public type FoundryOriginalSubject record {|
    string? oid = ();
    string? tid = ();
    string? idtype = ();
|};

# The tracing and correlation headers of a request. Every field is `()` when the header is absent.
#
# + traceparent - The W3C `traceparent` header
# + tracestate - The W3C `tracestate` header
# + baggage - The W3C `baggage` header
# + requestId - The `x-request-id` header
# + clientRequestId - The `x-ms-client-request-id` header
public type FoundryTraceContext record {|
    string? traceparent = ();
    string? tracestate = ();
    string? baggage = ();
    string? requestId = ();
    string? clientRequestId = ();
|};

# The platform context of a Foundry invocation request.
#
# Declare a parameter of this type on a `FoundryInvocationService` resource to receive it.
# Every platform value is optional, so the service also works locally where Foundry sends none.
#
# + sessionId - The resolved session ID. On `POST /invocations` it comes from the
# `agent_session_id` query parameter, then `FOUNDRY_AGENT_SESSION_ID`, then a generated UUID.
# On get and cancel it is `""` when no session is known
# + invocationId - The resolved invocation ID
# + userId - The per-user partition key from the `x-agent-user-id` header
# + callId - The opaque call ID from the `x-agent-foundry-call-id` header. Forward it unchanged on
# outbound calls to Foundry services; never parse it
# + originalSubject - The parsed `x-ms-original-subject` header
# + clientHeaders - Every `x-client-*` request header, keyed by its lower-case name
# + trace - The tracing and correlation headers
# + agent - Information about the hosted agent
# + headers - The raw request headers
public type FoundryContext record {|
    string sessionId;
    string invocationId;
    string? userId = ();
    string? callId = ();
    FoundryOriginalSubject? originalSubject = ();
    map<string> clientHeaders = {};
    FoundryTraceContext trace = {};
    FoundryAgentInfo agent = {};
    http:Headers headers;
|};

const ENV_GRACEFUL_SHUTDOWN_TIMEOUT = "AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS";
const ENV_SSE_KEEPALIVE_INTERVAL = "SSE_KEEPALIVE_INTERVAL";
const ENV_PORT = "PORT";
const decimal DEFAULT_GRACEFUL_STOP_TIMEOUT = 30;
const int DEFAULT_SSE_KEEPALIVE_INTERVAL = 15;
const int DEFAULT_PORT = 8088;

isolated function foundryGracefulStopTimeoutFromEnv() returns decimal {
    string value = os:getEnv(ENV_GRACEFUL_SHUTDOWN_TIMEOUT).trim();
    int|error timeout = int:fromString(value);
    return timeout is int ? <decimal>(timeout < 0 ? 0 : timeout) : DEFAULT_GRACEFUL_STOP_TIMEOUT;
}

isolated function foundrySseKeepAliveIntervalFromEnv() returns int {
    string value = os:getEnv(ENV_SSE_KEEPALIVE_INTERVAL).trim();
    int|error interval = int:fromString(value);
    return interval is int ? (interval < 0 ? 0 : interval) : DEFAULT_SSE_KEEPALIVE_INTERVAL;
}

isolated function foundryAgentInfoFromEnv() returns FoundryAgentInfo => {
    projectEndpoint: envOrNil("FOUNDRY_PROJECT_ENDPOINT"),
    projectArmId: envOrNil("FOUNDRY_PROJECT_ARM_ID"),
    name: envOrNil("FOUNDRY_AGENT_NAME"),
    version: envOrNil("FOUNDRY_AGENT_VERSION"),
    id: envOrNil("FOUNDRY_AGENT_ID"),
    sessionId: envOrNil("FOUNDRY_AGENT_SESSION_ID")
};

isolated function envOrNil(string name) returns string? {
    string value = os:getEnv(name);
    return value == "" ? () : value;
}
