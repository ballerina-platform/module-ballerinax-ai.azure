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
import ballerina/data.jsondata;
import ballerina/http;
import ballerina/lang.array;
import ballerinax/azure.openai.chat;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

# A single content part of a Chat Completions message. `azure.openai.chat` only generates the text content
# part type, so the image and audio parts are defined here to match the Azure OpenAI wire format.
type DocumentContentPart TextContentPart|ImageContentPart|AudioContentPart;

type TextContentPart record {|
    readonly "text" 'type = "text";
    string text;
|};

type ImageContentPart record {|
    readonly "image_url" 'type = "image_url";
    record {|string url;|} image_url;
|};

type AudioContentPart record {|
    readonly "input_audio" 'type = "input_audio";
    record {|
        string format;
        string data;
    |} input_audio;
|};

// ===== Chat Completions request message shapes =====
// `azure.openai.chat:OpenAIChatCompletionRequestMessage` is an open record carrying only `role`, so the concrete
// per-role shapes are defined here. Each is a structural subtype of `OpenAIChatCompletionRequestMessage`.

type AzureChatUserMessage record {|
    "user" role = "user";
    string|DocumentContentPart[] content;
    string name?;
|};

type AzureChatSystemMessage record {|
    "system" role = "system";
    string content;
    string name?;
|};

type AzureChatAssistantMessage record {|
    "assistant" role = "assistant";
    string content?;
    AzureChatToolCall[] tool_calls?;
|};

type AzureChatToolMessage record {|
    "tool" role = "tool";
    string content;
    string tool_call_id;
|};

type AzureChatToolCall record {|
    string id;
    "function" 'type = "function";
    record {|string name; string arguments;|} 'function;
|};

# Extracts the (non-streaming) completion choices from a Chat Completions response.
#
# `chat:InlineResponse200` is a union of the non-streaming completion response and the streaming chunk response;
# this module never streams, so the choices are narrowed to the completion variant.
#
# + response - The Chat Completions response returned by the connector / raw client
# + return - The completion choices, or an `ai:Error` if a streaming response was received
isolated function getCompletionChoices(chat:InlineResponse200 response)
        returns chat:OpenAICreateChatCompletionResponseChoices[]|ai:Error {
    var choices = response.choices;
    if choices is chat:OpenAICreateChatCompletionResponseChoices[] {
        return choices;
    }
    return error ai:LlmInvalidResponseError("Streaming Chat Completions responses are not supported");
}

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the " +
    "LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RESULT = "result";
const GET_RESULTS_TOOL = "getResults";
const FUNCTION = "function";
const NO_RELEVANT_RESPONSE_FROM_THE_LLM = "No relevant response from the LLM";

isolated function generateJsonObjectSchema(map<json> schema) returns ResponseSchema {
    string[] supportedMetaDataFields = ["$schema", "$id", "$anchor", "$comment", "title", "description"];

    if schema["type"] == "object" {
        return {schema};
    }

    map<json> updatedSchema = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) is int
        select [key, value];

    updatedSchema["type"] = "object";
    map<json> content = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) !is int
        select [key, value];

    updatedSchema["properties"] = {[RESULT]: content};

    return {schema: updatedSchema, isOriginallyJsonObject: false};
}

isolated function parseResponseAsType(string resp,
        typedesc<anydata> expectedResponseTypedesc, boolean isOriginallyJsonObject) returns anydata|error {
    if !isOriginallyJsonObject {
        map<json> respContent = check resp.fromJsonStringWithType();
        anydata|error result = trap respContent[RESULT].fromJsonWithType(expectedResponseTypedesc);
        if result is error {
            return handleParseResponseError(result);
        }
        return result;
    }

    anydata|error result = resp.fromJsonStringWithType(expectedResponseTypedesc);
    if result is error {
        return handleParseResponseError(result);
    }
    return result;
}

isolated function getExpectedResponseSchema(typedesc<anydata> expectedResponseTypedesc) returns ResponseSchema|ai:Error {
    // Restricted at compile-time for now.
    typedesc<json> td = checkpanic expectedResponseTypedesc.ensureType();
    return generateJsonObjectSchema(check generateJsonSchemaForTypedescAsJson(td));
}

isolated function getGetResultsToolChoice() returns chat:OpenAIChatCompletionNamedToolChoice => {
    'type: FUNCTION,
    'function: {
        name: GET_RESULTS_TOOL
    }
};

