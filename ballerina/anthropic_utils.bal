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
import ballerina/constraint;
import ballerina/http;

// ===== Constants =====

# The Messages API route, appended to the resolved `/anthropic` base URL.
const ANTHROPIC_MESSAGES_PATH = "/v1/messages";

# The base-path segment Azure exposes the Anthropic (Claude) surface under.
const ANTHROPIC_BASE_SEGMENT = "/anthropic";

# The beta opt-in required to reference an uploaded file by id in a `document` content block.
const ANTHROPIC_FILES_BETA = "files-api-2025-04-14";

# Provider name recorded on observability spans.
const ANTHROPIC_PROVIDER_NAME = "azure.ai.anthropic";

# The smallest `budget_tokens` value the Messages API accepts for manual extended thinking.
const MIN_THINKING_BUDGET_TOKENS = 1024;

# The prefix used for synthesized tool-use ids, matching the ids the Messages API issues itself (`toolu_...`).
const ANTHROPIC_TOOL_ID_PREFIX = "toolu";

# An `input_schema` for a tool that takes no parameters. The Messages API requires every tool to carry a
# JSON Schema object, so a parameterless tool is described as an object with no properties.
final readonly & map<json> EMPTY_TOOL_INPUT_SCHEMA = {"type": "object", "properties": {}};

// ===== Messages API request shapes =====
// Each record mirrors the Anthropic Messages API wire format exactly, so the field names are the wire names.

type AnthropicTextBlock record {|
    "text" 'type = "text";
    string text;
|};

type AnthropicBase64Source record {|
    "base64" 'type = "base64";
    string media_type;
    string data;
|};

type AnthropicUrlSource record {|
    "url" 'type = "url";
    string url;
|};

type AnthropicFileSource record {|
    "file" 'type = "file";
    string file_id;
|};

type AnthropicImageBlock record {|
    "image" 'type = "image";
    AnthropicBase64Source|AnthropicUrlSource 'source;
|};

type AnthropicDocumentBlock record {|
    "document" 'type = "document";
    AnthropicBase64Source|AnthropicUrlSource|AnthropicFileSource 'source;
|};

type AnthropicToolUseBlock record {|
    "tool_use" 'type = "tool_use";
    string id;
    string name;
    map<json> input;
|};

// The wire shape also carries an `is_error` flag, which is not modelled: `ai:ChatFunctionMessage` cannot express
// a failed tool invocation, so there is nothing to map onto it.
type AnthropicToolResultBlock record {|
    "tool_result" 'type = "tool_result";
    string tool_use_id;
    string content?;
|};

# A content block of an Anthropic Messages API request.
type AnthropicContentBlock AnthropicTextBlock|AnthropicImageBlock|AnthropicDocumentBlock|AnthropicToolUseBlock|
    AnthropicToolResultBlock;

# The content blocks that can be produced from an `ai:Prompt` (a document/chunk insertion or plain text).
type AnthropicPromptBlock AnthropicTextBlock|AnthropicImageBlock|AnthropicDocumentBlock;

type AnthropicMessage record {|
    "user"|"assistant" role;
    AnthropicContentBlock[] content;
|};

type AnthropicTool record {|
    string name;
    string description?;
    map<json> input_schema;
|};

// Only `tool` is used today (by the `generate` method's forced `getResults` call); `chat` leaves the field unset
// so the service default (`auto`) applies. The other members are kept because they are the wire contract.
type AnthropicToolChoice record {|
    "auto"|"any"|"tool"|"none" 'type;
    string name?;
|};

# The parts of a Messages API request derived from an `ai:ChatMessage` list.
#
# The Messages API keeps system instructions in a dedicated top-level `system` field rather than as a message,
# and it needs to know whether the request references an uploaded file (which requires a beta opt-in header),
# so both travel alongside the converted messages.
type AnthropicRequestParts record {|
    # The converted conversation turns
    AnthropicMessage[] messages;
    # The concatenated system messages, or `()` when the conversation carries none
    string? system;
    # `true` when any content block references a file by id, which requires the Files API beta header
    boolean usesFileSource;
|};

// ===== Messages API response shapes =====
// Open records with a `json` rest field so that response fields this module does not consume (for example
// `thinking` blocks or newly added usage counters) bind without failing.

type AnthropicResponseBlock record {|
    string 'type;
    // `text` blocks
    string? text?;
    // `tool_use` blocks
    string? id?;
    string? name?;
    json input?;
    json...;
|};

type AnthropicUsage record {|
    int? input_tokens?;
    int? output_tokens?;
    json...;
|};

type AnthropicStopDetails record {|
    string 'type?;
    string? category?;
    string? explanation?;
    json...;
|};

