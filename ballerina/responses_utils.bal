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
import ballerina/ai.observe;
import ballerina/http;
import ballerina/log;
import ballerinax/azure.openai.responses;

// ===== Responses API request item shapes =====
// `azure.openai.responses` models input items, tools and tool choices as open records carrying only a
// discriminator, so the concrete shapes used by this module are defined here. Each is a structural subtype of
// the corresponding connector type (`OpenAIInputItem`, `OpenAITool`, `OpenAIToolChoiceParam`).

type ResponsesInputText record {|
    "input_text" 'type = "input_text";
    string text;
|};

type ResponsesInputImage record {|
    "input_image" 'type = "input_image";
    string image_url;
|};

type ResponsesInputContent ResponsesInputText|ResponsesInputImage;

type ResponsesInputMessage record {|
    "message" 'type = "message";
    "user"|"assistant"|"system"|"developer" role;
    string|ResponsesInputContent[] content;
|};

type ResponsesFunctionCall record {|
    "function_call" 'type = "function_call";
    string id?;
    string call_id;
    string name;
    string arguments;
    string status?;
|};

type ResponsesFunctionCallOutput record {|
    "function_call_output" 'type = "function_call_output";
    string call_id;
    string output;
|};

type ResponsesFunctionTool record {|
    "function" 'type = "function";
    string name;
    string? description?;
    map<json> parameters?;
    boolean strict?;
|};

type ResponsesToolChoiceFunction record {|
    "function" 'type = "function";
    string name;
|};

// ===== Responses API output parsing shapes =====

type ResponsesOutputContentItem record {
    string 'type;
    string text?;
};

type ResponsesOutputMessageItem record {
    ResponsesOutputContentItem[] content;
};

type ResponsesFunctionCallItem record {
    string name;
    string arguments;
    string call_id?;
};

# Converts an `ai:ChatMessage` array to Responses API input items and instructions.
#
# System messages are extracted to the `instructions` parameter. User, assistant, and function messages are
# converted to typed input items. User message content that carries documents (images) is converted to Responses
# input content parts.
#
# + messages - List of chat messages or a single user message
# + return - A tuple of [input items, optional instructions] or an error
isolated function convertToResponsesInput(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns [responses:OpenAIInputItem[], string?]|ai:Error {
    if messages is ai:ChatUserMessage {
        ResponsesInputMessage item = {
            role: "user",
            content: check buildResponsesUserContent(messages.content)
        };
        return [[item], ()];
    }

    responses:OpenAIInputItem[] inputItems = [];
    string[] instructionParts = [];
    // Per-tool-name occurrence counters used only when a message carries no id of its own. Counting
    // calls and outputs separately keeps the nth call to a given tool paired with the nth output for
    // that tool, while still giving each call its own `call_id`.
    map<int> callIdCounts = {};
    map<int> outputIdCounts = {};

    foreach ai:ChatMessage message in messages {
        if message is ai:ChatSystemMessage {
            instructionParts.push(check getChatMessageStringContent(message.content));
        } else if message is ai:ChatUserMessage {
            ResponsesInputMessage item = {
                role: "user",
                content: check buildResponsesUserContent(message.content)
            };
            inputItems.push(item);
        } else if message is ai:ChatAssistantMessage {
            ai:FunctionCall[]? toolCalls = message.toolCalls;
            if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
                string? content = message?.content;
                if content is string {
                    ResponsesInputMessage item = {role: "assistant", content};
                    inputItems.push(item);
                }
                foreach ai:FunctionCall tc in toolCalls {
                    string callId = tc.id ?: nextToolCallId(tc.name, callIdCounts);
                    // Only set `call_id` (the `call_...` correlation id). The optional item `id`
                    // must be a server-assigned `fc_...` id; sending the `call_...` value there
                    // makes Azure reject the turn ("Expected an ID that begins with 'fc'").
                    // Omitting it matches the working ai.openai Responses path.
                    ResponsesFunctionCall functionCall = {
                        call_id: callId,
                        name: tc.name,
                        arguments: (tc?.arguments ?: {}).toJsonString(),
                        status: "completed"
                    };
                    inputItems.push(functionCall);
                }
            } else {
                ResponsesInputMessage item = {role: "assistant", content: message?.content ?: ""};
                inputItems.push(item);
            }
        } else if message is ai:ChatFunctionMessage {
            ResponsesFunctionCallOutput output = {
                call_id: message.id ?: nextToolCallId(message.name, outputIdCounts),
                output: message?.content ?: ""
            };
            inputItems.push(output);
        }
    }

    string? instructions = instructionParts.length() > 0
        ? string:'join("\n\n", ...instructionParts)
        : ();
    return [inputItems, instructions];
}

# Builds the Responses API `content` for a user message from either a plain string or a prompt with documents.
#
# + content - The user message content (string or prompt)
# + return - A string (text-only) or an array of Responses input content parts, or an error
isolated function buildResponsesUserContent(ai:Prompt|string content)
        returns string|ResponsesInputContent[]|ai:Error {
    if content is string {
        return content;
    }
    DocumentContentPart[] parts = check generateChatCreationContent(content);
    return convertContentPartsForResponses(parts);
}