isolated function getGetResultsTool(map<json> parameters) returns chat:OpenAIChatCompletionTool[]|ai:Error {
    map<json>|error toolParam = parameters.ensureType();
    if toolParam is error {
        return error("Error in generated schema: " + toolParam.message());
    }
    return [
        {
            'type: FUNCTION,
            'function: {
                name: GET_RESULTS_TOOL,
                parameters: toolParam,
                description: "Tool to call with the response from a large language model (LLM) for a user prompt."
            }
        }
    ];
}

isolated function generateChatCreationContent(ai:Prompt prompt) returns DocumentContentPart[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    DocumentContentPart[] contentParts = [];
    string accumulatedTextContent = "";

    if strings.length() > 0 {
        accumulatedTextContent += strings[0];
    }

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string str = strings[i + 1];

        if insertion is ai:Document|ai:Chunk {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            check addDocumentContentPart(insertion, contentParts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            foreach ai:Document|ai:Chunk doc in insertion {
                check addDocumentContentPart(doc, contentParts);
            }
        } else {
            accumulatedTextContent += insertion.toString();
        }
        accumulatedTextContent += str;
    }

    addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
    return contentParts;
}

isolated function addDocumentContentPart(ai:Document|ai:Chunk doc, DocumentContentPart[] contentParts) returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        return addTextContentPart(buildTextContentPart(doc.content), contentParts);
    } else if doc is ai:ImageDocument {
        return contentParts.push(check buildImageContentPart(doc));
    } else if doc is ai:AudioDocument {
        return contentParts.push(check buildAudioContentPart(doc));
    }
    return error ai:Error("Only text, image and audio documents are supported.");
}

isolated function addTextContentPart(TextContentPart? contentPart, DocumentContentPart[] contentParts) {
    if contentPart is TextContentPart {
        return contentParts.push(contentPart);
    }
}

isolated function buildTextContentPart(string content) returns TextContentPart? {
    if content.length() == 0 {
        return;
    }

    return {
        'type: "text",
        text: content
    };
}

isolated function buildImageContentPart(ai:ImageDocument doc) returns ImageContentPart|ai:Error =>
    {
    image_url: {
        url: check buildImageUrl(doc.content, doc.metadata?.mimeType)
    }
};

isolated function buildAudioContentPart(ai:AudioDocument doc) returns AudioContentPart|ai:Error {
    "mp3"|"wav"|error format = doc?.metadata["format"].ensureType();
    if format is error {
        return error(
            "Please specify the audio format in the 'format' field of the metadata; supported values are 'mp3' and 'wav'"
        );
    }

    ai:Url|byte[] content = doc.content;
    if content is ai:Url {
        return error("URL-based audio content is not supported at the moment.");
    }

    return {input_audio: {format, data: check getBase64EncodedString(content)}};
}

isolated function buildImageUrl(ai:Url|byte[] content, string? mimeType) returns string|ai:Error {
    if content is ai:Url {
        ai:Url|constraint:Error validationRes = constraint:validate(content);
        if validationRes is error {
            return error(validationRes.message(), validationRes.cause());
        }
        return content;
    }

    return string `data:${mimeType ?: "image/*"};base64,${check getBase64EncodedString(content)}`;
}

isolated function getBase64EncodedString(byte[] content) returns string|ai:Error {
    string|error binaryContent = array:toBase64(content);
    if binaryContent is error {
        return error("Failed to convert byte array to string: " + binaryContent.message() + ", " +
                        binaryContent.detail().toBalString());
    }
    return binaryContent;
}

isolated function handleParseResponseError(error chatResponseError) returns error {
    string message = chatResponseError.message();
    if message.includes(JSON_CONVERSION_ERROR) || message.includes(CONVERSION_ERROR) {
        return error(ERROR_MESSAGE, chatResponseError);
    }
    return chatResponseError;
}

// Azure added `max_completion_tokens` to the Chat Completions request schema (and made the o-series reject the
// legacy `max_tokens`) in api-version 2024-09-01-preview, alongside o1-preview/o1-mini support. It is absent from
// the 2024-08-01-preview Chat Completions schema, which only carries it on the Assistants run schemas.
// api-version values are date-prefixed (YYYY-MM-DD[-preview]) and therefore sort lexicographically, so a prefix
// comparison is a reliable "is this version >= threshold" test.
const string MAX_COMPLETION_TOKENS_MIN_API_VERSION = "2024-09-01";

