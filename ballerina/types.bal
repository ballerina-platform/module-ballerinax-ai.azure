// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
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

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# The Azure OpenAI API surface used by the `OpenAiModelProvider`.
#
# The concrete wire route is derived from both this value and the shape of the `serviceUrl`:
#
# | `apiType` | `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
# | --- | --- | --- |
# | `CHAT_COMPLETIONS` | `POST {serviceUrl}/chat/completions` via the `azure.openai.chat` connector | `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version={apiVersion}` |
# | `RESPONSES` | `POST {serviceUrl}/responses` via the `azure.openai.responses` connector | `POST {legacyBase}/responses?api-version={apiVersion}` |
#
# On the legacy surface `legacyBase` is the `serviceUrl` completed with `/openai` when it is a bare origin
# (e.g. `https://<resource>.openai.azure.com`) and used verbatim when it already carries a path (e.g. an API
# Management base path).
@display {label: "OpenAI API Type"}
public enum ApiType {
    # Use the OpenAI Chat Completions API (`/chat/completions`)
    CHAT_COMPLETIONS = "chat_completions",
    # Use the OpenAI Responses API (`/responses`)
    RESPONSES = "responses"
}

# Reasoning effort level for reasoning models (`gpt-5`/`o`-series).
#
# The supported set follows the Azure OpenAI specification. Not every model supports every value (for example,
# `MINIMAL` is only supported by the original `gpt-5` reasoning models, `XHIGH` only by `gpt-5.1-codex-max` and
# later, and `NONE` only by `gpt-5.1`+). Passing an unsupported value for the target deployment results in an
# error from the service.
public enum ReasoningEffort {
    # No reasoning; supported by `gpt-5.1` and later.
    NONE = "none",
    # The smallest amount of reasoning; supported by the original `gpt-5` reasoning models.
    MINIMAL = "minimal",
    # Favours speed and fewer reasoning tokens.
    LOW = "low",
    # Balances reasoning depth and latency.
    MEDIUM = "medium",
    # Favours more complete reasoning.
    HIGH = "high",
    # The largest amount of reasoning; supported by `gpt-5.1-codex-max` and later.
    XHIGH = "xhigh"
}

// ===== Anthropic (Claude) types =====

# The default `anthropic-version` header value: the version documented for Claude models in Microsoft Foundry.
public const DEFAULT_ANTHROPIC_VERSION = "2023-06-01";

// `Effort`, `ThinkingType` and `ThinkingDisplay` are string unions rather than enums (unlike `ApiType` and
// `ReasoningEffort` above) because enum members are module-level constants: an `Effort` enum could not declare
// `LOW`/`MEDIUM`/`HIGH`/`XHIGH`, which `ReasoningEffort` already owns. A closed string union keeps the values
// type-checked without prefixed member names.

# The effort level for Claude models, forwarded as `output_config.effort` on the Anthropic Messages API.
#
# Effort controls how much thinking and overall token spend the model uses. The service default is `"high"`.
# Support is per model: Claude Sonnet 4.5 and Claude Haiku 4.5 reject the parameter, Claude Opus 4.5 accepts
# only `"low"`, `"medium"` and `"high"`, and `"xhigh"` arrived with Claude Opus 4.7. Passing an unsupported
# value for the target deployment results in an error from the service.
public type Effort "low"|"medium"|"high"|"xhigh"|"max";

# The thinking mode requested from a Claude model.
#
# - `"adaptive"` - the model decides whether and how much to think per request. Available on Claude Opus 4.6 /
#   Sonnet 4.6 and later, and the only *on* mode from Claude Opus 4.7 onwards.
# - `"enabled"` - manual extended thinking against a fixed `budgetTokens` budget. The only thinking mode on
#   Claude Sonnet 4.5, Claude Opus 4.5 and Claude Haiku 4.5, deprecated on the 4.6 models, and **rejected** by
#   Claude Opus 4.7 and later.
# - `"disabled"` - no thinking. Accepted by most models, but Claude Opus 5 accepts it only at an effort of
#   `"high"` or lower.
#
# The Messages API rejects a `temperature` while thinking is on, so the two cannot be configured together.
public type ThinkingType "adaptive"|"enabled"|"disabled";

# Controls whether the model's reasoning is returned in the response.
#
# This module does not surface thinking content on `ai:ChatAssistantMessage`, so the value only affects the
# tokens spent on rendering a summary.
public type ThinkingDisplay "summarized"|"omitted";

# Thinking configuration for a Claude model, forwarded as the `thinking` field of the Anthropic Messages API
# request.
#
# Leave the provider's `thinking` argument as `()` to omit the field entirely and let the deployed model apply
# its own default: no thinking on Claude Opus 4.8 and earlier, adaptive thinking on Claude Opus 5 and Claude
# Sonnet 5, and always-on thinking on Claude Fable 5.
@display {label: "Thinking Configuration"}
public type Thinking record {|
    # The thinking mode. Defaults to `"adaptive"`.
    @display {label: "Thinking Type"}
    ThinkingType 'type = "adaptive";
    # The thinking token budget, sent as `budget_tokens`. **Required** when `type` is `"enabled"` and invalid
    # otherwise. Must be at least 1024 and less than the provider's `maxTokens`.
    @display {label: "Budget Tokens"}
    int budgetTokens?;
    # Whether a summary of the model's reasoning is returned.
    @display {label: "Thinking Display"}
    ThinkingDisplay display?;
|};
