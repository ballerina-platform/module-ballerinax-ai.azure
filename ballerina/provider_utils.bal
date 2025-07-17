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
import ballerina/constraint;
import ballerina/lang.array;
import ballerinax/azure.openai.chat;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

type TextContentPart record {|
    readonly string 'type = "text";
    string text;
|};

type ImageContentPart record {|
    readonly string 'type = "image_url";
    record {|string url;|} image_url;
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

isolated function getGetResultsToolChoice() returns chat:ChatCompletionNamedToolChoice => {
    'type: FUNCTION,
    'function: {
        name: GET_RESULTS_TOOL
    }
};

isolated function getGetResultsTool(map<json> parameters) returns chat:ChatCompletionTool[]|error =>
    [
        {
            'type: FUNCTION,
            'function: {
                name: GET_RESULTS_TOOL,
                parameters: check parameters.cloneWithType(),
                description: "Tool to call with the response from a large language model (LLM) for a user prompt."
            }
        }
    ];

isolated function generateChatCreationMultimodalContent(ai:Prompt prompt)
                        returns (TextContentPart|ImageContentPart)[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    (TextContentPart|ImageContentPart)[] contentParts = [];

    if strings.length() > 0 {
        contentParts.push({
            text: strings[0]
        });
    }

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string str = strings[i + 1];

        if insertion is ai:TextDocument {
            contentParts.push({
                text: insertion.content
            });
        } else if insertion is ai:TextDocument[] {
            foreach ai:TextDocument doc in insertion {
                contentParts.push({
                    text: doc.content
                });
            }
        } else if insertion is ai:ImageDocument {
            contentParts.push(check buildImageContentPart(insertion));
        } else if insertion is ai:ImageDocument[] {
            foreach ai:ImageDocument doc in insertion {
                contentParts.push(check buildImageContentPart(doc));
            }
        } else if insertion is ai:Document {
            return error("Only text, image, audio, and file documents are supported.");
        } else {
            contentParts.push({
                text: insertion.toString()
            });
        }

        if str.trim().length() > 0 {
            contentParts.push({
                text: str
            });
        }
    }
    return contentParts;
}

isolated function buildImageContentPart(ai:ImageDocument doc) returns ImageContentPart|ai:Error {
    ai:ImageDocument|constraint:Error validatedImageDoc = constraint:validate(doc);
    if validatedImageDoc is error {
        return error("Invalid image document: " + validatedImageDoc.message());
    }

    return {
        "image_url": {
            "url": check constructImageUrl(doc.content, doc.metadata?.mimeType)
        }
    };
}

isolated function constructImageUrl(ai:Url|byte[] content, string? mimeType) returns string|ai:Error {
    if content is ai:Url {
        return content;
    }

    return string `data:${mimeType ?: "image/*"};base64,${check getBase64EncodedString(content)}`;
}

isolated function getBase64EncodedString(byte[] content) returns string|ai:Error {
    if content.length() == 0 {
        return error("Image content is empty.");
    }
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

isolated function generateLlmResponse(chat:Client llmClient, string deploymentId,
        string apiVersion, decimal temperature, int maxTokens, ai:Prompt prompt, 
        typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    (TextContentPart|ImageContentPart)[] content = check generateChatCreationMultimodalContent(prompt);
    ResponseSchema ResponseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    chat:ChatCompletionTool[]|error tools = getGetResultsTool(ResponseSchema.schema);
    if tools is error {
        return error("Error in generated schema: " + tools.message());
    }

    chat:CreateChatCompletionRequest request = {
        messages: [
            {
                role: ai:USER,
                "content": content
            }
        ],
        tools,
        temperature,
        max_tokens: maxTokens,
        tool_choice: getGetResultsToolChoice()
    };

    chat:CreateChatCompletionResponse|error response =
        llmClient->/deployments/[deploymentId]/chat/completions.post(apiVersion, request);
    if response is error {
        return error("LLM call failed: " + response.message());
    }

    record {
        chat:ChatCompletionResponseMessage message?;
        chat:ContentFilterChoiceResults content_filter_results?;
        int index?;
        string finish_reason?;
    }[]? choices = response.choices;

    if choices is () || choices.length() == 0 {
        return error("No completion choices");
    }

    chat:ChatCompletionResponseMessage? message = choices[0].message;
    chat:ChatCompletionMessageToolCall[]? toolCalls = message?.tool_calls;
    if toolCalls is () || toolCalls.length() == 0 {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    chat:ChatCompletionMessageToolCall tool = toolCalls[0];
    map<json>|error arguments = tool.'function.arguments.fromJsonStringWithType();
    if arguments is error {
        return error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            ResponseSchema.isOriginallyJsonObject);
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
