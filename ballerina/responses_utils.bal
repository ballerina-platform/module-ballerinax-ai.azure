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
import ballerinax/azure.openai.responses as responses;

# Converts ai:ChatMessage array to Responses API input items and instructions.
#
# System messages are extracted to the `instructions` parameter.
# User, assistant, and function messages are converted to typed input items.
#
# + messages - List of chat messages or a single user message
# + tools - Tool definitions (used for ReAct prompt construction on unsupported models)
# + return - A tuple of [input items, optional instructions] or an error
isolated function convertToResponsesInput(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns [responses:OpenAI\.InputParam, string?]|ai:Error {
    if messages is ai:ChatUserMessage {
        responses:OpenAI\.InputItem item = {
            'type: "message",
            "role": ai:USER,
            "content": check getChatMessageStringContent(messages.content)
        };
        return [[item], ()];
    }

    responses:OpenAI\.InputItem[] inputItems = [];
    string[] instructionParts = [];

    foreach ai:ChatMessage message in messages {
        if message is ai:ChatSystemMessage {
            string content = check getChatMessageStringContent(message.content);
            instructionParts.push(content);
        } else if message is ai:ChatUserMessage {
            inputItems.push({
                'type: "message",
                "role": ai:USER,
                "content": check getChatMessageStringContent(message.content)
            });
        } else if message is ai:ChatAssistantMessage {
            ai:FunctionCall[]? toolCalls = message.toolCalls;
            if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
                string? content = message?.content;
                if content is string {
                    inputItems.push({
                        'type: "message", 
                        "role": ai:ASSISTANT, 
                        "content": content
                    });
                }
                foreach ai:FunctionCall tc in toolCalls {
                    inputItems.push({
                        'type: "function_call",
                        "name": tc.name,
                        "arguments": tc?.arguments.toJsonString(),
                        "call_id": tc.id ?: string `call_${tc.name}`,
                        "status": "completed"
                    });
                }
            } else {
                inputItems.push({
                    'type: "message",
                    "role": ai:ASSISTANT,
                    "content": message?.content ?: ""
                });
            }
        } else if message is ai:ChatFunctionMessage {
            inputItems.push({
                'type: "function_call_output",
                "call_id": message.id ?: string `call_${message.name}`,
                "output": message?.content ?: ""
            });
        }
    }

    string? instructions = instructionParts.length() > 0
        ? string:'join("\n\n", ...instructionParts)
        : ();
    return [inputItems, instructions];
}

# Converts ai:ChatCompletionFunctions to Responses API flat function tool format.
#
# + tools - The tool definitions to convert
# + return - Array of function tool objects in Responses API flat format
isolated function convertToResponsesTools(ai:ChatCompletionFunctions[] tools) returns responses:OpenAI\.Tool[]|error {
    responses:OpenAI\.Tool[] result = [];
    foreach ai:ChatCompletionFunctions tool in tools {
        responses:OpenAI\.Tool|error converted = {
            'type: "function",
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters ?: {},
            strict: false
        }.cloneWithType();

        if converted is responses:OpenAI\.Tool {
            result.push(converted);
        } else {
            return converted;
        } 
    }
    return result;
}

