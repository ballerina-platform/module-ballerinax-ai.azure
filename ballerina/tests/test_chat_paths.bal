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
import ballerina/test;

// End-to-end coverage for the request-building branches of the chat() paths (every ChatMessage role and content
// shape) and their connection-failure handling, on both the Chat Completions and Responses surfaces.

// A full conversation exercises every branch of the Chat Completions request-message builder: a system message
// (with a name), a user message, an assistant message with tool calls (and content), an assistant message with
// only content, and a function (tool result) message.
@test:Config
function testChatCompletionFullConversationHistory() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are helpful.", name: "supervisor"},
        <ai:ChatUserMessage>{role: "user", content: "What is the weather in London?"},
        <ai:ChatAssistantMessage>{
            role: "assistant",
            content: "Let me check that.",
            toolCalls: [{id: "call_1", name: "get_weather", arguments: {"city": "London"}}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "get_weather", id: "call_1", content: "sunny, 20C"},
        <ai:ChatAssistantMessage>{role: "assistant", content: "It is sunny in London."}
    ];
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(messages, []);
    test:assertTrue(result.content is string);
}

// The same conversation shape on the Responses API exercises the Responses input-item builder branches
// (instructions extraction, assistant tool calls, function_call_output).
@test:Config
function testResponsesFullConversationHistory() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are helpful."},
        <ai:ChatUserMessage>{role: "user", content: "What is the weather in London?"},
        <ai:ChatAssistantMessage>{
            role: "assistant",
            content: "Let me check that.",
            toolCalls: [{id: "call_1", name: "get_weather", arguments: {"city": "London"}}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "get_weather", id: "call_1", content: "sunny, 20C"}
    ];
    ai:ChatAssistantMessage result = check responsesProvider->chat(messages, []);
    test:assertTrue(result.content is string);
}

// A user message whose content is a prompt carrying an image document exercises the document-content branch of
// the user-message mapper (Chat Completions).
@test:Config
function testChatCompletionUserMessageWithImagePrompt() returns ai:Error? {
    ai:ImageDocument img = {content: "https://example.com/i.png", metadata: {mimeType: "image/png"}};
    ai:ChatUserMessage userMsg = {role: "user", content: `Describe ${img}`};
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(userMsg, []);
    test:assertTrue(result.content is string);
}

// The same on the Responses API exercises the prompt branch of the Responses user-content builder.
@test:Config
function testResponsesUserMessageWithImagePrompt() returns ai:Error? {
    ai:ImageDocument img = {content: "https://example.com/i.png", metadata: {mimeType: "image/png"}};
    ai:ChatUserMessage userMsg = {role: "user", content: `Describe ${img}`};
    ai:ChatAssistantMessage result = check responsesProvider->chat(userMsg, []);
    test:assertTrue(result.content is string);
}

// A user message prompt carrying an unsupported document must fail while building the Chat Completions request.
@test:Config
function testChatCompletionRequestBuildFailure() returns error? {
    ai:FileDocument doc = {content: "raw"};
    ai:ChatUserMessage userMsg = {role: "user", content: `See ${doc}`};
    ai:ChatAssistantMessage|ai:Error result = chatCompletionProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error, "an unsupported document must fail request building");
}

// A user message prompt carrying audio cannot be represented on the Responses API and must fail input transform.
@test:Config
function testResponsesRequestBuildFailure() returns error? {
    ai:AudioDocument aud = {content: sampleBinaryData, metadata: {"format": "mp3"}};
    ai:ChatUserMessage userMsg = {role: "user", content: `Describe ${aud}`};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error, "audio is unsupported on the Responses API");
    test:assertTrue((<ai:Error>result).message().includes("transforming input"),
            "unexpected error: " + (<ai:Error>result).message());
}

// ===== connection failures on the chat() paths =====

@test:Config
function testChatCompletionConnectionFailure() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage|ai:Error result = unreachableChatProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("connecting to the model"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesConnectionFailure() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage|ai:Error result = unreachableResponsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("connecting to the model"),
            "unexpected error: " + (<ai:Error>result).message());
}
