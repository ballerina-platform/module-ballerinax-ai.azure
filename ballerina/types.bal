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

# Defines which API endpoint to use for model interactions.
public enum ApiType {
    CHAT_COMPLETIONS = "chat_completions",
    RESPONSES = "responses"
}

type AzureChatUserMessage record {|
    *ai:ChatUserMessage;
    string content;
|};

type AzureChatSystemMessage record {|
    *ai:ChatSystemMessage;
    string content;
|};

type CodeInterpreterTool record {|
    *ai:InbuiltModelTool;
    "code_interpreter" name;
    record {|
        anydata container;
    |} configurations;
|};

type WebsearchTool record {|
    *ai:InbuiltModelTool;
    "web_search"|"web_search_2025_08_26" name;
    record {|
        anydata filters?;
        anydata user_location?;
        "low"|"medium"|"high" search_context_size = "medium";
    |} configurations;
|};

type LocalShellTool record {|
    *ai:InbuiltModelTool;
    "local_shell" name;
    never configurations;
|};

type FileSearchTool record {|
    *ai:InbuiltModelTool;
    "file_search" name;
    record {|
        string[] vector_store_ids;
        int max_num_results?;
        anydata ranking_options?;
        anydata filters?;
    |} configurations;
|};

type ComputerUsePreviewTool record {|
    *ai:InbuiltModelTool;
    "computer_use_preview" name;
    record {|
        "windows"|"mac"|"linux"|"ubuntu"|"browser" environment;
        int display_width;
        int display_height;
    |} configurations;
|};

type McpTool record {|
    *ai:InbuiltModelTool;
    "mcp" name;
    record {|
        string server_label;
        string server_url?;
        string server_description?;
        string authorization?;
        anydata headers?;
        anydata allowed_tools?;
        anydata require_approval?;
    |} configurations;
|};

type ImageGenTool record {|
    *ai:InbuiltModelTool;
    "image_generation" name;
    record {|
        string model?;
        "low"|"medium"|"high"|"auto" quality?;
        "1024x1024"|"1024x1536"|"1536x1024"|"auto" size?;
        "png"|"webp"|"jpeg" output_format?;
        int output_compression?;
        "auto"|"low" moderation?;
        "transparent"|"opaque"|"auto" background?;
        anydata input_image_mask?;
        int partial_images?;
    |} configurations;
|};

type FunctionShellTool record {|
    *ai:InbuiltModelTool;
    "shell" name;
    record {|
        anydata environment?;
    |} configurations;
|};

type AzureInbuiltModelTool CodeInterpreterTool|WebsearchTool|LocalShellTool|FileSearchTool|ComputerUsePreviewTool|McpTool|ImageGenTool|FunctionShellTool;
