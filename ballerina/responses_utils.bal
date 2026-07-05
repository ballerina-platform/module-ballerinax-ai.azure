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
import ballerinax/azure.openai.responses as responses;

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
                    string callId = tc.id ?: string `call_${tc.name}`;
                    ResponsesFunctionCall functionCall = {
                        id: callId,
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
                call_id: message.id ?: string `call_${message.name}`,
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
# - **Legacy** (otherwise): the raw HTTP client posts `POST {serviceUrl}/openai/responses?api-version={apiVersion}`
#   with the `api-key` header.
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
# The connector's `ApiKeysConfig` requires both `api-key` and `authorization`; Azure api-key authentication only
# needs the `api-key` header, so `authorization` is left empty.
#
# + apiKey - The Azure OpenAI API key
# + cc - The module connection configuration to map
# + return - The `azure.openai.responses` connector configuration
isolated function toResponsesConnectionConfig(string apiKey, ConnectionConfig cc) returns responses:ConnectionConfig => {
    auth: {api\-key: apiKey, authorization: ""},
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
