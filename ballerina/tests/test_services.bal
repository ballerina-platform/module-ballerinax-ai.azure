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
import ballerinax/azure.openai.chat;
import ballerinax/azure.openai.embeddings;

service /llm on new http:Listener(8080) {
    resource function post azureopenai/deployments/gpt4onew/chat/completions(
            string api\-version, chat:CreateChatCompletionRequest payload)
                returns chat:CreateChatCompletionResponse|error {
        test:assertEquals(api\-version, "2023-08-01-preview");
        test:assertEquals(payload?.temperature, DEFAULT_TEMPERATURE);
        test:assertEquals(payload.max_tokens, DEFAULT_MAX_TOKEN_COUNT);
        chat:ChatCompletionRequestMessage[] messages = check payload.messages.ensureType();
        chat:ChatCompletionRequestMessage message = messages[0];

        json[]? content = check message["content"].ensureType();
        if content is () {
            test:assertFail("Expected content in the payload");
        }

        TextContentPart initialTextContent = check content[0].fromJsonWithType();
        string initialText = initialTextContent.text.toString();
        test:assertEquals(content, getExpectedContentParts(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        test:assertEquals(message.role, "user");
        chat:ChatCompletionTool[]? tools = payload.tools;
        if tools is () || tools.length() == 0 {
            test:assertFail("No tools in the payload");
        }

        map<json>? parameters = check tools[0].'function?.parameters.toJson().cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected tool");
        }

        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        return getTestServiceResponse(initialText);
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

// Separate mock service for parallel tool call tests
service / on new http:Listener(8081) {
    resource function post deployments/[string deploymentId]/chat/completions(
            string api\-version, chat:CreateChatCompletionRequest payload)
                returns chat:CreateChatCompletionResponse|error {

        chat:ChatCompletionRequestMessage[] messages = check payload.messages.ensureType();

        if messages.length() == 1 {
            // First turn: return two parallel tool calls
            return {
                id: "parallel-test-id",
                'object: "chat.completion",
                created: 1234567890,
                model: "gpt-4o",
                choices: [
                    {
                        message: {
                            role: "assistant",
                            tool_calls: [
                                {
                                    id: "call_paris_id",
                                    'type: "function",
                                    'function: {name: "getWeather", arguments: "{\"city\": \"Paris\"}"}
                                },
                                {
                                    id: "call_tokyo_id",
                                    'type: "function",
                                    'function: {name: "getWeather", arguments: "{\"city\": \"Tokyo\"}"}
                                }
                            ]
                        }
                    }
                ]
            };
        }

        // Second turn: verify history is reconstructed correctly
        // Assistant message must use tool_calls (not function_call)
        json[]? toolCallsInHistory = check messages[1]["tool_calls"].ensureType();
        test:assertTrue(toolCallsInHistory is json[], "Assistant message must use tool_calls field");
        test:assertEquals((<json[]>toolCallsInHistory).length(), 2, "Both tool calls must be in history");

        // Tool result messages must use role: "tool" with tool_call_id
        test:assertEquals(messages[2]["role"], "tool", "First tool result must have role 'tool'");
        test:assertEquals(messages[2]["tool_call_id"], "call_paris_id", "First result must reference call_paris_id");
        test:assertEquals(messages[3]["role"], "tool", "Second tool result must have role 'tool'");
        test:assertEquals(messages[3]["tool_call_id"], "call_tokyo_id", "Second result must reference call_tokyo_id");

        return {
            id: "parallel-test-id-2",
            'object: "chat.completion",
            created: 1234567890,
            model: "gpt-4o",
            choices: [
                {
                    message: {
                        role: "assistant",
                        content: "Paris is sunny at 25°C and Tokyo is rainy at 18°C."
                    }
                }
            ]
        };
    }
}