type AnthropicMessagesResponse record {|
    string id?;
    string 'type?;
    string role?;
    string model?;
    AnthropicResponseBlock[] content;
    string? stop_reason?;
    string? stop_sequence?;
    AnthropicStopDetails? stop_details?;
    AnthropicUsage? usage?;
    json...;
|};

// ===== Service URL resolution =====

# Resolves the base URL of the Azure Anthropic (Claude) surface from a caller-supplied service URL.
#
# Azure documents the base URL as `https://<resource>.services.ai.azure.com/anthropic` and the target URI as
# `{base}/v1/messages`, so this function normalises the common shapes a caller may have on hand:
#
# - a single trailing slash is dropped;
# - a `/v1/messages` or `/v1` suffix (i.e. the full target URI, copied from the deployment details) is removed,
#   because the route is appended per request;
# - a **bare origin** (e.g. `https://<resource>.services.ai.azure.com`) is completed with `/anthropic`;
# - a URL that already carries a path is used **verbatim**, so a caller fronting the service through API
#   Management or another gateway owns their base path.
#
# + serviceUrl - The caller-supplied service URL
# + return - The base URL that `/v1/messages` is appended to
isolated function resolveAnthropicBase(string serviceUrl) returns string {
    string trimmed = trimTrailingSlash(serviceUrl);
    if trimmed.endsWith(ANTHROPIC_MESSAGES_PATH) {
        trimmed = trimTrailingSlash(trimmed.substring(0, trimmed.length() - ANTHROPIC_MESSAGES_PATH.length()));
    } else if trimmed.endsWith("/v1") {
        trimmed = trimTrailingSlash(trimmed.substring(0, trimmed.length() - 3));
    }
    return hasPathSegment(trimmed) ? trimmed : trimmed + ANTHROPIC_BASE_SEGMENT;
}

isolated function trimTrailingSlash(string url) returns string {
    string trimmed = url;
    while trimmed.endsWith("/") {
        trimmed = trimmed.substring(0, trimmed.length() - 1);
    }
    return trimmed;
}

// ===== Request configuration validation =====

# Validates a thinking configuration against the Messages API rules.
#
# Three rules are checked, all of which the service enforces with a 400 on every request:
#
# 1. `budget_tokens` is required by (and only valid for) manual extended thinking.
# 2. It must be at least 1024 and must leave room for the answer within `max_tokens`.
# 3. `temperature` cannot be combined with thinking. On the newer Claude models a non-default `temperature` is
#    rejected outright; on the older ones the restriction applies whenever thinking is on.
#
# Catching these at initialization turns a request-time 400 from the service into an actionable error at the
# call site.
#
# + thinking - The thinking configuration to validate, if any
# + maxTokens - The configured response token limit
# + temperature - The configured sampling temperature, if any
# + return - An `ai:Error` when the configuration is invalid; otherwise `()`
isolated function validateThinking(Thinking? thinking, int maxTokens, decimal? temperature) returns ai:Error? {
    if thinking is () {
        return;
    }
    if temperature is decimal && thinking.'type != "disabled" {
        return error ai:Error(string `The 'temperature' argument cannot be combined with thinking; the Messages ` +
                string `API rejects a sampling temperature while thinking is on (found the thinking type "${
                thinking.'type}"). Drop 'temperature', or set the thinking type to "disabled".`);
    }
    int? budgetTokens = thinking.budgetTokens;
    if thinking.'type != "enabled" {
        if budgetTokens is int {
            return error ai:Error(string `The 'budgetTokens' field is only valid when the thinking type is ` +
                    string `"enabled"; found the type "${thinking.'type}".`);
        }
        return;
    }
    if budgetTokens is () {
        return error ai:Error("The 'budgetTokens' field is required when the thinking type is \"enabled\".");
    }
    if budgetTokens < MIN_THINKING_BUDGET_TOKENS {
        return error ai:Error(string `The 'budgetTokens' field must be at least ${
            MIN_THINKING_BUDGET_TOKENS}; found ${budgetTokens}.`);
    }
    if budgetTokens >= maxTokens {
        return error ai:Error(string `The 'budgetTokens' field (${budgetTokens}) must be less than 'maxTokens' (${
            maxTokens}), because thinking tokens count towards the response token limit.`);
    }
    return;
}