# Converts ai:BuiltInTool array to Responses API tool format.
#
# + tools - The built-in tool definitions to convert
# + return - Array of responses:OpenAI\.Tool objects or an error
isolated function convertBuiltInToolsToResponsesFormat(ai:BuiltInTool[] tools) returns responses:OpenAI\.Tool[]|ai:Error {
    responses:OpenAI\.Tool[] result = [];
    foreach ai:BuiltInTool tool in tools {
        map<anydata> toolMap = {'type: tool.name};
        map<anydata>? configs = tool.configurations;
        if configs is map<anydata> {
            foreach string key in configs.keys() {
                anydata value = configs[key];
                toolMap[key] = value;
            }
        }
        responses:OpenAI\.Tool|error converted = toolMap.cloneWithType();
        if converted is error {
            return error ai:Error("Failed to convert built-in tool '" + tool.name + "' to Responses API format. " + "Found " + toolMap.toString(), converted);
        }
        result.push(converted);
    }
    return result;
}

# Converts a Responses API response to an ai:ChatAssistantMessage.
#
# + response - The Responses API response
# + return - A ChatAssistantMessage or an error
isolated function convertResponsesOutputToAssistantMessage(responses:inline_response_200_5 response)
        returns ai:ChatAssistantMessage|ai:Error {
    ai:ChatAssistantMessage result = {role: ai:ASSISTANT};
    ai:FunctionCall[] functionCalls = [];

    // Scan output items for message and function_call items
    foreach responses:OpenAI\.OutputItem item in response.output {
        string itemType = item.'type;
        if itemType == "message" {
            // Extract text content from message output items
            anydata contentArr = item["content"];
            if contentArr is anydata[] {
                foreach anydata contentPart in contentArr {
                    if contentPart is map<anydata> {
                        string? partType = <string?>contentPart["type"];
                        if partType == "output_text" {
                            string? text = <string?>contentPart["text"];
                            if text is string && text.length() > 0 {
                                result.content = (result.content ?: "") + text;
                            }
                        }
                    }
                }
            }
        } else if itemType == "function_call" {
            string? name = <string?>item["name"];
            string? arguments = <string?>item["arguments"];
            string? callId = <string?>item["call_id"];
            if name is string && arguments is string {
                json|error parsedArgs = arguments.fromJsonString();
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
                    name: name,
                    arguments: argsMap,
                    id: callId
                });
            }
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

# Converts DocumentContentPart array from Chat Completions format to Responses API format.
#
# + parts - The content parts in Chat Completions format
# + return - The content parts in Responses API format
isolated function convertContentPartsForResponses(DocumentContentPart[] parts) returns json[] {
    json[] result = [];
    foreach DocumentContentPart part in parts {
        if part is TextContentPart {
            result.push({
                'type: "input_text",
                text: part.text
            });
        } else if part is ImageContentPart {
            result.push({
                'type: "input_image",
                image_url: part.image_url.url
            });
        }
    }
    return result;
}

# Generates a structured response from the LLM via the Responses API.
#
# + responsesClient - The chat client for the Responses API
# + deploymentId - The Azure deployment ID (used as model name)
# + apiVersion - The Azure API version
# + temperature - The sampling temperature for the response 
# + maxTokens - The maximum number of tokens to generate in the response
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response or an error
isolated function generateLlmResponseViaResponses(responses:Client responsesClient, string deploymentId,
        responses:AzureAIFoundryModelsApiVersion? apiVersion, decimal? temperature, int maxTokens, 
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc)
        returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    span.addProvider("azure.ai.openai");

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    // Build the getResults tool
    responses:OpenAI\.Tool|error getResultsTool = {
        'type: "function",
        name: GET_RESULTS_TOOL,
        parameters: responseSchema.schema,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        strict: false
    }.cloneWithType();
    if getResultsTool is error {
        ai:Error err = error("Failed to create getResults tool: " + getResultsTool.message());
        span.close(err);
        return err;
    }

    // Build tool_choice
    responses:OpenAI\.ToolChoiceParam|error toolChoice = {
        'type: "function",
        name: GET_RESULTS_TOOL
    }.cloneWithType();
    if toolChoice is error {
        ai:Error err = error("Failed to create tool choice: " + toolChoice.message());
        span.close(err);
        return err;
    }

    // Audio input is not supported in the Responses API
    foreach DocumentContentPart part in content {
        if part is AudioContentPart {
            ai:Error err = error("Audio input is not supported in the Responses API.");
            span.close(err);
            return err;
        }
    }

    // Convert content parts to Responses API format
    json[] responsesContent = convertContentPartsForResponses(content);

    // Build input
    responses:OpenAI\.InputParam inputMessage = [{
        "role": ai:USER,
        "content": responsesContent,
        'type: "message"
    }];
    
    responses:OpenAI\.CreateResponse request = {
        model: deploymentId,
        input: inputMessage,
        tools: [getResultsTool],
        tool_choice: toolChoice,
        temperature: temperature,
        max_output_tokens: maxTokens
    };

    span.addInputMessages([inputMessage].toJson());

    responses:inline_response_200_5|error response = responsesClient->/responses.post(request,
        queries = {api\-version: apiVersion});
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), detail = response.detail(), cause = response.cause());
        span.close(err);
        return err;
    }

    // Record observability
    span.addResponseId(response.id);
    responses:OpenAI\.ResponseUsage? usage = response.usage;
    if usage is responses:OpenAI\.ResponseUsage {
        span.addInputTokenCount(usage.input_tokens);
        span.addOutputTokenCount(usage.output_tokens);
    }

    // Find the function_call output item for getResults
    string? toolArguments = ();
    foreach responses:OpenAI\.OutputItem item in response.output {
        if item.'type == "function_call" {
            string? itemName = <string?>item["name"];
            if itemName == GET_RESULTS_TOOL {
                toolArguments = <string?>item["arguments"];
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