# Decides whether a legacy (date-based) api-version accepts `max_completion_tokens`.
#
# + apiVersion - The date-based api-version (e.g. `2024-09-01-preview`)
# + return - `true` for api-versions `>= 2024-09-01`; `false` otherwise
isolated function usesMaxCompletionTokens(string apiVersion) returns boolean =>
    apiVersionAtLeast(apiVersion, MAX_COMPLETION_TOKENS_MIN_API_VERSION);

// Azure added `stream_options` (and with it `stream_options.include_usage`, the only way to get token usage on a
// streamed response) to the Chat Completions request schema in api-version 2024-08-01-preview. Older versions
// reject the whole request with "Unrecognized request argument supplied: stream_options", so on those the field
// must be omitted and the stream simply carries no usage chunk.
const string STREAM_OPTIONS_MIN_API_VERSION = "2024-08-01";

# Decides whether a legacy (date-based) api-version accepts `stream_options`.
#
# + apiVersion - The date-based api-version (e.g. `2024-08-01-preview`)
# + return - `true` for api-versions `>= 2024-08-01`; `false` otherwise
isolated function supportsStreamOptions(string apiVersion) returns boolean =>
    apiVersionAtLeast(apiVersion, STREAM_OPTIONS_MIN_API_VERSION);

# Compares a date-based api-version against a `YYYY-MM-DD` threshold. api-version values are date-prefixed
# (`YYYY-MM-DD[-preview]`) and therefore sort lexicographically, so a prefix comparison is a reliable
# "is this version >= threshold" test. A value too short to carry a date prefix is compared as-is, which puts
# any malformed/degenerate input below every threshold.
#
# + apiVersion - The date-based api-version to test
# + minApiVersion - The `YYYY-MM-DD` threshold
# + return - `true` when `apiVersion` is at or after the threshold
isolated function apiVersionAtLeast(string apiVersion, string minApiVersion) returns boolean {
    string datePrefix = apiVersion.length() >= 10 ? apiVersion.substring(0, 10) : apiVersion;
    return datePrefix >= minApiVersion;
}

# Sets the correct token-limit field on a Chat Completions request.
#
# GPT-5/o-series reasoning models reject the deprecated `max_tokens` and require `max_completion_tokens`. The v1
# GA surface always accepts `max_completion_tokens`; on the legacy surface it is accepted only from api-version
# `2024-09-01-preview` onward, so older versions fall back to `max_tokens`.
#
# + request - The Chat Completions request to mutate
# + maxTokens - The token limit value
# + useMaxCompletionTokens - `true` to send `max_completion_tokens`; `false` to send `max_tokens`
isolated function applyMaxTokens(chat:ChatCompletionsBody request, int maxTokens, boolean useMaxCompletionTokens) {
    if useMaxCompletionTokens {
        request.max_completion_tokens = maxTokens;
    } else {
        request.max_tokens = maxTokens;
    }
}

# Serializes a Chat Completions request for the legacy deployment-scoped route.
#
# The deployment is carried in the URL path on the legacy route, so a body-level `model` is dropped (both to
# avoid redundancy and to preserve the request shape used by earlier releases of this module).
#
# + request - The Chat Completions request (with the token-limit field already selected)
# + return - The wire body, or an `ai:Error` on serialization failure
isolated function buildLegacyChatBody(chat:ChatCompletionsBody request) returns map<json>|ai:Error {
    do {
        map<json> body = check jsondata:toJson(request).ensureType();
        if body.hasKey("model") {
            _ = body.remove("model");
        }
        return body;
    } on fail error e {
        return error ai:Error("Failed to build the Chat Completions request body", e);
    }
}