# Maps a `Thinking` value to its Messages API wire form (`budgetTokens` becomes `budget_tokens`).
#
# + thinking - The thinking configuration
# + return - The `thinking` field value
isolated function toThinkingJson(Thinking thinking) returns map<json> {
    map<json> result = {"type": thinking.'type};
    int? budgetTokens = thinking.budgetTokens;
    if budgetTokens is int {
        result["budget_tokens"] = budgetTokens;
    }
    ThinkingDisplay? display = thinking.display;
    if display is ThinkingDisplay {
        result["display"] = display;
    }
    return result;
}

// ===== Message conversion =====

# Converts `ai:ChatMessage`s to Anthropic Messages API turns.
#
# Three structural differences from the OpenAI chat shape are handled here:
#
# 1. System messages are not turns. They are concatenated into the top-level `system` field.
# 2. Tool results are not their own role. Each `ai:ChatFunctionMessage` becomes a `tool_result` content block
#    inside a **user** turn.
# 3. Turns alternate. Consecutive messages that map to the same role are merged into one turn, which is also
#    what keeps the results of parallel tool calls together in a single user turn - splitting them across
#    turns degrades the model's willingness to keep calling tools in parallel.
#
# + messages - The chat messages, or a single user message
# + return - The converted request parts, or an `ai:Error` when a message carries unsupported content
isolated function convertToAnthropicMessages(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns AnthropicRequestParts|ai:Error {
    AnthropicMessage[] anthropicMessages = [];
    string[] systemParts = [];
    boolean usesFileSource = false;

    // Note: the `is` check is written against the array type rather than `ai:ChatUserMessage` because a `[`
    // immediately after the `?` of a conditional expression is parsed as an array type descriptor.
    ai:ChatMessage[] messageList = messages is ai:ChatMessage[] ? messages : [messages];
    // Per-tool-name occurrence counters used only when a message carries no id of its own. Counting calls and
    // results separately keeps the nth call to a given tool paired with the nth result for that tool, while
    // still giving each call its own id.
    map<int> toolCallCounts = {};
    map<int> toolResultCounts = {};

    foreach ai:ChatMessage message in messageList {
        if message is ai:ChatSystemMessage {
            systemParts.push(check getChatMessageStringContent(message.content));
        } else if message is ai:ChatUserMessage {
            AnthropicPromptBlock[] blocks = check buildAnthropicUserContent(message.content);
            usesFileSource = usesFileSource || containsFileSource(blocks);
            appendAnthropicBlocks(anthropicMessages, "user", widenToContentBlocks(blocks));
        } else if message is ai:ChatAssistantMessage {
            appendAnthropicBlocks(anthropicMessages, "assistant",
                    buildAssistantBlocks(message, toolCallCounts));
        } else if message is ai:ChatFunctionMessage {
            appendAnthropicBlocks(anthropicMessages, "user", [buildToolResultBlock(message, toolResultCounts)]);
        }
    }

    normalizeToolResultOrder(anthropicMessages);
    if anthropicMessages.length() == 0 {
        return error ai:Error("At least one user or assistant message with content is required; the Anthropic " +
                "Messages API carries system instructions in a separate field and cannot be sent on its own.");
    }
    return {
        messages: anthropicMessages,
        system: systemParts.length() > 0 ? string:'join("\n\n", ...systemParts) : (),
        usesFileSource
    };
}

# Builds the content blocks of an assistant turn: its text (when present) followed by one `tool_use` block per
# requested tool call.
#
# + message - The assistant message
# + counts - Per-tool-name occurrence counters used to synthesize missing ids, updated in place
# + return - The assistant content blocks; empty when the message carries neither text nor tool calls
isolated function buildAssistantBlocks(ai:ChatAssistantMessage message, map<int> counts)
        returns AnthropicContentBlock[] {
    AnthropicContentBlock[] blocks = [];
    string? content = message.content;
    // The Messages API rejects empty text blocks, and an assistant turn that only announced tool calls
    // legitimately has no text, so a blank content value is dropped rather than sent.
    if content is string && content.trim().length() > 0 {
        blocks.push(<AnthropicTextBlock>{text: content});
    }
    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is ai:FunctionCall[] {
        foreach ai:FunctionCall toolCall in toolCalls {
            blocks.push(<AnthropicToolUseBlock>{
                id: toolCall.id ?: nextToolCallId(toolCall.name, counts, ANTHROPIC_TOOL_ID_PREFIX),
                name: toolCall.name,
                input: toolCall.arguments ?: {}
            });
        }
    }
    return blocks;
}

# Builds the `tool_result` block for a tool (function) result message.
#
# + message - The function message carrying the tool result
# + counts - Per-tool-name occurrence counters used to synthesize missing ids, updated in place
# + return - The `tool_result` content block
isolated function buildToolResultBlock(ai:ChatFunctionMessage message, map<int> counts)
        returns AnthropicToolResultBlock {
    AnthropicToolResultBlock block = {
        tool_use_id: message.id ?: nextToolCallId(message.name, counts, ANTHROPIC_TOOL_ID_PREFIX)
    };
    string? content = message.content;
    // `content` is optional on the wire; sending an empty string is rejected, so an absent or blank result is
    // represented by omitting the field.
    if content is string && content.trim().length() > 0 {
        block.content = content;
    }
    return block;
}

# Appends content blocks as a turn, merging into the previous turn when it has the same role.
#
# + messages - The turns built so far, updated in place
# + role - The role of the blocks being appended
# + blocks - The content blocks to append; an empty list is ignored
isolated function appendAnthropicBlocks(AnthropicMessage[] messages, "user"|"assistant" role,
        AnthropicContentBlock[] blocks) {
    if blocks.length() == 0 {
        return;
    }
    int count = messages.length();
    if count > 0 {
        AnthropicMessage last = messages[count - 1];
        if last.role == role {
            foreach AnthropicContentBlock block in blocks {
                last.content.push(block);
            }
            return;
        }
    }
    messages.push({role, content: blocks});
}

# Moves `tool_result` blocks to the front of every user turn that also carries other content.
#
# The Messages API requires the tool results of the preceding assistant turn to lead the user turn that answers
# it. Merging turns preserves the natural agent ordering already, so this only matters for a history whose
# messages arrive out of order.
#
# + messages - The turns to normalize, updated in place
isolated function normalizeToolResultOrder(AnthropicMessage[] messages) {
    foreach AnthropicMessage message in messages {
        if message.role != "user" {
            continue;
        }
        AnthropicContentBlock[] toolResults = [];
        AnthropicContentBlock[] others = [];
        foreach AnthropicContentBlock block in message.content {
            if block is AnthropicToolResultBlock {
                toolResults.push(block);
            } else {
                others.push(block);
            }
        }
        if toolResults.length() == 0 || others.length() == 0 {
            continue;
        }
        foreach AnthropicContentBlock block in others {
            toolResults.push(block);
        }
        message.content = toolResults;
    }
}

# Copies prompt content blocks into a content-block array.
#
# A cast would keep the array's inherent type as `AnthropicPromptBlock[]`, and appending a `tool_result` block to
# the same turn later (a user message immediately followed by a tool result) would then panic with an inherent
# type violation. Copying gives an array that accepts every content block kind.
#
# + blocks - The prompt content blocks
# + return - The same blocks in an `AnthropicContentBlock[]`
isolated function widenToContentBlocks(AnthropicPromptBlock[] blocks) returns AnthropicContentBlock[] {
    AnthropicContentBlock[] contentBlocks = [];
    foreach AnthropicPromptBlock block in blocks {
        contentBlocks.push(block);
    }
    return contentBlocks;
}

isolated function containsFileSource(AnthropicPromptBlock[] blocks) returns boolean {
    foreach AnthropicPromptBlock block in blocks {
        if block is AnthropicDocumentBlock && block.'source is AnthropicFileSource {
            return true;
        }
    }
    return false;
}

# Builds the content blocks of a user turn from either a plain string or a prompt with insertions.
#
# + content - The user message content
# + return - The content blocks, or an `ai:Error` for unsupported content
isolated function buildAnthropicUserContent(string|ai:Prompt content) returns AnthropicPromptBlock[]|ai:Error {
    if content is string {
        AnthropicTextBlock? block = buildAnthropicTextBlock(content);
        if block is AnthropicTextBlock {
            return [block];
        }
        return [];
    }
    return generateAnthropicContent(content);
}

# Converts an `ai:Prompt` to Anthropic content blocks, interleaving the template's text with its document
# insertions in the order they appear.
#
# + prompt - The prompt to convert
# + return - The content blocks, or an `ai:Error` for an unsupported document type
isolated function generateAnthropicContent(ai:Prompt prompt) returns AnthropicPromptBlock[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    AnthropicPromptBlock[] blocks = [];
    string accumulatedText = strings.length() > 0 ? strings[0] : "";

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string next = strings[i + 1];

        if insertion is ai:Document|ai:Chunk {
            accumulatedText = flushAnthropicText(accumulatedText, blocks);
            check addAnthropicDocumentBlock(insertion, blocks);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            accumulatedText = flushAnthropicText(accumulatedText, blocks);
            foreach ai:Document|ai:Chunk document in insertion {
                check addAnthropicDocumentBlock(document, blocks);
            }
        } else {
            accumulatedText += insertion.toString();
        }
        accumulatedText += next;
    }

    _ = flushAnthropicText(accumulatedText, blocks);
    return blocks;
}

