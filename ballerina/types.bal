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

    # The choice of setting the forwarded or x-forwarded header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling the compression (accept-encoding) header
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

    # Enables the inbound payload validation provided by the constraint package
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# Connection configuration of OpenAiModelProvider.
@display {label: "Connection Configuration"}
public type OpenAiModelConnectionConfig record {|
    *ConnectionConfig;

    # The Microsoft Entra ID token scope, derived from the service URL when not set
    @display {label: "Token Scope"}
    string tokenScope?;
|};

# Defines which Azure OpenAI API to use for model interactions.
@display {label: "OpenAI API Type"}
public enum ApiType {
    # Use the Azure OpenAI Chat Completions API
    CHAT_COMPLETIONS = "chat_completions",
    # Use the Azure OpenAI Responses API
    RESPONSES = "responses"
}

# Reasoning effort level for reasoning models.
public enum ReasoningEffort {
    # No reasoning.
    NONE = "none",
    # The smallest amount of reasoning.
    MINIMAL = "minimal",
    # Favours speed and fewer reasoning tokens.
    LOW = "low",
    # Balances reasoning depth and latency.
    MEDIUM = "medium",
    # Favours more complete reasoning.
    HIGH = "high",
    # The largest amount of reasoning.
    XHIGH = "xhigh"
}