# Posts a prepared Chat Completions request to the configured surface.
#
# - **v1 GA** (`useV1` is `true`): the generated `chat:Client` posts `{serviceUrl}/chat/completions`. `api-version`
#   is only sent when the caller opted into `preview`/`v1` (`v1ApiVersion`).
# - **Legacy** (otherwise): the raw HTTP client posts
#   `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version={apiVersion}` with the `api-key`
#   header, where `legacyBase` is the resolved legacy base URL (see `resolveLegacyBase`).
#
# + chatClient - The generated Chat Completions connector for the v1 GA surface (`()` on the legacy path)
# + legacyChatClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key (sent as `api-key` on the legacy route)
# + deploymentId - The Azure deployment ID
# + apiVersion - The date-based `api-version` query value used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version to forward on the v1 route, if any
# + request - The prepared Chat Completions request
# + return - The parsed Chat Completions response, or an `error` on failure
isolated function postChatCompletion(chat:Client? chatClient, http:Client? legacyChatClient, boolean useV1,
        string apiKey, string deploymentId, string? apiVersion, string? v1ApiVersion,
        chat:ChatCompletionsBody request) returns chat:InlineResponse200|error {
    if useV1 {
        chat:Client? llmClient = chatClient;
        if llmClient is () {
            return error("Chat Completions (v1) client is not initialized");
        }
        if v1ApiVersion is string {
            return llmClient->/chat/completions.post(request,
                    api\-version = <chat:AzureAIFoundryModelsApiVersion>v1ApiVersion);
        }
        return llmClient->/chat/completions.post(request);
    }

    http:Client? llmClient = legacyChatClient;
    if llmClient is () {
        return error("Chat Completions (legacy) client is not initialized");
    }
    map<json> body = check buildLegacyChatBody(request);
    chat:InlineResponse200 result = check llmClient->post(
            string `/deployments/${deploymentId}/chat/completions?api-version=${apiVersion ?: ""}`,
            body, {"api-key": apiKey});
    return result;
}

# Serializes a Chat Completions request for the v1 GA route.
#
# Unlike the legacy route, the v1 GA surface carries the deployment as `model` in the body (there is no
# deployment path segment in the URL), so `model` is kept.
#
# + request - The Chat Completions request (with the token-limit field already selected)
# + return - The wire body, or an `ai:Error` on serialization failure
isolated function buildV1ChatBody(chat:ChatCompletionsBody request) returns map<json>|ai:Error {
    do {
        return check jsondata:toJson(request).ensureType();
    } on fail error e {
        return error ai:Error("Failed to build the Chat Completions request body", e);
    }
}

# Opens a streaming (`stream: true`) Chat Completions request against the configured surface and returns the raw
# Server-Sent Event stream.
#
# The generated `chat:Client` (used for the non-streaming v1 GA path) binds its response to a single value and
# cannot consume Server-Sent Events, so both surfaces stream through a raw HTTP client:
#
# - **v1 GA** (`useV1` is `true`): `v1StreamClient` posts `{serviceUrl}/chat/completions` (`model` kept in the
#   body). `api-version` is only sent when the caller opted into `preview`/`v1` (`v1ApiVersion`).
# - **Legacy** (otherwise): `legacyChatClient` (already a raw client) posts
#   `{legacyBase}/deployments/{deploymentId}/chat/completions?api-version={apiVersion}`, `model` dropped from the
#   body.
#
# Both routes send the `api-key` header and set `stream: true` on the request before serializing it.
# `stream_options.include_usage` is added only where the target surface accepts it: always on v1 GA, and on the
# legacy surface only from api-version `2024-08-01-preview` onward. Older legacy api-versions reject the whole
# request with "Unrecognized request argument supplied: stream_options", so there the stream is opened without
# it and simply carries no usage chunk.
#
# + v1StreamClient - The raw HTTP client for the v1 GA surface (`()` on the legacy path)
# + legacyChatClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key (sent as the `api-key` header on both routes)
# + deploymentId - The Azure deployment ID
# + apiVersion - The date-based `api-version` used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version to forward on the v1 route, if any
# + request - The prepared Chat Completions request
# + return - The opened Server-Sent Event stream, or an `ai:Error` on failure
isolated function postChatCompletionStream(http:Client? v1StreamClient, http:Client? legacyChatClient,
        boolean useV1, string apiKey, string deploymentId, string? apiVersion, string? v1ApiVersion,
        chat:ChatCompletionsBody request) returns stream<http:SseEvent, error?>|ai:Error {
    request.'stream = true;
    if useV1 || supportsStreamOptions(apiVersion ?: "") {
        request.stream_options = {include_usage: true};
    }

    http:Response|error response;
    if useV1 {
        http:Client? streamClient = v1StreamClient;
        if streamClient is () {
            return error ai:Error("Chat Completions (v1) streaming client is not initialized");
        }
        map<json> body = check buildV1ChatBody(request);
        string path = "/chat/completions";
        if v1ApiVersion is string {
            path += "?api-version=" + v1ApiVersion;
        }
        response = streamClient->post(path, body, {"api-key": apiKey});
    } else {
        http:Client? streamClient = legacyChatClient;
        if streamClient is () {
            return error ai:Error("Chat Completions (legacy) streaming client is not initialized");
        }
        map<json> body = check buildLegacyChatBody(request);
        string path = string `/deployments/${deploymentId}/chat/completions?api-version=${apiVersion ?: ""}`;
        response = streamClient->post(path, body, {"api-key": apiKey});
    }
    if response is error {
        return error ai:LlmConnectionError("Error while connecting to the model for streaming", response);
    }
    // A non-2xx status still binds to `http:Response` rather than erroring (the target type here is the raw
    // response, not a typed payload), so it must be checked explicitly before treating the body as an SSE
    // stream; otherwise `getSseEventStream()` fails on Azure's JSON error body with an opaque parse error that
    // hides what Azure actually rejected.
    if response.statusCode != http:STATUS_OK {
        return error ai:Error(buildStreamingRejectionMessage(deploymentId, response));
    }
    stream<http:SseEvent, error?>|error sseStream = response.getSseEventStream();
    if sseStream is error {
        return error ai:Error("Failed to open the SSE stream from the model", sseStream);
    }
    return sseStream;
}