# Converts `DocumentContentPart`s (Chat Completions shape) into Responses API input content parts.
#
# Audio input is not supported by the Azure OpenAI Responses API, so an audio part produces an error.
#
# + parts - The content parts in Chat Completions format
# + return - The content parts in Responses API format, or an error for unsupported content
isolated function convertContentPartsForResponses(DocumentContentPart[] parts)
        returns ResponsesInputContent[]|ai:Error {
    ResponsesInputContent[] result = [];
    foreach DocumentContentPart part in parts {
        if part is TextContentPart {
            result.push({'type: "input_text", text: part.text});
        } else if part is ImageContentPart {
            result.push({'type: "input_image", image_url: part.image_url.url});
        } else {
            return error ai:Error("Audio input is not supported by the Azure OpenAI Responses API.");
        }
    }
    return result;
}

# Converts `ai:ChatCompletionFunctions` to Responses API function tool definitions.
#
# + tools - The tool definitions to convert
# + return - Array of function tool objects in Responses API format
isolated function convertToResponsesTools(ai:ChatCompletionFunctions[] tools) returns responses:OpenAITool[] {
    responses:OpenAITool[] result = [];
    foreach ai:ChatCompletionFunctions tool in tools {
        ResponsesFunctionTool functionTool = {
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters ?: {},
            strict: false
        };
        result.push(functionTool);
    }
    return result;
}

# Converts a Responses API response to an `ai:ChatAssistantMessage`.
#
# + response - The Responses API response
# + return - A `ChatAssistantMessage` or an error
isolated function convertResponsesOutputToAssistantMessage(responses:InlineResponse200 response)
        returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatAssistantMessage result = {role: ai:ASSISTANT};
    ai:FunctionCall[] functionCalls = [];

    foreach responses:OpenAIOutputItem item in response.output {
        string itemType = item.'type;
        if itemType == "message" || itemType == "output_message" {
            ResponsesOutputMessageItem|error message = item.cloneWithType();
            if message is error {
                continue;
            }
            foreach ResponsesOutputContentItem contentPart in message.content {
                if contentPart.'type == "output_text" {
                    string? text = contentPart.text;
                    if text is string && text.length() > 0 {
                        result.content = (result.content ?: "") + text;
                    }
                }
            }
        } else if itemType == "function_call" {
            ResponsesFunctionCallItem|error functionCall = item.cloneWithType();
            if functionCall is error {
                return error ai:LlmInvalidResponseError("Failed to parse function call output item", functionCall);
            }
            json|error parsedArgs = functionCall.arguments.fromJsonString();
            if parsedArgs is error {
                return error ai:LlmInvalidResponseError(
                    "Failed to parse function call arguments as JSON", parsedArgs);
            }
            map<json>|error argsMap = parsedArgs.cloneWithType();
            if argsMap is error {
                return error ai:LlmInvalidResponseError(
                    "Failed to convert parsed arguments to expected type", argsMap);
            }
            functionCalls.push({
                name: functionCall.name,
                arguments: argsMap,
                id: functionCall.call_id
            });
        }
    }

    if functionCalls.length() > 0 {
        result.toolCalls = functionCalls;
    }

    if result.content is () && functionCalls.length() == 0 {
        return error ai:LlmInvalidResponseError("Empty response from the model");
    }

    return result;
}

# Posts a prepared Responses request to the configured surface.
#
# - **v1 GA** (`useV1` is `true`): the generated `responses:Client` posts `{serviceUrl}/responses`. `api-version`
#   is only sent when the caller opted into `preview`/`v1` (`v1ApiVersion`).
# - **Legacy** (otherwise): the raw HTTP client posts `POST {legacyBase}/responses?api-version={apiVersion}` with
#   the `api-key` header, where `legacyBase` is the resolved legacy base URL (see `resolveLegacyBase`).
#
# + responsesClient - The generated Responses connector for the v1 GA surface (`()` on the legacy path)
# + legacyResponsesClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key (sent as `api-key` on the legacy route)
# + apiVersion - The date-based `api-version` query value used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version forwarded on the v1 route, if any
# + request - The prepared Responses request
# + return - The Responses API response, or an `error` on failure
isolated function postResponsesRequest(responses:Client? responsesClient, http:Client? legacyResponsesClient,
        boolean useV1, string apiKey, string? apiVersion, string? v1ApiVersion,
        responses:OpenAICreateResponse request) returns responses:InlineResponse200|error {
    if useV1 {
        responses:Client? llmClient = responsesClient;
        if llmClient is () {
            return error("Responses (v1) client is not initialized");
        }
        if v1ApiVersion is string {
            return llmClient->/responses.post(request,
                    api\-version = <responses:AzureAIFoundryModelsApiVersion>v1ApiVersion);
        }
        return llmClient->/responses.post(request);
    }

    http:Client? llmClient = legacyResponsesClient;
    if llmClient is () {
        return error("Responses (legacy) client is not initialized");
    }
    responses:InlineResponse200 response = check llmClient->post(
            string `/responses?api-version=${apiVersion ?: ""}`, request.toJson(), {"api-key": apiKey});
    return response;
}

# Validates the status of an Azure OpenAI Responses API response and returns an error for any non-completed state.
#
# + response - The Responses API response
# + return - An `ai:Error` if the response did not complete successfully; otherwise `()`
isolated function checkResponseStatus(responses:InlineResponse200 response) returns ai:Error? {
    string? status = response.status;
    if status == "failed" {
        string errorMsg = "Response generation failed";
        responses:OpenAIResponseError? responseError = response.'error;
        if responseError is responses:OpenAIResponseError {
            errorMsg = responseError.message;
        }
        return error ai:LlmConnectionError(errorMsg);
    }
    if status == "incomplete" {
        string errorMsg = "Response generation incomplete";
        responses:OpenAIResponseIncompleteDetails? details = response.incomplete_details;
        if details is responses:OpenAIResponseIncompleteDetails {
            errorMsg = string `Response incomplete: ${details.toString()}`;
        }
        return error ai:LlmInvalidResponseError(errorMsg);
    }
    if status == "cancelled" {
        return error ai:LlmConnectionError("Response generation was cancelled");
    }
    if status == "in_progress" || status == "queued" {
        return error ai:LlmConnectionError(
            string `Response is still ${status}; use background mode with polling to handle async responses`);
    }
    return;
}

# Maps the module's `ConnectionConfig` to the `azure.openai.responses` connector configuration.
#
# Azure api-key authentication is carried solely by the `api-key` header. No `authorization` value is supplied:
# sending an empty `Authorization` header makes API Management/WAF front ends reject the request with a 401.
#
# + apiKey - The Azure OpenAI API key
# + cc - The module connection configuration to map
# + return - The `azure.openai.responses` connector configuration
isolated function toResponsesConnectionConfig(string apiKey, ConnectionConfig cc) returns responses:ConnectionConfig => {
    auth: {api\-key: apiKey},
    httpVersion: cc.httpVersion,
    http1Settings: cc.http1Settings ?: {},
    http2Settings: cc.http2Settings ?: {},
    timeout: cc.timeout,
    forwarded: cc.forwarded,
    poolConfig: cc.poolConfig,
    cache: cc.cache ?: {},
    compression: cc.compression,
    circuitBreaker: cc.circuitBreaker,
    retryConfig: cc.retryConfig,
    responseLimits: cc.responseLimits ?: {},
    secureSocket: cc.secureSocket,
    proxy: cc.proxy,
    validation: cc.validation
};

# Opens a streaming (`stream: true`) Responses request against the configured surface and returns the raw
# Server-Sent Event stream.
#
# The generated `responses:Client` (used for the non-streaming path) binds its response to a single value and
# cannot consume Server-Sent Events, so both surfaces stream through a raw HTTP client:
#
# - **v1 GA** (`useV1` is `true`): `v1ResponsesStreamClient` posts `{serviceUrl}/responses`. `api-version` is only
#   sent when the caller opted into `preview`/`v1` (`v1ApiVersion`).
# - **Legacy** (otherwise): `legacyResponsesClient` (already a raw client) posts
#   `{legacyBase}/responses?api-version={apiVersion}`.
#
# Both routes send the `api-key` header and set `stream: true` on the request before serializing it.
#
# + v1ResponsesStreamClient - The raw HTTP client for the v1 GA surface (`()` on the legacy path)
# + legacyResponsesClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key (sent as the `api-key` header on both routes)
# + apiVersion - The date-based `api-version` used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version to forward on the v1 route, if any
# + request - The prepared Responses request
# + return - The opened Server-Sent Event stream, or an `ai:Error` on failure
isolated function postResponsesStream(http:Client? v1ResponsesStreamClient, http:Client? legacyResponsesClient,
        boolean useV1, string apiKey, string? apiVersion, string? v1ApiVersion,
        responses:OpenAICreateResponse request) returns stream<http:SseEvent, error?>|ai:Error {
    request.'stream = true;

    http:Response|error response;
    if useV1 {
        http:Client? streamClient = v1ResponsesStreamClient;
        if streamClient is () {
            return error ai:Error("Responses (v1) streaming client is not initialized");
        }
        string path = "/responses";
        if v1ApiVersion is string {
            path += "?api-version=" + v1ApiVersion;
        }
        response = streamClient->post(path, request.toJson(), {"api-key": apiKey});
    } else {
        http:Client? streamClient = legacyResponsesClient;
        if streamClient is () {
            return error ai:Error("Responses (legacy) streaming client is not initialized");
        }
        response = streamClient->post(string `/responses?api-version=${apiVersion ?: ""}`, request.toJson(),
                {"api-key": apiKey});
    }
    if response is error {
        return error ai:LlmConnectionError("Error while connecting to the model for streaming", response);
    }
    // A non-2xx response body is JSON, not an SSE stream (`streamClient->post` does not raise `error` for these
    // status codes, unlike the generated connectors used elsewhere in this module); surface the actual error
    // body instead of letting `getSseEventStream` fail with an opaque content-type mismatch. The check is
    // `!= 200` rather than `>= 400` so a redirect or other unexpected non-200 is reported here too, instead of
    // reaching `getSseEventStream` and failing on a body that is not an event stream. Message extraction is
    // shared with the Chat Completions stream opener so both surfaces report a rejection identically.
    if response.statusCode != http:STATUS_OK {
        return error ai:Error(string `Azure OpenAI rejected the streaming Responses request ` +
                string `(HTTP ${response.statusCode}): ${extractAzureErrorMessage(response)}`);
    }
    stream<http:SseEvent, error?>|error sseStream = response.getSseEventStream();
    if sseStream is error {
        return error ai:Error("Failed to open the SSE stream from the model", sseStream);
    }
    return sseStream;
}

// ===== Streaming (`chatAsStream` via `apiType = RESPONSES`) wire types =====
//
// The Responses API streams a heterogeneous sequence of typed SSE events (`response.output_text.delta`,
// `response.function_call_arguments.delta`, `response.completed`, ...) instead of repeated deltas of one
// envelope shape like Chat Completions. Only the `type` discriminator and the per-event fields this module
// actually consumes are modeled below; every shape is an open record (no `{| |}`) so unrelated fields already
// present in the payload - and any Azure adds later - are ignored rather than rejected by `cloneWithType`.

# The `type` discriminator alone, read first to route a raw event to its specific shape below.
type ResponsesStreamEventType record {
    # The event kind, e.g. `response.output_text.delta`, `response.completed`
    string 'type;
};

# `response.output_item.added` - announces a new output item (a message, function call, or reasoning block) and
# its position; the `item.id` on a `function_call` item is the key later delta events reference via `item_id`.
type ResponsesStreamOutputItemAdded record {
    # The output item that was just added
    ResponsesStreamItem item;
};

# The `item` payload of an output-item-added event; only the fields needed to open a tool-call slot are modeled.
type ResponsesStreamItem record {
    # The item kind, e.g. `message`, `function_call`, `reasoning`
    string 'type;
    # Server-assigned id of this item; the key later delta events reference via `item_id`
    string id?;
    # Correlation id for a `function_call` item, echoed back on the matching tool result
    string call_id?;
    # Tool name, present on a `function_call` item
    string name?;
};

# `response.output_text.delta` - an incremental fragment of the assistant's visible answer text.
type ResponsesStreamTextDelta record {
    # The text fragment
    string delta;
};

# `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` - an incremental fragment of the
# model's reasoning ("thinking") content, when the deployment streams a reasoning summary.
type ResponsesStreamReasoningDelta record {
    # The reasoning text fragment
    string delta;
};

# `response.function_call_arguments.delta` - an incremental fragment of a streamed tool call's JSON arguments,
# keyed by `item_id` to the slot opened by the corresponding `response.output_item.added` event.
type ResponsesStreamFunctionCallArgumentsDelta record {
    # Id of the `function_call` item this fragment belongs to
    string item_id;
    # The arguments JSON-string fragment
    string delta;
};

# Token usage on the terminal streaming envelope. The connector's `OpenAIResponseUsage` requires both
# `input_tokens_details` and `output_tokens_details`; Azure does not always send them on the streaming terminal
# event, and a missing one would fail `cloneWithType` and turn a fully-delivered stream into an error at the very
# last event. Every count is therefore optional here, and the detail breakdowns (which this module does not
# surface) are simply not modeled.
type ResponsesStreamUsage record {
    # The number of input tokens
    int input_tokens?;
    # The number of output tokens
    int output_tokens?;
    # The total number of tokens used
    int total_tokens?;
};

# The error detail on a `response.failed` terminal event. The connector's `OpenAIResponseError` types `code` as
# `OpenAIResponseErrorCode`, a closed union of image/prompt-related codes only; any other code Azure returns
# (`content_filter`, `insufficient_quota`, `server_error` variants, ...) fails the bind and loses Azure's own
# error message. `code` is kept as a plain string here so the message always survives.
type ResponsesStreamError record {
    # The error code for the response
    string code?;
    # A human-readable description of the error
    string message?;
};

# Why generation stopped early on a `response.incomplete` terminal event. The connector's
# `OpenAIResponseIncompleteDetails` types `reason` as a closed `"max_output_tokens"|"content_filter"` union;
# it is kept as a plain string here so an unrecognized reason degrades to `STOP` instead of failing the bind.
type ResponsesStreamIncompleteDetails record {
    # The reason generation stopped early, e.g. `max_output_tokens`, `content_filter`
    string reason?;
};

# The `response` envelope embedded in a `response.completed` / `.failed` / `.incomplete` terminal streaming
# event. Deliberately looser than `InlineResponse200` (the non-streaming response type): only the fields this
# module reads are modeled, all as optional, and `error`/`incomplete_details` are additionally nilable since
# Azure sends both with an explicit JSON `null` on the terminal streaming envelope too (mirroring
# `InlineResponse200`'s own required-but-nilable fields) - declaring them as plain (non-nilable) optional fields
# makes `cloneWithType` reject that explicit `null` and fail even on a well-formed `response.completed` event.
# `usage`/`error`/`incomplete_details` use the loose module-local shapes above rather than the connector types,
# whose closed unions and required sub-records would reject well-formed terminal events.
type ResponsesStreamTerminalResponse record {
    # Unique identifier for this response
    string id?;
    # The status of the response generation
    string status?;
    # The content items generated by the model; present on a successful/failed/incomplete terminal event
    responses:OpenAIOutputItem[] output?;
    # Token usage; present once the response is complete
    ResponsesStreamUsage? usage?;
    # The error detail; present (possibly `null`) when `status` is `failed`
    ResponsesStreamError? 'error?;
    # Why generation stopped early; present (possibly `null`) when `status` is `incomplete`
    ResponsesStreamIncompleteDetails? incomplete_details?;
};

# `response.completed` / `response.failed` / `response.incomplete` - the terminal event carrying the response
# envelope (status, usage, output, and, on failure, the error).
type ResponsesStreamTerminalEvent record {
    # The response envelope
    ResponsesStreamTerminalResponse response;
};

# A top-level stream `error` event (distinct from a `response.failed` terminal event, e.g. a mid-stream rate
# limit or connection problem).
type ResponsesStreamErrorEvent record {
    # Human-readable error description
    string message;
};

# Maps a terminal Responses envelope onto the Chat-Completions-style finish reason. Returns `ai:FinishReason`
# rather than `ai:FinishReason?` because a terminal event always yields a definite outcome - falling back to
# `STOP` when the envelope carries neither an incomplete reason nor a tool call.
#
# An `incomplete` response ended early for a reason Chat Completions reports as an ordinary finish reason
# (`length`, `content_filter`) rather than as an error, so it is mapped the same way here: the partial output the
# model did produce stays usable instead of being discarded by a failed stream. Otherwise the reason is inferred
# from the `output` shape - `TOOL_CALLS` when the model's turn ended in a function call, `STOP` otherwise - since
# the Responses API has no direct equivalent of Chat Completions' `finish_reason: "tool_calls"`.
#
# + response - The terminal Responses envelope
# + return - The normalized finish reason
isolated function mapResponsesFinishReason(ResponsesStreamTerminalResponse response) returns ai:FinishReason {
    ResponsesStreamIncompleteDetails? details = response?.incomplete_details;
    if details is ResponsesStreamIncompleteDetails {
        string? reason = details.reason;
        if reason == "max_output_tokens" {
            return ai:LENGTH;
        }
        if reason == "content_filter" {
            return ai:CONTENT_FILTER;
        }
    }
    responses:OpenAIOutputItem[]? output = response.output;
    if output is responses:OpenAIOutputItem[] {
        foreach responses:OpenAIOutputItem item in output {
            if item.'type == "function_call" {
                return ai:TOOL_CALLS;
            }
        }
    }
    return ai:STOP;
}

# Builds the error for a terminal streaming event that reports a genuine failure (`failed`/`cancelled`),
# surfacing Azure's own message when it sent one. `incomplete` is deliberately not handled here: it is a normal
# early stop, mapped to a finish reason by `mapResponsesFinishReason` instead.
#
# + response - The terminal response envelope
# + return - The error describing the failure
isolated function buildStreamTerminalError(ResponsesStreamTerminalResponse response) returns ai:Error {
    if response.status == "cancelled" {
        return error ai:LlmConnectionError("Response generation was cancelled");
    }
    ResponsesStreamError? responseError = response?.'error;
    if responseError is ResponsesStreamError {
        string? message = responseError.message;
        if message is string {
            return error ai:LlmConnectionError(message);
        }
    }
    return error ai:LlmConnectionError("Response generation failed");
}

# Builds the final chunk for a `response.completed` / `response.incomplete` event: a content-less chunk carrying
# only the finish reason, matching the final finish-only chunk the Chat Completions path sends. Token usage is not
# carried onto the chunk - `ai:ChatMessageChunk` has no field for it - the iterator records it onto the span
# directly from the raw terminal envelope instead.
#
# + response - The terminal Responses envelope
# + return - The final normalized chunk
isolated function buildResponsesTerminalChunk(ResponsesStreamTerminalResponse response) returns ai:ChatMessageChunk {
    ai:ChatMessageChunk chunk = {role: ai:ASSISTANT, finishReason: mapResponsesFinishReason(response)};
    string? id = response.id;
    if id is string {
        chunk.id = id;
    }
    return chunk;
}

# Iterator that converts the Azure OpenAI Responses API's Server-Sent Event stream into a stream of normalized
# `ai:ChatMessageChunk` values.
#
# Unlike Chat Completions (which repeats one envelope shape per chunk), the Responses API streams a sequence of
# differently-shaped, `type`-discriminated events describing item lifecycle (`response.output_item.added`),
# incremental text/reasoning/tool-argument fragments, and a terminal envelope (`response.completed` /
# `.failed` / `.incomplete`). This iterator dispatches each event by its `type` and normalizes only the events
# `chatAsStream`'s contract cares about; every other event type (`response.content_part.added`, the `.done`
# companion of each `.delta` event, keep-alive comments, ...) is skipped. Each streamed `function_call` output
# item is assigned a stable `index` (keyed by its `item_id`) the first time it is seen, mirroring how Chat
# Completions correlates streamed tool-call argument fragments.
#
# A payload that is not valid JSON, or that does not bind to the shape its own `type` discriminator promises, is
# surfaced as an `ai:LlmInvalidResponseError` rather than skipped - skipping it would silently drop answer text
# or make a whole tool call vanish with no error. Event types this module does not consume are still skipped
# without inspecting their shape, so new Azure event types remain forward-compatible.
class ResponsesChunkIterator {
    private final stream<http:SseEvent, error?> sseStream;
    # The chat span opened by `chatAsStream`. The iterator owns it: a streaming request is not finished when
    # `chatAsStream` returns, only when the last chunk has been read, so the span is closed here.
    private final observe:ChatSpan span;
    private map<int> toolCallIndexByItemId = {};
    private int nextToolCallIndex = 0;
    # `true` once the stream has terminated (via `[DONE]`, exhaustion, an error, or an explicit `close`), so a
    # later `next` returns `()` instead of resuming reads against a finished stream.
    private boolean done = false;
    # Response id captured from `response.created`, stamped onto every chunk so `id` is stable across the
    # stream, as the `ai:ChatMessageChunk` contract describes. The Responses API carries it only on the
    # lifecycle events, not on the individual deltas.
    private string? responseId = ();
    # `true` once the response id has been recorded on the span; it repeats across the lifecycle events.
    private boolean responseIdRecorded = false;

    isolated function init(stream<http:SseEvent, error?> sseStream, observe:ChatSpan span) {
        self.sseStream = sseStream;
        self.span = span;
    }

    public isolated function next() returns record {|ai:ChatMessageChunk value;|}|ai:Error? {
        if self.done {
            return ();
        }
        while true {
            record {|http:SseEvent value;|}|error? event = self.sseStream.next();
            if event is () {
                self.finish();
                return ();
            }
            if event is error {
                ai:Error err = error ai:Error("Error while reading the model stream", event);
                self.finish(err);
                return err;
            }
            string? data = event.value.data;
            if data is () {
                continue;
            }
            string trimmedData = data.trim();
            if trimmedData == "" {
                continue;
            }
            if trimmedData == "[DONE]" {
                self.finish();
                return ();
            }
            json|error payload = trimmedData.fromJsonString();
            if payload is error {
                ai:Error err = error ai:LlmInvalidResponseError(
                        "Invalid or malformed event received from the Responses API stream", payload);
                self.finish(err);
                return err;
            }
            ResponsesStreamEventType|error typed = payload.cloneWithType();
            if typed is error {
                ai:Error err = error ai:LlmInvalidResponseError(
                        "Event without a 'type' discriminator received from the Responses API stream", typed);
                self.finish(err);
                return err;
            }

            record {|ai:ChatMessageChunk value;|}|ai:Error? result = self.handleEvent(typed.'type, payload);
            if result is ai:Error {
                self.finish(result);
                return result;
            }
            if result is () {
                continue;
            }
            self.recordObservations(result.value);
            return result;
        }
    }

    # Records the response id (once) and the finish reason carried by an emitted chunk. Token usage is recorded
    # separately, directly off the raw terminal envelope, since `ai:ChatMessageChunk` has no field for it.
    #
    # + chunk - The chunk about to be returned to the caller
    private isolated function recordObservations(ai:ChatMessageChunk chunk) {
        string? id = chunk.id;
        if !self.responseIdRecorded && id is string {
            self.span.addResponseId(id);
            self.responseIdRecorded = true;
        }
        ai:FinishReason? finishReason = chunk.finishReason;
        if finishReason is ai:FinishReason {
            self.span.addFinishReason(finishReason);
            self.span.addOutputType(observe:TEXT);
        }
    }

    private isolated function handleEvent(string eventType, json payload)
            returns record {|ai:ChatMessageChunk value;|}|ai:Error? {
        if eventType == "response.created" {
            // Purely informational: the only thing taken from it is the response id stamped onto later chunks,
            // so a shape this module does not recognize is not worth failing the stream over.
            ResponsesStreamTerminalEvent|error created = payload.cloneWithType();
            if created is ResponsesStreamTerminalEvent {
                self.responseId = created.response.id;
            }
            return ();
        }
        if eventType == "response.output_item.added" {
            ResponsesStreamOutputItemAdded|error added = payload.cloneWithType();
            if added is error {
                return error ai:LlmInvalidResponseError(
                        "Unexpected shape for a 'response.output_item.added' event", added);
            }
            return self.handleOutputItemAdded(added.item);
        }
        if eventType == "response.output_text.delta" {
            ResponsesStreamTextDelta|error textDelta = payload.cloneWithType();
            if textDelta is error {
                return error ai:LlmInvalidResponseError(
                        "Unexpected shape for a 'response.output_text.delta' event", textDelta);
            }
            if textDelta.delta.length() == 0 {
                return ();
            }
            return self.emit({role: ai:ASSISTANT, content: textDelta.delta});
        }
        if eventType == "response.reasoning_summary_text.delta" || eventType == "response.reasoning_text.delta" {
            ResponsesStreamReasoningDelta|error reasoningDelta = payload.cloneWithType();
            if reasoningDelta is error {
                return error ai:LlmInvalidResponseError(
                        string `Unexpected shape for a '${eventType}' event`, reasoningDelta);
            }
            if reasoningDelta.delta.length() == 0 {
                return ();
            }
            return self.emit({role: ai:ASSISTANT, reasoning: reasoningDelta.delta});
        }
        if eventType == "response.function_call_arguments.delta" {
            ResponsesStreamFunctionCallArgumentsDelta|error argsDelta = payload.cloneWithType();
            if argsDelta is error {
                return error ai:LlmInvalidResponseError(
                        "Unexpected shape for a 'response.function_call_arguments.delta' event", argsDelta);
            }
            int index = self.indexForItemId(argsDelta.item_id);
            return self.emit({role: ai:ASSISTANT, toolCalls: [{index, arguments: argsDelta.delta}]});
        }
        // `incomplete` is a normal early stop (token cap, content filter), not a failure: it is mapped onto a
        // terminal chunk carrying `LENGTH`/`CONTENT_FILTER` so the partial output already streamed stays usable,
        // matching how the Chat Completions path reports the same model behavior.
        if eventType == "response.completed" || eventType == "response.incomplete" {
            ResponsesStreamTerminalEvent|error terminal = payload.cloneWithType();
            if terminal is error {
                return error ai:LlmInvalidResponseError(
                        string `Unexpected shape for a '${eventType}' event`, terminal);
            }
            self.recordTerminalUsage(terminal.response);
            ai:ChatMessageChunk chunk = buildResponsesTerminalChunk(terminal.response);
            return {value: self.stamp(chunk)};
        }
        if eventType == "response.failed" {
            ResponsesStreamTerminalEvent|error terminal = payload.cloneWithType();
            if terminal is error {
                return error ai:LlmConnectionError("Response generation failed", terminal);
            }
            return buildStreamTerminalError(terminal.response);
        }
        if eventType == "error" {
            ResponsesStreamErrorEvent|error errorEvent = payload.cloneWithType();
            if errorEvent is error {
                return error ai:LlmConnectionError("Error event received from the Responses API stream");
            }
            return error ai:LlmConnectionError(errorEvent.message);
        }
        return ();
    }

    private isolated function handleOutputItemAdded(ResponsesStreamItem item)
            returns record {|ai:ChatMessageChunk value;|}|ai:Error? {
        if item.'type != "function_call" {
            return ();
        }
        string? itemId = item?.id;
        if itemId is () {
            return ();
        }
        int index = self.indexForItemId(itemId);
        ai:ToolCallChunk toolCall = {index};
        string? callId = item?.call_id;
        if callId is string {
            toolCall.id = callId;
        }
        string? name = item?.name;
        if name is string {
            toolCall.name = name;
        }
        return self.emit({role: ai:ASSISTANT, toolCalls: [toolCall]});
    }

    # Records token usage carried by a terminal envelope onto the span, read directly off the raw response since
    # `ai:ChatMessageChunk` has no field for it.
    #
    # + response - The terminal Responses envelope
    private isolated function recordTerminalUsage(ResponsesStreamTerminalResponse response) {
        ResponsesStreamUsage? usage = response?.usage;
        if usage is () {
            return;
        }
        int? inputTokens = usage.input_tokens;
        if inputTokens is int {
            self.span.addInputTokenCount(inputTokens);
        }
        int? outputTokens = usage.output_tokens;
        if outputTokens is int {
            self.span.addOutputTokenCount(outputTokens);
        }
    }

    # Wraps a chunk for return, stamping the stream-wide response id captured from `response.created` when the
    # chunk does not already carry one.
    #
    # + chunk - The chunk to emit; already carries `role: ASSISTANT`, as required by `ai:ChatMessageChunk`
    # + return - The chunk record the stream yields
    private isolated function emit(ai:ChatMessageChunk chunk) returns record {|ai:ChatMessageChunk value;|} =>
        {value: self.stamp(chunk)};

    # Stamps the captured response id onto a chunk that does not already carry one.
    #
    # + chunk - The chunk to stamp
    # + return - The same chunk, with `id` filled in where available
    private isolated function stamp(ai:ChatMessageChunk chunk) returns ai:ChatMessageChunk {
        if chunk.id is string {
            return chunk;
        }
        string? id = self.responseId;
        if id is string {
            chunk.id = id;
        }
        return chunk;
    }

    private isolated function indexForItemId(string itemId) returns int {
        int? existing = self.toolCallIndexByItemId[itemId];
        if existing is int {
            return existing;
        }
        int index = self.nextToolCallIndex;
        self.nextToolCallIndex += 1;
        self.toolCallIndexByItemId[itemId] = index;
        return index;
    }

    # Marks the stream finished, releases the underlying SSE connection, and closes the span. Termination via
    # `[DONE]` or a terminal event happens before the transport stream is exhausted, so without the close the
    # connection is left half-read and never returned to the pool. A close failure is not surfaced: the chunks
    # were already delivered, and failing the stream at that point would be misleading.
    #
    # + err - The error that terminated the stream, if any
    private isolated function finish(ai:Error? err = ()) {
        if self.done {
            return;
        }
        self.done = true;
        error? result = self.sseStream.close();
        if result is error {
            log:printDebug("Failed to close the Azure OpenAI Responses SSE stream", result);
        }
        self.span.close(err);
    }

    public isolated function close() returns ai:Error? {
        if self.done {
            return ();
        }
        self.done = true;
        error? result = self.sseStream.close();
        self.span.close(result is error ? result : ());
        if result is error {
            return error ai:Error("Error while closing the model stream", result);
        }
        return ();
    }
}

# Generates a structured value from the LLM via the Responses API (the `generate` method's responses path).
#
# + responsesClient - The generated Responses connector for the v1 GA surface (`()` on the legacy path)
# + legacyResponsesClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key
# + apiVersion - The date-based `api-version` used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version forwarded on the v1 route, if any
# + deploymentId - The Azure deployment ID (used as the model name)
# + temperature - The sampling temperature, if any
# + maxTokens - The maximum number of tokens to generate
# + reasoning - The reasoning effort, if any
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response, or an error
isolated function generateLlmResponseViaResponses(responses:Client? responsesClient,
        http:Client? legacyResponsesClient, boolean useV1, string apiKey, string? apiVersion, string? v1ApiVersion,
        string deploymentId, decimal? temperature, int maxTokens, ReasoningEffort? reasoning,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    span.addProvider("azure.ai.openai");
    if temperature is decimal {
        span.addTemperature(temperature);
    }

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    ResponsesInputContent[]|ai:Error inputContent = convertContentPartsForResponses(content);
    if inputContent is ai:Error {
        span.close(inputContent);
        return inputContent;
    }

    ResponsesFunctionTool getResultsTool = {
        name: GET_RESULTS_TOOL,
        parameters: responseSchema.schema,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        strict: false
    };
    ResponsesToolChoiceFunction toolChoice = {name: GET_RESULTS_TOOL};
    ResponsesInputMessage inputMessage = {role: "user", content: inputContent};

    responses:OpenAICreateResponse request = {
        model: deploymentId,
        input: [inputMessage],
        tools: [getResultsTool],
        tool_choice: toolChoice,
        max_output_tokens: maxTokens,
        store: false
    };
    if temperature is decimal {
        request.temperature = temperature;
    }
    if reasoning is ReasoningEffort {
        request.reasoning = {effort: reasoning};
    }
    span.addInputMessages([inputMessage].toJson());

    responses:InlineResponse200|error response = postResponsesRequest(responsesClient, legacyResponsesClient,
            useV1, apiKey, apiVersion, v1ApiVersion, request);
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), detail = response.detail(), cause = response.cause());
        span.close(err);
        return err;
    }

    ai:Error? statusError = checkResponseStatus(response);
    if statusError is ai:Error {
        span.close(statusError);
        return statusError;
    }

    span.addResponseId(response.id);
    responses:OpenAIResponseUsage? usage = response.usage;
    if usage is responses:OpenAIResponseUsage {
        span.addInputTokenCount(usage.input_tokens);
        span.addOutputTokenCount(usage.output_tokens);
    }

    string? toolArguments = ();
    foreach responses:OpenAIOutputItem item in response.output {
        if item.'type == "function_call" {
            ResponsesFunctionCallItem|error functionCall = item.cloneWithType();
            if functionCall is ResponsesFunctionCallItem && functionCall.name == GET_RESULTS_TOOL {
                toolArguments = functionCall.arguments;
                break;
            }
        }
    }

    if toolArguments is () {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    map<json>|error arguments = toolArguments.fromJsonStringWithType();
    if arguments is error {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof response).toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}
