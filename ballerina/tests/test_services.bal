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
}