# Builds a clear error message for a streaming Chat Completions request that Azure rejected (non-2xx response).
#
# Surfaces Azure's own error message rather than guessing the cause up front, and appends a hint pointing at the
# Responses API when the rejection looks like the known case where a deployment refuses to stream over Chat
# Completions while the Responses API surface streams it successfully (GPT-5-series reasoning deployments).
#
# The hint triggers on Azure's own message mentioning streaming, rather than on the deployment id alone:
# deployment names are caller-chosen, so `gpt-5` is present in neither every affected deployment (`prod-reasoning`)
# nor only affected ones. The deployment-id check is kept as a secondary trigger for the case where Azure returns
# a rejection whose text does not name the streaming parameter.
#
# + deploymentId - The Azure deployment id that was streamed against
# + response - The non-2xx HTTP response returned by the streaming request
# + return - The composed error message
isolated function buildStreamingRejectionMessage(string deploymentId, http:Response response) returns string {
    string azureMessage = extractAzureErrorMessage(response);
    string message = string `Azure OpenAI rejected the streaming request for deployment '${deploymentId}' ` +
        string `(HTTP ${response.statusCode}): ${azureMessage}`;
    if azureMessage.toLowerAscii().includes("stream") || deploymentId.toLowerAscii().includes("gpt-5") {
        message += ". This deployment may not support streaming via the Chat Completions API — set " +
            "apiType = RESPONSES to stream from it instead.";
    }
    return message;
}

# Extracts a human-readable error message from a non-2xx Azure OpenAI response: the standard
# `{"error": {"message": ...}}` shape first, then the raw text body, then the bare status code.
#
# The body is read exactly once, as text, and parsed from that string. Reading it as JSON first and falling back
# to `getTextPayload` does not work: the first accessor consumes the entity's data source, so once a non-JSON
# body has failed to parse the text fallback errors too and Azure's actual message is lost.
#
# + response - The non-2xx HTTP response to extract the message from
# + return - The best-effort error message
isolated function extractAzureErrorMessage(http:Response response) returns string {
    string|error text = response.getTextPayload();
    if text is error {
        return string `HTTP ${response.statusCode}`;
    }
    string body = text.trim();
    if body.length() == 0 {
        return string `HTTP ${response.statusCode}`;
    }
    json|error payload = body.fromJsonString();
    if payload is json {
        json|error message = payload.'error.message;
        if message is string {
            return message;
        }
    }
    return body;
}

