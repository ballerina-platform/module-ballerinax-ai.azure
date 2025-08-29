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
    private map<int> retryCountMap = {};

    isolated resource function post azureopenai/deployments/gpt4onew/chat/completions(
            @http:Payload chat:CreateChatCompletionRequest payload) returns chat:CreateChatCompletionResponse|error {
        [chat:ChatCompletionRequestMessage[], string] [messages, initialText] = check validateChatCompletionPayload(payload);

        json[]? content = check messages[0]["content"].ensureType();
        test:assertEquals(content, check getExpectedContentParts(initialText),
            string `Prompt assertion failed for prompt starting with '${initialText}'`);

        return check getTestServiceResponse(initialText);
    }

    isolated resource function post azureopenai/deployments/gpt4onew\-retry/chat/completions(
            @http:Payload chat:CreateChatCompletionRequest payload) returns chat:CreateChatCompletionResponse|error {
        [chat:ChatCompletionRequestMessage[], string] [messages, initialText] = check validateChatCompletionPayload(payload);

        int index;
        lock {
            index = updateRetryCountMap(initialText, self.retryCountMap);
        }

        check assertContentParts(messages, initialText, index);
        return check getTestServiceResponse(initialText, index);
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

isolated function validateChatCompletionPayload(chat:CreateChatCompletionRequest payload) 
        returns [chat:ChatCompletionRequestMessage[], string]|error {
    test:assertEquals(payload?.temperature, 0.7d);

    chat:ChatCompletionRequestMessage[] messages = check payload.messages.ensureType();
    chat:ChatCompletionRequestMessage message = messages[0];
    test:assertEquals(message.role, "user");

    json[]? content = check message["content"].ensureType();
    if content is () {
        test:assertFail("Expected content in the payload");
    }

    TextContentPart initialTextContent = check content[0].fromJsonWithType();
    string initialText = initialTextContent.text;

    chat:ChatCompletionTool[]? tools = payload.tools;
    if tools is () || tools.length() == 0 {
        test:assertFail("No tools in the payload");
    }

    map<json>? parameters = check tools[0].'function?.parameters.toJson().cloneWithType();
    if parameters is () {
        test:assertFail("No parameters in the expected tool");
    }

    test:assertEquals(parameters, getExpectedParameterSchema(initialText),
            string `Parameter assertion failed for prompt starting with '${initialText}'`);

    return [messages, initialText];
}

isolated function assertContentParts(chat:ChatCompletionRequestMessage[] messages, 
        string initialText, int index) returns error? {
    if index >= messages.length() {
        test:assertFail(string `Expected at least ${index + 1} message(s) in the payload`);
    }

    // Test input messages where the role is 'user'.
    chat:ChatCompletionRequestMessage message = messages[index * 2];

    json|error? content = message["content"].ensureType();

    if content is () {
        test:assertFail("Expected content in the payload");
    }

    if index == 0 {
        test:assertEquals(content, check getExpectedContentParts(initialText),
            string `Prompt assertion failed for prompt starting with '${initialText}'`);
        return;
    }

    if index == 1 {
        test:assertEquals(content, check getExpectedContentPartsForFirstRetryCall(initialText),
            string `Prompt assertion failed for prompt starting with '${initialText}' 
                on first attempt of the retry`);
        return;
    }

    test:assertEquals(content,check getExpectedContentPartsForSecondRetryCall(initialText),
            string `Prompt assertion failed for prompt starting with '${initialText}' on 
                second attempt of the retry`);
}
