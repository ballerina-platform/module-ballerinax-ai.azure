// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
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

import ballerina/http;
import ballerina/test;
import ballerinax/azure.openai.embeddings;

service /llm on new http:Listener(8080) {
    // Chat Completions API mock endpoint
    resource function post azureopenai/v1/chat/completions(
            string? api\-version, @http:Payload json payload)
                returns json|error {
        test:assertEquals(api\-version, ());
        json[] messages = check (check payload.messages).ensureType();
        json message = messages[0];

        json contentJson = check message.content;

        // Handle string content (used in chat() → Chat Completions fallback path)
        if contentJson is string {
            return getChatCompletionsFallbackToolCallResponse(contentJson);
        }

        json[]? content = check contentJson.ensureType();
        if content is () {
            test:assertFail("Expected content in the payload");
        }

        TextContentPart initialTextContent = check content[0].fromJsonWithType();
        string initialText = initialTextContent.text.toString();
        test:assertEquals(content, getExpectedContentParts(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        test:assertEquals(check message.role, "user");
        json[] tools = check (check payload.tools).ensureType();
        if tools.length() == 0 {
            test:assertFail("No tools in the payload");
        }

        json toolFn = check tools[0].'function;
        map<json>? parameters = check (check toolFn.parameters).cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected tool");
        }

        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        return getTestServiceResponse(initialText);
    }

    // Responses API mock endpoint (v1 / GA surface — used by `OpenAiModelProviderV2`)
    resource function post azureopenai/v1/responses(string api\-version, @http:Payload json payload)
            returns json|http:NotFound|error {
        return handleResponsesApiRequest(payload);
    }

    // Responses API mock endpoint (legacy deployment-scoped surface — used by `OpenAiModelProvider`)
    resource function post azureopenai/openai/responses(string api\-version, @http:Payload json payload)
            returns json|http:NotFound|error {
        return handleResponsesApiRequest(payload);
    }

    // Chat Completions mock endpoint (legacy deployment-scoped surface — used by `OpenAiModelProvider`)
    resource function post azureopenai/openai/deployments/[string deploymentId]/chat/completions(
            string api\-version, @http:Payload json payload) returns json|error {
        json|error functionsJson = payload.functions;
        if functionsJson is json[] && functionsJson.length() > 0 {
            json firstFn = functionsJson[0];
            string? fnName = check firstFn.name.ensureType();
            if fnName == GET_RESULTS_TOOL {
                // generate() path: validate the schema and return the structured result as a function_call.
                map<json>? parameters = check (check firstFn.parameters).cloneWithType();
                if parameters is () {
                    test:assertFail("No parameters in the expected getResults tool");
                }
                json[] messages = check (check payload.messages).ensureType();
                json[] contentParts = check (check messages[0].content).ensureType();
                string initialText = check contentParts[0].text.ensureType();
                test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                        string `Legacy Chat Completions: schema mismatch for prompt, ${initialText}`);
                return getLegacyChatCompletionFunctionCallResponse(GET_RESULTS_TOOL, getTheMockLLMResult(initialText));
            }
        }
        // chat() fallback path: return a get_weather tool call.
        return getLegacyChatCompletionFunctionCallResponse("get_weather", "{\"city\": \"Paris\"}");
    }

    resource function post deployments/[string deploymentId]/embeddings(string api\-version, embeddings:Deploymentid_embeddings_body payload)
        returns embeddings:Inline_response_200|error {
        embeddings:Inline_response_200_data[] data = from int i in 0 ..< 2
            select {
                embedding: from int j in 0 ..< 1536
                    select 0.1 + j * 0.1,
                index: i,
                'object: "list"
            };
        return {
            data: payload.input is embeddings:InputItemsString[] ? data : [data[0]],
            model: "text-embedding-3-small",
            usage: {
                prompt_tokens: 15,
                total_tokens: 15
            },
            'object: "list"
        };
    }
}

