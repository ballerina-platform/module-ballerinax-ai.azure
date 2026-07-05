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
# | `CHAT_COMPLETION` | `POST {serviceUrl}/chat/completions` via the `azure.openai.chat` connector | `POST {serviceUrl}/openai/deployments/{deploymentId}/chat/completions?api-version={apiVersion}` |
# | `RESPONSES` | `POST {serviceUrl}/responses` via the `azure.openai.responses` connector | `POST {serviceUrl}/openai/responses?api-version={apiVersion}` |
public enum ApiType {
    # Use the Azure OpenAI **Chat Completions API**. This is the default and preserves the behaviour of
    # earlier releases of this module.
    CHAT_COMPLETION,
    # Use the Azure OpenAI **Responses API**.
    RESPONSES
}

# Reasoning effort level for reasoning models (`gpt-5`/`o`-series).
#
# The supported set follows the Azure OpenAI specification: `none`, `minimal`, `low`, `medium`, `high`, and
# `xhigh`. Not every model supports every value (for example, `minimal` is only supported by the original
# `gpt-5` reasoning models, `xhigh` only by `gpt-5.1-codex-max` and later, and `none` only by `gpt-5.1`+).
# Passing an unsupported value for the target deployment results in an error from the service.
public type ReasoningEffort "none"|"minimal"|"low"|"medium"|"high"|"xhigh";