# Pushes the accumulated text as a text block, if it is non-empty, and resets the accumulator.
#
# + text - The accumulated text
# + blocks - The content blocks built so far, updated in place
# + return - The empty accumulator
isolated function flushAnthropicText(string text, AnthropicPromptBlock[] blocks) returns string {
    AnthropicTextBlock? block = buildAnthropicTextBlock(text);
    if block is AnthropicTextBlock {
        blocks.push(block);
    }
    return "";
}

# Builds a text block, or `()` when the text carries no content.
#
# The Messages API rejects text blocks that are empty or whitespace-only, which a prompt naturally produces
# between two adjacent document insertions.
#
# + text - The text content
# + return - The text block, or `()` when there is nothing to send
isolated function buildAnthropicTextBlock(string text) returns AnthropicTextBlock? =>
    text.trim().length() == 0 ? () : {text};

# Appends the content block for a single document or chunk.
#
# + document - The document or chunk to convert
# + blocks - The content blocks built so far, updated in place
# + return - An `ai:Error` for an unsupported document type; otherwise `()`
isolated function addAnthropicDocumentBlock(ai:Document|ai:Chunk document, AnthropicPromptBlock[] blocks)
        returns ai:Error? {
    if document is ai:TextDocument|ai:TextChunk {
        AnthropicTextBlock? block = buildAnthropicTextBlock(document.content);
        if block is AnthropicTextBlock {
            blocks.push(block);
        }
        return;
    }
    if document is ai:ImageDocument {
        blocks.push(check buildAnthropicImageBlock(document));
        return;
    }
    if document is ai:FileDocument {
        blocks.push(check buildAnthropicDocumentBlock(document));
        return;
    }
    if document is ai:AudioDocument {
        return error ai:Error("Audio documents are not supported by the Anthropic Messages API. " +
                "Only text, image and file (PDF or plain text) documents are supported.");
    }
    return error ai:Error("Only text, image and file documents are supported.");
}