// Shared handler for the Azure OpenAI Responses API mock (used by both the v1 and the legacy endpoints).
function handleResponsesApiRequest(json payload) returns json|http:NotFound|error {
    json[] inputItems = check (check payload.input).ensureType();
    if inputItems.length() == 0 {
        test:assertFail("Expected input items in the payload");
    }

    // Find the first user message's content to determine the test case.
    string initialText = "";
    json firstItem = inputItems[0];
    string? role = check firstItem.role.ensureType();
    if role == "user" {
        json itemContent = check firstItem.content;
        if itemContent is string {
            initialText = itemContent;
        } else {
            json[] contentParts = check itemContent.ensureType();
            if contentParts.length() > 0 {
                json firstPart = contentParts[0];
                string? partType = check firstPart.'type.ensureType();
                if partType == "input_text" {
                    initialText = check firstPart.text.ensureType();
                }
            }
        }
    }

    // Simulate a model_not_found error for fallback tests.
    if initialText.startsWith("Fallback test") {
        return <http:NotFound>{
            body: {
                "error": {
                    "code": "model_not_found",
                    "message": "The model gpt4onew does not support the Responses API"
                }
            }
        };
    }

    // Classify the provided tools.
    json|error toolsJson = payload.tools;
    boolean hasGetResultsTool = false;
    boolean hasBuiltInTool = false;
    boolean hasFunctionTool = false;
    if toolsJson is json[] && toolsJson.length() > 0 {
        foreach json tool in toolsJson {
            string? toolType = check tool.'type.ensureType();
            if toolType == "web_search_preview" || toolType == "code_interpreter" {
                hasBuiltInTool = true;
            } else if toolType == "function" {
                hasFunctionTool = true;
                string? toolName = check tool.name.ensureType();
                if toolName == GET_RESULTS_TOOL {
                    hasGetResultsTool = true;
                }
            }
        }
    }

    if hasGetResultsTool {
        json[] toolsArr = check toolsJson.ensureType();
        json firstTool = toolsArr[0];
        map<json>? parameters = check (check firstTool.parameters).cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected tool");
        }
        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Responses API: Test failed for prompt with initial content, ${initialText}`);
        return getTestResponsesApiResponseWithToolCall(initialText);
    }

    if hasBuiltInTool && !hasFunctionTool {
        return getTestResponsesApiChatResponse(initialText);
    }

    if toolsJson is json[] && toolsJson.length() > 0 {
        return getTestResponsesApiToolCallChatResponse();
    }

    return getTestResponsesApiChatResponse(initialText);
}

// Builds a legacy Chat Completions response carrying a single `function_call` (deprecated function-calling flow).
isolated function getLegacyChatCompletionFunctionCallResponse(string name, string arguments) returns json => {
    id: "legacy-chat-test-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "function_call",
            index: 0,
            message: {
                role: "assistant",
                content: (),
                function_call: {
                    name: name,
                    arguments: arguments
                }
            }
        }
    ],
    usage: {
        prompt_tokens: 20,
        completion_tokens: 10,
        total_tokens: 30
    }
};

// Builds a Responses API response with a function_call output item (for generate() tests)
isolated function getTestResponsesApiResponseWithToolCall(string content) returns json {
    return {
        id: "resp_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        output: [
            {
                id: "fc_test_id",
                'type: "function_call",
                name: GET_RESULTS_TOOL,
                arguments: getTheMockLLMResult(content),
                call_id: "call_test_id",
                status: "completed"
            }
        ],
        output_text: "",
        usage: {
            input_tokens: 100,
            output_tokens: 50,
            total_tokens: 150,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a Responses API response with a text message output item (for chat() tests)
isolated function getTestResponsesApiChatResponse(string content) returns json {
    string responseText = "This is a mock response for: " + content;
    return {
        id: "resp_chat_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        output: [
            {
                id: "msg_test_id",
                'type: "message",
                role: "assistant",
                status: "completed",
                content: [
                    {
                        'type: "output_text",
                        text: responseText,
                        annotations: [],
                        logprobs: []
                    }
                ]
            }
        ],
        output_text: responseText,
        usage: {
            input_tokens: 50,
            output_tokens: 30,
            total_tokens: 80,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a Chat Completions response for the Responses→Chat Completions fallback path
isolated function getChatCompletionsFallbackToolCallResponse(string content) returns json {
    return {
        id: "fallback-test-id",
        'object: "chat.completion",
        created: 1234567890,
        model: "gpt-4o",
        choices: [
            {
                finish_reason: "tool_calls",
                index: 0,
                message: {
                    role: "assistant",
                    tool_calls: [
                        {
                            id: "call_fallback_weather",
                            'type: "function",
                            'function: {
                                name: "get_weather",
                                arguments: "{\"city\": \"Paris\"}"
                            }
                        }
                    ]
                }
            }
        ]
    };
}

// Builds a Responses API response with function_call output items (for chat() with tools tests)
isolated function getTestResponsesApiToolCallChatResponse() returns json {
    return {
        id: "resp_tool_chat_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        output: [
            {
                id: "fc_chat_test_id",
                'type: "function_call",
                name: "get_weather",
                arguments: "{\"city\": \"London\"}",
                call_id: "call_weather_123",
                status: "completed"
            }
        ],
        output_text: "",
        usage: {
            input_tokens: 80,
            output_tokens: 20,
            total_tokens: 100,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}
