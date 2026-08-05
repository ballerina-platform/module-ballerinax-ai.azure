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

// ===== Reasoning models: Chat Completions API =====
// A reasoning model omits `temperature` and carries a `reasoning_effort`. The mock (keyed on the reasoning
// deployment id) asserts both facts reach the wire, and additionally that the token limit is sent as
// `max_completion_tokens` (reasoning models reject the legacy `max_tokens`).

@test:Config
function testReasoningChatCompletionsLegacy() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check reasoningChatLegacyProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testReasoningChatCompletionsV1() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check reasoningChatV1Provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testReasoningChatCompletionsWithTools() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
        }
    ];
    ai:ChatAssistantMessage result = check reasoningChatV1Provider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
}

// ===== Reasoning models: Responses API =====
// A reasoning model carries a nested `reasoning: {effort}` object and omits `temperature`.

@test:Config
function testReasoningResponsesLegacy() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check reasoningResponsesLegacyProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testReasoningResponsesV1() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check reasoningResponsesV1Provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testReasoningResponsesWithTools() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
        }
    ];
    ai:ChatAssistantMessage result = check reasoningResponsesV1Provider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
}

// Every reasoning-effort value accepted by the Azure OpenAI spec must round-trip through both API paths. The
// mock validates the value on the wire.
@test:Config
function testAllReasoningEffortValuesChatCompletions() returns ai:Error? {
    ReasoningEffort[] efforts = [NONE, MINIMAL, LOW, MEDIUM, HIGH, XHIGH];
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    foreach ReasoningEffort effort in efforts {
        OpenAiModelProvider provider = check new (SERVICE_URL_V1, API_KEY, REASONING_DEPLOYMENT,
            reasoningEffort = effort, temperature = (), apiType = CHAT_COMPLETION);
        ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
        test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
    }
}

@test:Config
function testAllReasoningEffortValuesResponses() returns ai:Error? {
    ReasoningEffort[] efforts = [NONE, MINIMAL, LOW, MEDIUM, HIGH, XHIGH];
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    foreach ReasoningEffort effort in efforts {
        OpenAiModelProvider provider = check new (SERVICE_URL_V1, API_KEY, REASONING_DEPLOYMENT,
            reasoningEffort = effort, temperature = (), apiType = RESPONSES);
        ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
        test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
    }
}

// ===== maxTokens parameter reaches the wire =====

@test:Config
function testCustomMaxTokensChatCompletions() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check customTokensChatProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testCustomMaxTokensResponses() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check customTokensResponsesV1Provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// ===== v1 GA `preview`/`v1` api-version opt-in reaches the wire =====

@test:Config
function testV1PreviewApiVersionChatCompletions() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check v1PreviewChatProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testV1OptInApiVersionResponses() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check v1OptInResponsesProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// ===== stop sequence: Chat Completions forwards it; Responses warns and ignores it =====

@test:Config
function testChatCompletionWithStopSequence() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(userMsg, [], "STOP");
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testResponsesWithStopSequenceIsIgnored() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    // The Responses API does not support `stop`; the provider logs a warning and proceeds.
    ai:ChatAssistantMessage result = check responsesProvider->chat(userMsg, [], "STOP");
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// ===== connection configuration is accepted and used =====

@test:Config
function testProviderWithCustomConnectionConfig() returns ai:Error? {
    OpenAiModelProvider provider = check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION,
        apiType = CHAT_COMPLETION, timeout = 120, forwarded = "enable");
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testV1ProviderWithCustomConnectionConfig() returns ai:Error? {
    OpenAiModelProvider provider = check new (SERVICE_URL_V1, API_KEY, DEPLOYMENT_ID,
        apiType = RESPONSES, timeout = 90);
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}