isolated function buildAnthropicImageBlock(ai:ImageDocument document) returns AnthropicImageBlock|ai:Error {
    ai:Url|byte[] content = document.content;
    if content is ai:Url {
        return {'source: {url: check validateUrl(content)}};
    }
    string? mimeType = document.metadata?.mimeType;
    if mimeType is () {
        // Unlike the OpenAI data URL form, the Messages API takes the media type as its own field and has no
        // wildcard default, so it cannot be guessed.
        return error ai:Error("Please specify the image media type in the 'mimeType' field of the metadata " +
                "(for example \"image/png\") when passing image content as binary data.");
    }
    return {'source: {media_type: mimeType, data: check getBase64EncodedString(content)}};
}

isolated function buildAnthropicDocumentBlock(ai:FileDocument document) returns AnthropicDocumentBlock|ai:Error {
    byte[]|ai:Url|ai:FileId content = document.content;
    if content is ai:Url {
        return {'source: {url: check validateUrl(content)}};
    }
    if content is ai:FileId {
        return {'source: {file_id: content.fileId}};
    }
    string? mimeType = document.metadata?.mimeType;
    if mimeType is () {
        return error ai:Error("Please specify the document media type in the 'mimeType' field of the metadata " +
                "(for example \"application/pdf\") when passing file content as binary data.");
    }
    return {'source: {media_type: mimeType, data: check getBase64EncodedString(content)}};
}

isolated function validateUrl(ai:Url url) returns ai:Url|ai:Error {
    ai:Url|constraint:Error validationResult = constraint:validate(url);
    if validationResult is error {
        return error ai:Error(validationResult.message(), validationResult.cause());
    }
    return url;
}

// ===== Tool conversion =====

# Converts `ai:ChatCompletionFunctions` to Anthropic tool definitions.
#
# + tools - The tool definitions to convert
# + return - The tools in Messages API format
isolated function convertToAnthropicTools(ai:ChatCompletionFunctions[] tools) returns AnthropicTool[] =>
    from ai:ChatCompletionFunctions tool in tools
    select {
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters ?: EMPTY_TOOL_INPUT_SCHEMA
    };

# Builds the `getResults` tool used by the `generate` method to force a structured response out of the model.
#
# + parameters - The JSON schema of the expected response
# + return - A single-element tool list
isolated function getAnthropicGetResultsTool(map<json> parameters) returns AnthropicTool[] => [
    {
        name: GET_RESULTS_TOOL,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        input_schema: parameters
    }
];

// ===== Request building =====

# Assembles a Messages API request body.
#
# + deploymentId - The Azure deployment name, sent as `model`
# + maxTokens - The response token limit (required by the Messages API)
# + temperature - The sampling temperature, when configured
# + thinking - The thinking configuration, when configured
# + effort - The effort level, when configured
# + parts - The converted messages and system instructions
# + tools - The tool definitions, when the request carries any
# + toolChoice - The tool choice, when the request forces one
# + stop - A stop sequence, when supplied
# + return - The request body
isolated function buildAnthropicRequest(string deploymentId, int maxTokens, decimal? temperature,
        Thinking? thinking, Effort? effort, AnthropicRequestParts parts, AnthropicTool[]? tools,
        AnthropicToolChoice? toolChoice, string? stop) returns map<json> {
    map<json> request = {
        model: deploymentId,
        max_tokens: maxTokens,
        messages: parts.messages
    };
    string? system = parts.system;
    if system is string {
        request["system"] = system;
    }
    if temperature is decimal {
        request["temperature"] = temperature;
    }
    if thinking is Thinking {
        request["thinking"] = toThinkingJson(thinking);
    }
    if effort is Effort {
        request["output_config"] = {effort: effort};
    }
    // A blank stop sequence is rejected by the service, and an empty `stop_sequences` entry carries no meaning,
    // so it is dropped rather than forwarded.
    if stop is string && stop.trim().length() > 0 {
        request["stop_sequences"] = [stop];
    }
    if tools is AnthropicTool[] && tools.length() > 0 {
        request["tools"] = tools;
        if toolChoice is AnthropicToolChoice {
            request["tool_choice"] = toolChoice;
        }
    }
    return request;
}

# Drops a thinking configuration that the Messages API rejects alongside a forced `tool_choice`.
#
# Manual extended thinking (`type: "enabled"`) is not supported with `tool_choice` of `any` or `tool` and
# returns a 400. Adaptive thinking supports forced tool use, so it is passed through unchanged. The
# `generate` method always forces the `getResults` tool, so the manual configuration is dropped there (and only
# there) rather than failing the call.
#
# + thinking - The configured thinking, if any
# + return - The thinking configuration to send, or `()` to omit the field
isolated function thinkingForForcedToolUse(Thinking? thinking) returns Thinking? {
    if thinking is Thinking && thinking.'type == "enabled" {
        // The provider warns about this once at initialization rather than on every call, since the
        // configuration is fixed for the lifetime of the provider.
        return ();
    }
    return thinking;
}

// ===== Transport =====

# Posts a prepared request to the Azure Anthropic Messages API (`POST {serviceUrl}/v1/messages`).
#
# Authentication is the deployment's API key in the `x-api-key` header, and the Messages API version travels in
# the `anthropic-version` header. Unlike the Azure OpenAI surfaces, this route takes **no** `api-version` query
# parameter.
#
# + anthropicClient - The HTTP client pointed at the resolved `/anthropic` base URL
# + apiKey - The Azure deployment API key
# + anthropicVersion - The `anthropic-version` header value
# + request - The prepared request body
# + usesFileSource - `true` when the request references an uploaded file by id, which needs the Files API beta
# + return - The parsed response, or an `ai:Error` on a transport, status or binding failure
isolated function postAnthropicMessages(http:Client anthropicClient, string apiKey, string anthropicVersion,
        map<json> request, boolean usesFileSource) returns AnthropicMessagesResponse|ai:Error {
    map<string|string[]> headers = {
        "x-api-key": apiKey,
        "anthropic-version": anthropicVersion
    };
    if usesFileSource {
        headers["anthropic-beta"] = ANTHROPIC_FILES_BETA;
    }

    http:Response|error response = anthropicClient->post(ANTHROPIC_MESSAGES_PATH, request, headers);
    if response is error {
        return error ai:LlmConnectionError("Error while connecting to the model", response);
    }

    int statusCode = response.statusCode;
    // Any 2xx is accepted rather than only 200, so that a gateway fronting the service cannot break the call
    // with a different success status.
    if statusCode < 200 || statusCode >= 300 {
        // The body is read as text and parsed here rather than through `getJsonPayload`, so that a gateway's
        // plain-text or HTML error page survives into the message instead of being lost to a binding failure.
        string|error errorBody = response.getTextPayload();
        json|error errorPayload = errorBody is string ? errorBody.fromJsonString() : errorBody;
        string message = buildAnthropicErrorMessage(statusCode, errorPayload, errorBody);
        // A 4xx is a rejected request (a bad parameter for the deployed model, an invalid key, a rate limit),
        // not a connection failure, so it is not reported as one: a caller retrying `ai:LlmConnectionError`
        // would otherwise retry a request that can never succeed as sent.
        return statusCode < 500 ? error ai:LlmError(message) : error ai:LlmConnectionError(message);
    }

    json|error payload = response.getJsonPayload();
    if payload is error {
        return error ai:LlmInvalidResponseError("Unable to read the response from the model", payload);
    }
    AnthropicMessagesResponse|error parsed = payload.cloneWithType();
    if parsed is error {
        return error ai:LlmInvalidResponseError("Unexpected response format from the Anthropic Messages API",
                parsed);
    }
    return parsed;
}

# Builds the error message for a non-2xx response, surfacing the Anthropic error envelope when present.
#
# The Messages API reports failures as `{"type": "error", "error": {"type": ..., "message": ...}}`, and those
# messages name the offending field (for example an unsupported `thinking` or `temperature` value for the
# deployed model), so they are worth propagating verbatim.
#
# + statusCode - The HTTP status code
# + payload - The response payload, or the error raised while reading it
# + textPayload - The response body read as text, used when it is not the JSON error envelope (for example a
#               gateway's plain-text or HTML error page)
# + return - The error message
isolated function buildAnthropicErrorMessage(int statusCode, json|error payload,
        string|error? textPayload = ()) returns string {
    string prefix = string `Anthropic Messages API request failed with status ${statusCode}`;
    if payload is map<json> {
        json errorValue = payload["error"];
        if errorValue is map<json> {
            json message = errorValue["message"];
            if message is string {
                json errorType = errorValue["type"];
                string typeSuffix = errorType is string ? string ` (${errorType})` : "";
                return string `${prefix}${typeSuffix}: ${message}`;
            }
        }
    }
    // Not the documented envelope: keep whatever body there is rather than discarding the only diagnostic.
    string body = "";
    if payload is json && payload !is () {
        body = payload.toJsonString();
    } else if textPayload is string {
        body = textPayload;
    }
    string trimmedBody = body.trim();
    return trimmedBody.length() == 0 ? prefix : string `${prefix}: ${trimmedBody}`;
}

// ===== Response handling =====

# Rejects the two `stop_reason` values that carry no usable answer.
#
# `refusal` is the safety-classifier decline documented for the newer Claude models: the call succeeds with
# HTTP 200 but carries no content, so it must not be handed back as an answer. `model_context_window_exceeded`
# means the conversation no longer fits. Every other reason - including `max_tokens` (a truncated but usable
# answer) and `pause_turn` - is passed through, and the reason is recorded on the span.
#
# + response - The Messages API response
# + return - An `ai:Error` when the response cannot be used; otherwise `()`
isolated function checkAnthropicStopReason(AnthropicMessagesResponse response) returns ai:Error? {
    string? stopReason = response?.stop_reason;
    if stopReason == "refusal" {
        AnthropicStopDetails? details = response?.stop_details;
        string suffix = "";
        if details is AnthropicStopDetails {
            string? category = details?.category;
            string? explanation = details?.explanation;
            suffix = category is string ? string ` (category: ${category})` : "";
            suffix += explanation is string ? string `: ${explanation}` : "";
        }
        return error ai:LlmError(string `The model declined to respond to the request${suffix}`);
    }
    if stopReason == "model_context_window_exceeded" {
        return error ai:LlmInvalidResponseError(
                "The request exceeded the model's context window; reduce the conversation or prompt size");
    }
    return;
}

# Converts a Messages API response to an `ai:ChatAssistantMessage`.
#
# `text` blocks are concatenated into the message content and `tool_use` blocks become `ai:FunctionCall`s.
# `thinking` and `redacted_thinking` blocks carry the model's reasoning, which `ai:ChatAssistantMessage` cannot
# represent, so they are skipped.
#
# + response - The Messages API response
# + return - The assistant message, or an `ai:Error` when the response carries no usable content
isolated function convertAnthropicResponseToAssistantMessage(AnthropicMessagesResponse response)
        returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatAssistantMessage result = {role: ai:ASSISTANT};
    ai:FunctionCall[] toolCalls = [];

    foreach AnthropicResponseBlock block in response.content {
        if block.'type == "text" {
            string? text = block?.text;
            if text is string && text.length() > 0 {
                result.content = (result.content ?: "") + text;
            }
        } else if block.'type == "tool_use" {
            toolCalls.push(check toFunctionCall(block));
        }
    }

    if toolCalls.length() > 0 {
        result.toolCalls = toolCalls;
    }
    if result.content is () && toolCalls.length() == 0 {
        return error ai:LlmInvalidResponseError("Empty response from the model");
    }
    return result;
}

# Converts a `tool_use` response block to an `ai:FunctionCall`.
#
# + block - The `tool_use` block
# + return - The function call, or an `ai:Error` when the block is malformed
isolated function toFunctionCall(AnthropicResponseBlock block) returns ai:FunctionCall|ai:Error {
    string? name = block?.name;
    if name is () {
        return error ai:LlmInvalidResponseError("A 'tool_use' response block is missing the tool name");
    }
    map<json>|error arguments = (block?.input ?: {}).cloneWithType();
    if arguments is error {
        return error ai:LlmInvalidResponseError(
                string `Invalid arguments received for the tool call '${name}'`, arguments);
    }
    return {id: block?.id, name, arguments};
}

# Records the response metadata of a Messages API call on a span.
#
# + span - The span to update
# + response - The Messages API response
isolated function addAnthropicResponseDetailsToSpan(observe:LlmSpan span, AnthropicMessagesResponse response) {
    string? id = response?.id;
    if id is string {
        span.addResponseId(id);
    }
    string? model = response?.model;
    if model is string {
        span.addResponseModel(model);
    }
    AnthropicUsage? usage = response?.usage;
    if usage is AnthropicUsage {
        int? inputTokens = usage?.input_tokens;
        if inputTokens is int {
            span.addInputTokenCount(inputTokens);
        }
        int? outputTokens = usage?.output_tokens;
        if outputTokens is int {
            span.addOutputTokenCount(outputTokens);
        }
    }
    string? stopReason = response?.stop_reason;
    if stopReason is string {
        span.addFinishReason(stopReason);
    }
}

// ===== Structured generation (the `generate` method's implementation) =====

# Generates a structured value from a Claude model through the Anthropic Messages API.
#
# The expected type's JSON schema is offered as the `getResults` tool and the model is forced to call it
# (`tool_choice: {"type": "tool", "name": "getResults"}`), so the answer arrives as validated tool input rather
# than as free text that has to be parsed out of prose.
#
# + anthropicClient - The HTTP client pointed at the resolved `/anthropic` base URL
# + apiKey - The Azure deployment API key
# + anthropicVersion - The `anthropic-version` header value
# + deploymentId - The Azure deployment name, sent as `model`
# + maxTokens - The response token limit
# + temperature - The sampling temperature, when configured
# + thinking - The thinking configuration, when configured
# + effort - The effort level, when configured
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response, or an `ai:Error`
isolated function generateAnthropicLlmResponse(http:Client anthropicClient, string apiKey,
        string anthropicVersion, string deploymentId, int maxTokens, decimal? temperature, Thinking? thinking,
        Effort? effort, ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    span.addProvider(ANTHROPIC_PROVIDER_NAME);
    if temperature is decimal {
        span.addTemperature(temperature);
    }

    AnthropicPromptBlock[] content;
    ResponseSchema responseSchema;
    do {
        content = check generateAnthropicContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    AnthropicMessage message = {role: "user", content: widenToContentBlocks(content)};
    AnthropicRequestParts parts = {
        messages: [message],
        system: (),
        usesFileSource: containsFileSource(content)
    };
    AnthropicTool[] tools = getAnthropicGetResultsTool(responseSchema.schema);
    map<json> request = buildAnthropicRequest(deploymentId, maxTokens, temperature,
            thinkingForForcedToolUse(thinking), effort, parts, tools,
            {'type: "tool", name: GET_RESULTS_TOOL}, ());
    span.addInputMessages(parts.messages.toJson());
    span.addTools(tools);

    AnthropicMessagesResponse|ai:Error response = postAnthropicMessages(anthropicClient, apiKey,
            anthropicVersion, request, parts.usesFileSource);
    if response is ai:Error {
        ai:Error err = error("LLM call failed: " + response.message(), cause = response.cause(),
                detail = response.detail());
        span.close(err);
        return err;
    }
    addAnthropicResponseDetailsToSpan(span, response);

    ai:Error? stopError = checkAnthropicStopReason(response);
    if stopError is ai:Error {
        span.close(stopError);
        return stopError;
    }

    map<json>? arguments = findGetResultsArguments(response);
    if arguments is () {
        // A truncated response is the one case with an actionable cause, and the generic "no relevant response"
        // message hides it.
        ai:Error err = response?.stop_reason == "max_tokens"
            ? error ai:LlmInvalidResponseError("The model's response was truncated before the structured result " +
                    "was complete; increase 'maxTokens'.")
            : error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    anydata|error parsed = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if parsed is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${parsed.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = parsed.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof parsed).toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}

# Extracts the input of the forced `getResults` tool call from a response.
#
# + response - The Messages API response
# + return - The tool input, or `()` when the model did not call the tool with a JSON object input
isolated function findGetResultsArguments(AnthropicMessagesResponse response) returns map<json>? {
    foreach AnthropicResponseBlock block in response.content {
        if block.'type != "tool_use" || block?.name != GET_RESULTS_TOOL {
            continue;
        }
        map<json>|error arguments = (block?.input ?: {}).cloneWithType();
        if arguments is map<json> {
            return arguments;
        }
        return ();
    }
    return ();
}
