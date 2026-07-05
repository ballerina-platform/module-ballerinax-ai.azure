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

import ballerina/test;
import ballerinax/azure.openai.chat as chat;

// Unit tests for the api-version-driven token-limit field selection used by the Chat Completions path.
// These pin `usesMaxCompletionTokens`, `applyMaxTokens` and `buildLegacyChatBody` directly (no HTTP), while the
// integration guards in `test_services.bal` prove the selected body reaches the wire.

const int TEST_MAX_TOKENS = 512;

// Builds a minimal, valid Chat Completions request for the helper unit tests.
isolated function newTestChatRequest() returns chat:ChatCompletionsBody {
    AzureChatUserMessage userMessage = {content: "hello"};
    return {
        model: DEPLOYMENT_ID,
        messages: [userMessage],
        temperature: 0.5d
    };
}

// ===== usesMaxCompletionTokens: threshold and boundary behavior =====

@test:Config
function testUsesMaxCompletionTokensAtOrAfterThreshold() {
    test:assertTrue(usesMaxCompletionTokens("2024-08-01-preview"),
            "the 2024-08-01-preview threshold itself must use max_completion_tokens");
    test:assertTrue(usesMaxCompletionTokens("2024-08-01"),
            "the bare 2024-08-01 GA date must use max_completion_tokens");
    test:assertTrue(usesMaxCompletionTokens("2024-10-21"),
            "a later GA api-version must use max_completion_tokens");
    test:assertTrue(usesMaxCompletionTokens("2025-04-01-preview"),
            "a newer preview api-version must use max_completion_tokens");
}

@test:Config
function testUsesMaxCompletionTokensBeforeThreshold() {
    test:assertFalse(usesMaxCompletionTokens("2024-07-31-preview"),
            "the day before the threshold must fall back to max_tokens");
    test:assertFalse(usesMaxCompletionTokens("2024-02-15-preview"),
            "an older preview api-version must fall back to max_tokens");
    test:assertFalse(usesMaxCompletionTokens("2023-05-15"),
            "a much older GA api-version must fall back to max_tokens");
}

@test:Config
function testUsesMaxCompletionTokensDegenerateInputFallsBack() {
    // An empty api-version cannot be >= the threshold, so it safely falls back to the always-accepted field.
    test:assertFalse(usesMaxCompletionTokens(""),
            "an empty api-version must fall back to max_tokens");
}

// ===== applyMaxTokens: correct token-limit field on the request =====

@test:Config
function testApplyMaxTokensUsesMaxCompletionTokens() {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, TEST_MAX_TOKENS, true);
    test:assertEquals(request?.max_completion_tokens, TEST_MAX_TOKENS,
            "max_completion_tokens must carry the token limit when selected");
    test:assertTrue(request?.max_tokens is (),
            "max_tokens must not be set when max_completion_tokens is selected");
}

@test:Config
function testApplyMaxTokensUsesMaxTokens() {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, TEST_MAX_TOKENS, false);
    test:assertEquals(request?.max_tokens, TEST_MAX_TOKENS,
            "max_tokens must carry the token limit when selected");
    test:assertTrue(request?.max_completion_tokens is (),
            "max_completion_tokens must not be set on the legacy fallback path");
}

// ===== buildLegacyChatBody: correct wire body for the legacy route =====

@test:Config
function testBuildLegacyChatBodyDropsModelAndKeepsMaxTokens() returns error? {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, TEST_MAX_TOKENS, false);
    map<json> body = check buildLegacyChatBody(request);
    test:assertFalse(body.hasKey("model"),
            "the legacy route carries the deployment in the URL, so 'model' must be dropped from the body");
    test:assertTrue(body.hasKey("max_tokens"), "max_tokens must be present on the legacy fallback path");
    test:assertEquals(body["max_tokens"], TEST_MAX_TOKENS);
    test:assertFalse(body.hasKey("max_completion_tokens"),
            "max_completion_tokens must not be sent on the legacy fallback path");
}

@test:Config
function testBuildLegacyChatBodyKeepsMaxCompletionTokens() returns error? {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, 256, true);
    map<json> body = check buildLegacyChatBody(request);
    test:assertFalse(body.hasKey("model"), "'model' must be dropped from the legacy body");
    test:assertEquals(body["max_completion_tokens"], 256);
    test:assertFalse(body.hasKey("max_tokens"),
            "max_tokens must not be present when max_completion_tokens is selected");
}

@test:Config
function testBuildLegacyChatBodyPreservesOtherFields() returns error? {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, TEST_MAX_TOKENS, true);
    map<json> body = check buildLegacyChatBody(request);
    test:assertTrue(body.hasKey("temperature"), "non-token fields must be carried through unchanged");
    test:assertTrue(body.hasKey("messages"), "messages must be carried through unchanged");
    json[] messages = check body["messages"].ensureType();
    test:assertEquals(messages.length(), 1);
}

// ===== reasoning_effort handling =====
// The new connector models `reasoning_effort` as an optional (non-defaulted) field, so it is absent from the
// wire unless the caller selects an effort.

@test:Config
function testBuildLegacyChatBodyOmitsUnsetReasoningEffort() returns error? {
    chat:ChatCompletionsBody request = newTestChatRequest();
    applyMaxTokens(request, TEST_MAX_TOKENS, true);
    map<json> body = check buildLegacyChatBody(request);
    test:assertFalse(body.hasKey("reasoning_effort"),
            "reasoning_effort must be absent when the caller did not select an effort");
}

@test:Config
function testBuildLegacyChatBodyKeepsSelectedReasoningEffort() returns error? {
    chat:ChatCompletionsBody request = newTestChatRequest();
    request.reasoning_effort = "high";
    applyMaxTokens(request, TEST_MAX_TOKENS, true);
    map<json> body = check buildLegacyChatBody(request);
    test:assertTrue(body.hasKey("reasoning_effort"),
            "reasoning_effort must be kept when the caller selected an effort");
    test:assertEquals(body["reasoning_effort"], "high");
}
