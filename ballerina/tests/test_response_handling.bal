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

import ballerina/ai;
import ballerina/test;

// ===== Chat Completions: response-handling edge cases =====

// A streaming (`chat.completion.chunk`) response must be rejected; this module never streams.
@test:Config
function testChatCompletionStreamingResponseRejected() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STREAMING};
    ai:ChatAssistantMessage|ai:Error result = chatCompletionProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error, "a streaming response must be rejected");
    test:assertTrue((<ai:Error>result).message().includes("Streaming"),
            "unexpected error: " + (<ai:Error>result).message());
}

// An empty `choices` array must produce an "empty response" error.
@test:Config
function testChatCompletionEmptyChoices() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_EMPTY_CHOICES};
    ai:ChatAssistantMessage|ai:Error result = chatCompletionProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error, "empty choices must be an error");
    test:assertTrue((<ai:Error>result).message().includes("Empty response"),
            "unexpected error: " + (<ai:Error>result).message());
}

// Note on the `custom` tool-call guard in `convertChatCompletionsResponseToAssistantMessage`: a `custom`-type
// tool call cannot be delivered through either transport, because neither the v1 connector's strict response
// binding nor the legacy raw client's `laxDataBinding` can bind a `{"type":"custom", ...}` element to the
// `OpenAIChatCompletionMessageToolCall|OpenAIChatCompletionMessageCustomToolCall` union (union discrimination
// fails before the converter runs). That branch is therefore a defensive guard with no reachable wire input.

// The deprecated top-level `function_call` field must still be honored (backward compatibility).
@test:Config
function testChatCompletionDeprecatedFunctionCall() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_FUNCTION_CALL};
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(userMsg, []);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "Paris"});
}

// Malformed tool-call arguments (invalid JSON) must produce a parse error.
@test:Config
function testChatCompletionMalformedToolArgs() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_BAD_TOOL_ARGS};
    ai:ChatAssistantMessage|ai:Error result = chatCompletionProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error, "malformed tool args must be an error");
}

// ===== Responses API: status handling =====

@test:Config
function testResponsesStatusFailedWithError() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_FAILED};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("The upstream model failed"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusFailedWithoutError() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_FAILED_NOERR};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Response generation failed"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusIncompleteWithDetails() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_INCOMPLETE};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Response incomplete"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusIncompleteWithoutDetails() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_INCOMPLETE_NODETAIL};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Response generation incomplete"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusCancelled() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_CANCELLED};
    ai:ChatAssistantMessage|ai:Error result = responsesV1Provider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("cancelled"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusInProgress() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_INPROGRESS};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("in_progress"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesStatusQueued() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_STATUS_QUEUED};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("queued"),
            "unexpected error: " + (<ai:Error>result).message());
}

// ===== Responses API: output-item parsing =====

@test:Config
function testResponsesEmptyOutput() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_EMPTY_OUTPUT};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Empty response from the model"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesFunctionCallBadArgs() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_BAD_ARGS};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Failed to parse function call arguments"),
            "unexpected error: " + (<ai:Error>result).message());
}

// A function_call whose arguments are valid JSON but not a JSON object must fail the arguments-to-map conversion.
@test:Config
function testResponsesFunctionCallArgsNotObject() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_ARGS_NOT_OBJECT};
    ai:ChatAssistantMessage|ai:Error result = responsesProvider->chat(userMsg, []);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("convert parsed arguments"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testResponsesOutputMessageVariant() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_OUTPUT_MESSAGE};
    ai:ChatAssistantMessage result = check responsesV1Provider->chat(userMsg, []);
    test:assertEquals(result.content, "Variant message response.");
}

@test:Config
function testResponsesContentAndToolCombined() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: TRIGGER_CONTENT_AND_TOOL};
    ai:ChatAssistantMessage result = check responsesProvider->chat(userMsg, []);
    test:assertEquals(result.content, "Let me check the weather.");
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "Berlin"});
}