# Generates a structured value from the LLM via the Chat Completions API (the `generate` method's chat path).
#
# + chatClient - The generated Chat Completions connector for the v1 GA surface (`()` on the legacy path)
# + legacyChatClient - The raw HTTP client for the legacy route (`()` on the v1 path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key
# + deploymentId - The Azure deployment ID (also sent as the `model` on the v1 route)
# + apiVersion - The date-based `api-version` used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version forwarded on the v1 route, if any
# + temperature - The sampling temperature, if any
# + maxTokens - The maximum number of tokens to generate
# + reasoning - The reasoning effort, if any
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response, or an `ai:Error`
isolated function generateLlmResponse(chat:Client? chatClient, http:Client? legacyChatClient, boolean useV1,
        string apiKey, string deploymentId, string? apiVersion, string? v1ApiVersion, decimal? temperature,
        int maxTokens, ReasoningEffort? reasoning, ai:Prompt prompt, typedesc<json> expectedResponseTypedesc)
        returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    if temperature is decimal {
        span.addTemperature(temperature);
    }
    span.addProvider("azure.ai.openai");

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    chat:OpenAIChatCompletionTool[] tools;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
        tools = check getGetResultsTool(responseSchema.schema);
    } on fail error err {
        span.close(err);
        return error ai:Error(err.message(), cause = err.cause(), detail = err.detail());
    }

    AzureChatUserMessage userMessage = {role: "user", content};
    chat:OpenAIChatCompletionRequestMessage[] messages = [userMessage];
    chat:ChatCompletionsBody request = {
        model: deploymentId,
        messages,
        tools,
        tool_choice: getGetResultsToolChoice()
    };
    if temperature is decimal {
        request.temperature = temperature;
    }
    if reasoning is ReasoningEffort {
        request.reasoning_effort = reasoning;
    }
    applyMaxTokens(request, maxTokens, useV1 || usesMaxCompletionTokens(apiVersion ?: ""));
    span.addInputMessages(messages.toJson());

    chat:InlineResponse200|error response = postChatCompletion(chatClient, legacyChatClient, useV1, apiKey,
            deploymentId, apiVersion, v1ApiVersion, request);
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), cause = response.cause(), detail = response.detail());
        span.close(err);
        return err;
    }

    span.addResponseId(response.id);
    chat:OpenAICompletionUsage? usage = response.usage;
    if usage is chat:OpenAICompletionUsage {
        span.addInputTokenCount(usage.prompt_tokens);
        span.addOutputTokenCount(usage.completion_tokens);
    }

    anydata|ai:Error result = ensureAnydataResult(response, expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject, span);
    if result is ai:Error {
        span.close(result);
        return result;
    }
    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}

isolated function ensureAnydataResult(chat:InlineResponse200 response,
        typedesc<json> expectedResponseTypedesc, boolean isOriginallyJsonObject,
        observe:GenerateContentSpan span) returns anydata|ai:Error {

    chat:OpenAICreateChatCompletionResponseChoices[] choices = check getCompletionChoices(response);
    if choices.length() == 0 {
        return error("No completion choices");
    }

    chat:OpenAICreateChatCompletionResponseChoices firstChoice = choices[0];
    span.addFinishReason(firstChoice.finish_reason);

    chat:OpenAIChatCompletionResponseMessage message = firstChoice.message;
    chat:OpenAIChatCompletionMessageToolCallsItem? toolCalls = message.tool_calls;
    if toolCalls is () || toolCalls.length() == 0 {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    chat:OpenAIChatCompletionMessageToolCall|chat:OpenAIChatCompletionMessageCustomToolCall firstToolCall = toolCalls[0];
    if firstToolCall !is chat:OpenAIChatCompletionMessageToolCall {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    map<json>|error arguments = firstToolCall.'function.arguments.fromJsonStringWithType();
    if arguments is error {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc, isOriginallyJsonObject);
    if res is error {
        return error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);

    if result is error {
        return error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof response).toBalString()}'`);
    }
    return result;
}

// ===== Connector / raw HTTP client configuration mappers =====

# Maps the module's `ConnectionConfig` to the `azure.openai.chat` connector configuration, injecting api-key auth.
#
# Azure api-key authentication is carried solely by the `api-key` header. No `authorization` value is supplied:
# sending an empty `Authorization` header makes API Management/WAF front ends reject the request with a 401.
#
# + apiKey - The Azure OpenAI API key
# + cc - The module connection configuration to map
# + return - The `azure.openai.chat` connector configuration
isolated function toChatConnectionConfig(string apiKey, ConnectionConfig cc) returns chat:ConnectionConfig => {
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

# Maps the module's `ConnectionConfig` to a raw `http:ClientConfiguration` used for the legacy routes.
#
# `laxDataBinding` mirrors the generated connectors so real Azure responses bind identically on the legacy path.
#
# + cc - The module connection configuration to map
# + return - The raw HTTP client configuration
isolated function toRawHttpConfig(ConnectionConfig cc) returns http:ClientConfiguration => {
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
    validation: cc.validation,
    laxDataBinding: true
};
