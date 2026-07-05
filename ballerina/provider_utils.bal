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
import ballerinax/azure.openai.chat as chat;
import ballerinax/azure.openai.responses as responses;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

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

isolated function getGetResultsToolChoice() returns chat:chatCompletionNamedToolChoice => {
    'type: FUNCTION,
    'function: {
        name: GET_RESULTS_TOOL
    }
};

isolated function getGetResultsTool(map<json> parameters) returns chat:chatCompletionTool[]|ai:Error {
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

        if insertion is ai:Document {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            check addDocumentContentPart(insertion, contentParts);
        } else if insertion is ai:Document[] {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            foreach ai:Document doc in insertion {
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

isolated function addDocumentContentPart(ai:Document doc, DocumentContentPart[] contentParts) returns ai:Error? {
    if doc is ai:TextDocument {
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

// Azure introduced `max_completion_tokens` (and made reasoning models reject the legacy `max_tokens`) in
// api-version 2024-08-01-preview. api-version values are date-prefixed (YYYY-MM-DD[-preview]) and therefore
// sort lexicographically, so a prefix comparison is a reliable "is this version >= threshold" test.
const string MAX_COMPLETION_TOKENS_MIN_API_VERSION = "2024-08-01";

isolated function usesMaxCompletionTokens(string apiVersion) returns boolean {
    string datePrefix = apiVersion.length() >= 10 ? apiVersion.substring(0, 10) : apiVersion;
    return datePrefix >= MAX_COMPLETION_TOKENS_MIN_API_VERSION;
}

// Serializes a Chat Completions request to its wire form, choosing the correct fields for the target
// api-version and model.
//
// - Token limit: for api-version >= 2024-08-01-preview the value is sent as `max_completion_tokens` (required
//   by GPT-5/o-series, which reject `max_tokens`); for older versions it stays as `max_tokens` (those versions
//   don't recognize `max_completion_tokens`). The generated record always serializes a `max_tokens` key, so on
//   the newer path we relocate its value and drop the rejected key entirely.
// - Reasoning effort: the generated `createChatCompletionRequest` defaults `reasoning_effort` to "medium", so
//   `jsondata:toJson` always serializes it. Keep it only when the caller actually selected a
//   Chat-Completions-supported effort (mirroring where `request.reasoning_effort` is set); otherwise drop it so
//   non-reasoning deployments and older api-versions don't receive an unsupported/unintended `reasoning_effort`.
isolated function buildChatCompletionBody(chat:createChatCompletionRequest request, string apiVersion,
        responses:ReasoningEffort? reasoning) returns map<json>|ai:Error {
    do {
        map<json> body = check jsondata:toJson(request).ensureType();
        if usesMaxCompletionTokens(apiVersion) && body.hasKey("max_tokens") {
            body["max_completion_tokens"] = body.remove("max_tokens");
        }
        if !(reasoning is "low"|"medium"|"high") && body.hasKey("reasoning_effort") {
            _ = body.remove("reasoning_effort");
        }
        return body;
    } on fail error e {
        return error ai:Error("Failed to build the Chat Completions request body", e);
    }
}

isolated function generateLlmResponse(http:Client llmClient, string apiKey, string deploymentId,
        string apiVersion, decimal? temperature, int maxTokens, responses:ReasoningEffort? reasoning,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    decimal? temp = temperature;
    if temp is decimal {
        span.addTemperature(temp);
    }
    span.addProvider("azure.ai.openai");

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    chat:chatCompletionTool[] tools;
    chat:chatCompletionRequestUserMessageContentPart[] contentParts;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
        tools = check getGetResultsTool(responseSchema.schema);
        contentParts = check content.cloneWithType();
    } on fail error err {
        span.close(err);
        return error ai:Error(err.message(), cause = err.cause(), detail = err.detail());
    }

    chat:createChatCompletionRequest request = {
        messages: [
            <chat:chatCompletionRequestUserMessage>{
                role: ai:USER,
                content: contentParts
            }
        ],
        tools,
        temperature,
        max_tokens: maxTokens,
        tool_choice: getGetResultsToolChoice()
    };
    if reasoning is "low"|"medium"|"high" {
        request.reasoning_effort = reasoning;
    }
    span.addInputMessages(request.messages.toJson());

    map<json>|ai:Error body = buildChatCompletionBody(request, apiVersion, reasoning);
    if body is ai:Error {
        span.close(body);
        return body;
    }

    chat:createChatCompletionResponse|error response = llmClient->post(
        string `/deployments/${deploymentId}/chat/completions?api-version=${apiVersion}`,
        body, {"api-key": apiKey});
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), cause = response.cause(), detail = response.detail());
        span.close(err);
        return err;
    }

    span.addResponseId(response.id);
    chat:completionUsage? usage = response.usage;
    if usage is chat:completionUsage {
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

isolated function ensureAnydataResult(chat:createChatCompletionResponse response,
        typedesc<json> expectedResponseTypedesc, boolean isOriginallyJsonObject,
        observe:GenerateContentSpan span) returns anydata|ai:Error {

    chat:createChatCompletionResponse_choices[] choices = response.choices;
    if choices.length() == 0 {
        return error("No completion choices");
    }

    chat:chatCompletionResponseMessage message = choices[0].message;
    chat:chatCompletionMessageToolCall[]? toolCalls = message.tool_calls;
    if toolCalls is () || toolCalls.length() == 0 {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }
    span.addFinishReason(choices[0].finish_reason);

    map<json>|error arguments = toolCalls[0].'function.arguments.fromJsonStringWithType();
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
