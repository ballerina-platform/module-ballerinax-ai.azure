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

import ballerina/jballerina.java;

// Span attributes of a Foundry protocol request, under the reference's names. When Ballerina tracing is
// disabled nothing is built or set.
//
// The invocations package's span attribute names (`inv/_constants.py:21-25`).
const ATTR_INVOCATION_ID = "azure.ai.agentserver.invocations.invocation_id";
const ATTR_INVOCATIONS_SESSION_ID = "azure.ai.agentserver.invocations.session_id";
const ATTR_ERROR_CODE = "azure.ai.agentserver.invocations.error.code";
// The names the core package's span processor stamps on every span (`core/_tracing.py:53-83`, `797-874`).
const ATTR_MICROSOFT_FOUNDRY = "microsoft.foundry";
const MICROSOFT_FOUNDRY_VALUE = "True";
const ATTR_FOUNDRY_PROJECT_ID = "microsoft.foundry.project.id";
const ATTR_SESSION_ID = "microsoft.session.id";
const ATTR_AGENT_NAME = "gen_ai.agent.name";
const ATTR_AGENT_VERSION = "gen_ai.agent.version";
const ATTR_AGENT_ID = "gen_ai.agent.id";
const ATTR_AGENT_BLUEPRINT_ID = "microsoft.a365.agent.blueprint.id";
const ATTR_AGENT_TENANT_ID = "microsoft.tenant.id";

# The agent identity values the reference stamps on spans that `FoundryAgentInfo` doesn't carry, read from
# the environment (`core/_config.py:375-421`).
#
# + instanceClientId - `FOUNDRY_AGENT_INSTANCE_CLIENT_ID`, which the reference prefers for `gen_ai.agent.id`
# + blueprintClientId - `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID`
# + tenantId - `FOUNDRY_AGENT_TENANT_ID`
type FoundryTracingIdentity record {|
    string? instanceClientId = ();
    string? blueprintClientId = ();
    string? tenantId = ();
|};

final readonly & FoundryTracingIdentity FOUNDRY_TRACING_IDENTITY = {
    instanceClientId: envOrNil("FOUNDRY_AGENT_INSTANCE_CLIENT_ID"),
    blueprintClientId: envOrNil("FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"),
    tenantId: envOrNil("FOUNDRY_AGENT_TENANT_ID")
};

# Adds the Foundry attributes to the request span and to the span of the user's resource, when tracing
# is enabled. Spans started beneath the user's resource don't get them (see `FoundryTracing.java`).
#
# + agent - The agent information of the listener
# + invocationId - The invocation ID of the request; ignored unless it is a valid ID
# + sessionId - The session ID of the request; ignored when it is `()` or empty
isolated function tagFoundryRequestSpan(FoundryAgentInfo agent, string? invocationId, string? sessionId) {
    if isFoundryTracingEnabled() {
        setFoundrySpanTags(foundrySpanTags(agent, FOUNDRY_TRACING_IDENTITY, invocationId, sessionId));
    }
}

# Adds the error code of an error response to the current span, when tracing is enabled. Only the code
# is recorded, never the message, which may describe the request.
#
# + code - The error code of the error envelope, for example `internal_error`
isolated function tagFoundryErrorCode(string code) {
    if isFoundryTracingEnabled() {
        addFoundrySpanTag(ATTR_ERROR_CODE, code);
    }
}

# Builds the Foundry span attributes of a request, as the reference's invocations package and span
# processor name them. Agent identity attributes are left out when the value is not configured, as in
# the reference. `gen_ai.agent.id` is `FOUNDRY_AGENT_INSTANCE_CLIENT_ID`, else `<name>:<version>`, else
# `<name>` (`resolve_agent_id`, `core/_config.py:375-394`).
#
# + agent - The agent information of the listener
# + identity - The identity values read from the environment
# + invocationId - The invocation ID; left out unless it is a valid ID, so a get or cancel path value
# that is not an ID (request content) never becomes an attribute
# + sessionId - The session ID; left out when it is `()` or empty
# + return - The attributes
isolated function foundrySpanTags(FoundryAgentInfo agent, FoundryTracingIdentity identity, string? invocationId,
        string? sessionId) returns map<string> {
    map<string> tags = {[ATTR_MICROSOFT_FOUNDRY]: MICROSOFT_FOUNDRY_VALUE};
    addSpanTagIfSet(tags, ATTR_FOUNDRY_PROJECT_ID, agent.projectArmId);
    string? name = nonEmptyTagValue(agent.name);
    string? version = nonEmptyTagValue(agent.version);
    addSpanTagIfSet(tags, ATTR_AGENT_NAME, name);
    addSpanTagIfSet(tags, ATTR_AGENT_VERSION, version);
    string? agentId = nonEmptyTagValue(identity.instanceClientId);
    if agentId is () && name is string {
        agentId = version is string ? string `${name}:${version}` : name;
    }
    addSpanTagIfSet(tags, ATTR_AGENT_ID, agentId);
    addSpanTagIfSet(tags, ATTR_AGENT_BLUEPRINT_ID, identity.blueprintClientId);
    addSpanTagIfSet(tags, ATTR_AGENT_TENANT_ID, identity.tenantId);
    if invocationId is string && invocationId.length() <= MAX_ID_LENGTH && VALID_ID_PATTERN.isFullMatch(invocationId) {
        tags[ATTR_INVOCATION_ID] = invocationId;
    }
    string? session = nonEmptyTagValue(sessionId);
    if session is string {
        tags[ATTR_INVOCATIONS_SESSION_ID] = session;
        tags[ATTR_SESSION_ID] = session;
    }
    return tags;
}

isolated function addSpanTagIfSet(map<string> tags, string key, string? value) {
    string? nonEmptyValue = nonEmptyTagValue(value);
    if nonEmptyValue is string {
        tags[key] = nonEmptyValue;
    }
}

isolated function nonEmptyTagValue(string? value) returns string? => value == "" ? () : value;

isolated function isFoundryTracingEnabled() returns boolean = @java:Method {
    'class: "io.ballerina.lib.ai.azure.FoundryTracing"
} external;

isolated function setFoundrySpanTags(map<string> tags) = @java:Method {
    'class: "io.ballerina.lib.ai.azure.FoundryTracing"
} external;

isolated function addFoundrySpanTag(string key, string value) = @java:Method {
    'class: "io.ballerina.lib.ai.azure.FoundryTracing"
} external;
