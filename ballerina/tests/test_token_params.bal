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
// These pin `usesMaxCompletionTokens` and `buildChatCompletionBody` directly (no HTTP), while the
// integration guard in `test_services.bal` proves the selected body reaches the wire.

const int TEST_MAX_TOKENS = 512;

// Builds a minimal, valid Chat Completions request carrying `max_tokens` (the value the connector record
// always serializes) so the helpers have something to relocate/preserve.
isolated function newTestChatRequest(int maxTokens) returns chat:createChatCompletionRequest {
    chat:chatCompletionRequestUserMessage userMessage = {role: "user", content: "hello"};
    return {
        messages: [userMessage],
        temperature: 0.5d,
        max_tokens: maxTokens
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

// ===== buildChatCompletionBody: correct field on the wire =====

@test:Config
function testBuildChatCompletionBodyNewApiVersionUsesMaxCompletionTokens() returns error? {
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), NEW_API_VERSION, ());
    test:assertFalse(body.hasKey("max_tokens"),
            "max_tokens must be removed from the wire body on new api-versions");
    test:assertTrue(body.hasKey("max_completion_tokens"),
            "max_completion_tokens must be present on new api-versions");
    test:assertEquals(body["max_completion_tokens"], TEST_MAX_TOKENS,
            "the token-limit value must be preserved when relocated to max_completion_tokens");
}

@test:Config
function testBuildChatCompletionBodyThresholdApiVersionUsesMaxCompletionTokens() returns error? {
    map<json> body = check buildChatCompletionBody(newTestChatRequest(256), API_VERSION, ());
    test:assertFalse(body.hasKey("max_tokens"),
            "max_tokens must be absent at the 2024-08-01-preview threshold");
    test:assertEquals(body["max_completion_tokens"], 256);
}

@test:Config
function testBuildChatCompletionBodyOldApiVersionUsesMaxTokens() returns error? {
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), OLD_API_VERSION, ());
    test:assertTrue(body.hasKey("max_tokens"),
            "max_tokens must remain on old api-versions for backward compatibility");
    test:assertEquals(body["max_tokens"], TEST_MAX_TOKENS);
    test:assertFalse(body.hasKey("max_completion_tokens"),
            "max_completion_tokens must not be sent on old api-versions that do not support it");
}

@test:Config
function testBuildChatCompletionBodyNeverEmitsNullMaxTokens() returns error? {
    // Reasoning models reject both a present `max_tokens` and a null value, so on the new path the key must be
    // entirely absent — not present with a null value.
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), NEW_API_VERSION, ());
    test:assertFalse(body.hasKey("max_tokens"),
            "max_tokens must not be present at all (not even as null) on new api-versions");
}

@test:Config
function testBuildChatCompletionBodyPreservesOtherFields() returns error? {
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), NEW_API_VERSION, ());
    test:assertTrue(body.hasKey("temperature"), "non-token fields must be carried through unchanged");
    test:assertTrue(body.hasKey("messages"), "messages must be carried through unchanged");
    json[] messages = check body["messages"].ensureType();
    test:assertEquals(messages.length(), 1);
}

// ===== buildChatCompletionBody: reasoning_effort handling =====
// The generated `createChatCompletionRequest` defaults `reasoning_effort` to "medium" (it always serializes),
// so the body builder must drop it unless the caller actually selected an effort.

@test:Config
function testBuildChatCompletionBodyStripsUnsetReasoningEffort() returns error? {
    // No effort requested (reasoning is ()): the connector's defaulted "medium" must not reach the wire.
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), NEW_API_VERSION, ());
    test:assertFalse(body.hasKey("reasoning_effort"),
            "reasoning_effort must be dropped when the caller did not select an effort");
}

@test:Config
function testBuildChatCompletionBodyKeepsExplicitReasoningEffort() returns error? {
    // Effort explicitly requested: the caller sets it on the request and passes the same value in.
    chat:createChatCompletionRequest request = newTestChatRequest(TEST_MAX_TOKENS);
    request.reasoning_effort = "high";
    map<json> body = check buildChatCompletionBody(request, NEW_API_VERSION, "high");
    test:assertTrue(body.hasKey("reasoning_effort"),
            "reasoning_effort must be kept when the caller selected an effort");
    test:assertEquals(body["reasoning_effort"], "high");
}

@test:Config
function testBuildChatCompletionBodyStripsReasoningEffortOnOldApiVersion() returns error? {
    // Independent of api-version: an unset effort is dropped on the old (max_tokens) path too.
    map<json> body = check buildChatCompletionBody(newTestChatRequest(TEST_MAX_TOKENS), OLD_API_VERSION, ());
    test:assertFalse(body.hasKey("reasoning_effort"),
            "reasoning_effort must be dropped on old api-versions when no effort was selected");
}
