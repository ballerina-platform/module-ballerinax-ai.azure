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

# Converts ai:ChatMessage array to Responses API input items and instructions.
#
# System messages are extracted to the `instructions` parameter.
# User, assistant, and function messages are converted to typed input items.
#
# + messages - List of chat messages or a single user message
# + return - A tuple of [input items, optional instructions] or an error
isolated function convertToResponsesInput(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns [responses:InputItem[], string?]|ai:Error {
    if messages is ai:ChatUserMessage {
        responses:EasyInputMessage item = {
            'type: "message",
            role: "user",
            content: check getChatMessageStringContent(messages.content)
        };
        return [[item], ()];
    }

    responses:InputItem[] inputItems = [];
    string[] instructionParts = [];

    foreach ai:ChatMessage message in messages {
        if message is ai:ChatSystemMessage {
            instructionParts.push(check getChatMessageStringContent(message.content));
        } else if message is ai:ChatUserMessage {
            responses:EasyInputMessage item = {
                'type: "message",
                role: "user",
                content: check getChatMessageStringContent(message.content)
            };
            inputItems.push(item);
        } else if message is ai:ChatAssistantMessage {
            ai:FunctionCall[]? toolCalls = message.toolCalls;
            if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
                string? content = message?.content;
                if content is string {
                    responses:EasyInputMessage item = {
                        'type: "message",
                        role: "assistant",
                        content: content
                    };
                    inputItems.push(item);
                }
                foreach ai:FunctionCall tc in toolCalls {
                    string callId = tc.id ?: string `call_${tc.name}`;
                    responses:FunctionToolCall functionCall = {
                        id: callId,
                        'type: "function_call",
                        call_id: callId,
                        name: tc.name,
                        arguments: (tc?.arguments ?: {}).toJsonString(),
                        status: "completed"
                    };
                    inputItems.push(functionCall);
                }
            } else {
                responses:EasyInputMessage item = {
                    'type: "message",
                    role: "assistant",
                    content: message?.content ?: ""
                };
                inputItems.push(item);
            }
        } else if message is ai:ChatFunctionMessage {
            responses:FunctionToolCallOutput output = {
                'type: "function_call_output",
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

# Converts ai:ChatCompletionFunctions to Responses API function tool definitions.
#
# + tools - The tool definitions to convert
# + return - Array of function tool objects in Responses API format
isolated function convertToResponsesTools(ai:ChatCompletionFunctions[] tools) returns responses:Tool[]|error {
    responses:Tool[] result = [];
    foreach ai:ChatCompletionFunctions tool in tools {
        responses:FunctionTool functionTool = {
            'type: "function",
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters ?: {},
            strict: false
        };
        result.push(functionTool);
    }
    return result;
}

# Converts a Responses API response to an ai:ChatAssistantMessage.
#
# + response - The Responses API response
# + return - A ChatAssistantMessage or an error
isolated function convertResponsesOutputToAssistantMessage(responses:response response)
        returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatAssistantMessage result = {role: ai:ASSISTANT};
    ai:FunctionCall[] functionCalls = [];

    foreach responses:OutputItem item in response.output {
        if item is responses:OutputMessage {
            foreach responses:OutputContent contentPart in item.content {
                if contentPart is responses:OutputText {
                    string text = contentPart.text;
                    if text.length() > 0 {
                        result.content = (result.content ?: "") + text;
                    }
                }
            }
        } else if item is responses:FunctionToolCall {
            json|error parsedArgs = item.arguments.fromJsonString();
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
                name: item.name,
                arguments: argsMap,
                id: item.call_id
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

# Converts a DocumentContentPart array into Responses API input content parts.
#
# + parts - The content parts in Chat Completions format
# + return - The content parts in Responses API format
isolated function convertContentPartsForResponses(DocumentContentPart[] parts) returns responses:InputContent[] {
    responses:InputContent[] result = [];
    foreach DocumentContentPart part in parts {
        if part is TextContentPart {
            responses:InputText text = {
                'type: "input_text",
                text: part.text
            };
            result.push(text);
        } else if part is ImageContentPart {
            responses:InputImage image = {
                'type: "input_image",
                image_url: part.image_url.url
            };
            result.push(image);
        }
    }
    return result;
}

# Generates a structured response from the LLM via the Responses API.
#
# + responsesClient - The generated Responses connector used for the v1 GA surface (`()` on the legacy path)
# + legacyResponsesClient - The raw HTTP client used for the legacy preview route (`()` on the v1 path)
# + useV1Responses - `true` to target the v1 GA surface; `false` for the legacy preview route
# + apiKey - The Azure OpenAI API key, sent as the `api-key` header on the legacy route
# + apiVersion - The `api-version` query parameter value used on the legacy route
# + deploymentId - The Azure deployment ID (used as model name)
# + temperature - The sampling temperature for the response
# + maxTokens - The maximum number of tokens to generate in the response
# + reasoning - Reasoning effort level for reasoning models, if any
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response or an error
isolated function generateLlmResponseViaResponses(responses:Client? responsesClient,
        http:Client? legacyResponsesClient, boolean useV1Responses, string apiKey, string apiVersion,
        string deploymentId, decimal? temperature, int maxTokens, responses:ReasoningEffort? reasoning,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc)
        returns anydata|ai:Error {
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

    // Audio input is not supported in the Responses API.
    foreach DocumentContentPart part in content {
        if part is AudioContentPart {
            ai:Error err = error("Audio input is not supported in the Responses API.");
            span.close(err);
            return err;
        }
    }

    responses:FunctionTool getResultsTool = {
        'type: "function",
        name: GET_RESULTS_TOOL,
        parameters: responseSchema.schema,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        strict: false
    };
    responses:ToolChoiceFunction toolChoice = {
        'type: "function",
        name: GET_RESULTS_TOOL
    };

    responses:EasyInputMessage inputMessage = {
        'type: "message",
        role: "user",
        content: convertContentPartsForResponses(content)
    };

    responses:createResponse request = {
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
    if reasoning != () {
        request.reasoning = {effort: reasoning};
    }
    span.addInputMessages([inputMessage].toJson());

    responses:response|error response = postResponsesRequest(responsesClient, legacyResponsesClient,
            useV1Responses, apiKey, apiVersion, request);
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), detail = response.detail(), cause = response.cause());
        span.close(err);
        return err;
    }

    span.addResponseId(response.id);
    responses:ResponseUsage? usage = response.usage;
    if usage is responses:ResponseUsage {
        span.addInputTokenCount(usage.input_tokens);
        span.addOutputTokenCount(usage.output_tokens);
    }

    string? toolArguments = ();
    foreach responses:OutputItem item in response.output {
        if item is responses:FunctionToolCall && item.name == GET_RESULTS_TOOL {
            toolArguments = item.arguments;
            break;
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
