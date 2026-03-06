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

import ballerina/ai;
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

type AzureChatUserMessage record {|
    *ai:ChatUserMessage;
    string content;
|};

type AzureChatSystemMessage record {|
    *ai:ChatSystemMessage;
    string content;
|};

# Code interpreter tool for Azure OpenAI models.
# Allows the model to execute code in a sandboxed environment during a conversation.
# Ref: https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/code-interpreter
public type CodeInterpreterTool record {|
    *ai:BuiltInTool;
    # Tool identifier. Always `"code_interpreter"`.
    "code_interpreter" name;
    # Code interpreter configurations
    record {|
        # The container to run the code in. Either a string container ID or an auto-provisioned container configuration.
        anydata container;
    |} configurations;
|};

# Web search tool for Azure OpenAI models.
# Enables the model to search the web for real-time information during a conversation.
public type WebsearchTool record {|
    *ai:BuiltInTool;
    # Tool identifier. Use `"web_search"` (default) or `"web_search_2025_08_26"` for an older version.
    "web_search"|"web_search_2025_08_26" name;
    # Web search configurations
    record {|
        # Domain filters for narrowing search results
        anydata filters?;
        # Approximate user location for localizing search results
        anydata user_location?;
        # High level guidance for the amount of context window space to use for the search.
        # One of `low`, `medium`, or `high`. Defaults to `medium`.
        "low"|"medium"|"high" search_context_size = "medium";
    |} configurations;
|};

# Union type representing all built-in tools supported by the Azure OpenAI provider.
type AzureBuiltInTool CodeInterpreterTool|WebsearchTool;
