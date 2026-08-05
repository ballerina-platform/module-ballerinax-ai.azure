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
import ballerina/http;
import ballerina/test;
import ballerinax/azure.openai.chat;
import ballerinax/azure.openai.responses;

// The native `generate()` entry point dispatches into `generateLlmResponse` / `generateLlmResponseViaResponses`
// via a Java `callFunction`, which is not attributed to Ballerina code coverage. These tests therefore call those
// module functions directly (constructing the same clients the provider would), exercising the structured
// generation paths — happy paths, reasoning, the v1 opt-in, and every error branch — on both surfaces.

// Clients pointed at the two mock services.
final http:Client legacyChatRawClient = check new ("http://localhost:8080/llm/azureopenai/openai",
    toRawHttpConfig({}));
final http:Client legacyResponsesRawClient = check new ("http://localhost:8080/llm/azureopenai/openai",
    toRawHttpConfig({}));
final chat:Client v1ChatConnector = check new (toChatConnectionConfig(API_KEY, {}), SERVICE_URL_V1);
final responses:Client v1ResponsesConnector = check new (toResponsesConnectionConfig(API_KEY, {}), SERVICE_URL_V1);
// A client pointed at a port with nothing listening, to drive the connection-failure branches.
final http:Client unreachableClient = check new ("http://localhost:8099/nowhere", toRawHttpConfig({}));

// A prompt whose content/schema the mock recognises ("Rate this blog" -> integer result 4).
function ratePrompt() returns ai:Prompt => `Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`;

// ===== generateLlmResponse (Chat Completions) =====

@test:Config
function testGenerateLlmResponseLegacyHappyPath() returns error? {
    anydata result = check generateLlmResponse((), legacyChatRawClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), 0.7d, 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateLlmResponseLegacyReasoningNoTemperature() returns error? {
    // Reasoning model: no temperature, a reasoning effort, and a post-threshold api-version (max_completion_tokens).
    anydata result = check generateLlmResponse((), legacyChatRawClient, false, API_KEY, REASONING_DEPLOYMENT,
        NEW_API_VERSION, (), (), 512, HIGH, ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateLlmResponseV1HappyPath() returns error? {
    anydata result = check generateLlmResponse(v1ChatConnector, (), true, API_KEY, DEPLOYMENT_ID,
        (), (), 0.5d, 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateLlmResponseV1WithApiVersionOptIn() returns error? {
    anydata result = check generateLlmResponse(v1ChatConnector, (), true, API_KEY, DEPLOYMENT_ID,
        (), "preview", (), 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateLlmResponseConnectionFailure() {
    anydata|ai:Error result = generateLlmResponse((), unreachableClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), (), 512, (), ratePrompt(), int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("LLM call failed"));
}

@test:Config
function testGenerateLlmResponseMalformedArguments() {
    ai:Prompt prompt = `TRIGGER_GEN_BAD_ARGS produce something`;
    anydata|ai:Error result = generateLlmResponse((), legacyChatRawClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes(NO_RELEVANT_RESPONSE_FROM_THE_LLM));
}

@test:Config
function testGenerateLlmResponseTypeMismatch() {
    ai:Prompt prompt = `TRIGGER_GEN_TYPE_MISMATCH produce something`;
    anydata|ai:Error result = generateLlmResponse((), legacyChatRawClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Invalid value returned from the LLM Client"));
}

@test:Config
function testGenerateLlmResponseEmptyChoices() {
    ai:Prompt prompt = `TRIGGER_GEN_EMPTY_CHOICES produce something`;
    anydata|ai:Error result = generateLlmResponse((), legacyChatRawClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error, "an empty choices array must be an error");
}

@test:Config
function testGenerateLlmResponseUnsupportedDocumentFails() {
    ai:FileDocument doc = {content: "raw"};
    ai:Prompt prompt = `Summarize ${doc}`;
    anydata|ai:Error result = generateLlmResponse((), legacyChatRawClient, false, API_KEY, DEPLOYMENT_ID,
        NEW_API_VERSION, (), (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error, "an unsupported document must fail before the LLM call");
}

// ===== generateLlmResponseViaResponses (Responses API) =====

@test:Config
function testGenerateViaResponsesLegacyHappyPath() returns error? {
    anydata result = check generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, 0.7d, 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateViaResponsesReasoningNoTemperature() returns error? {
    anydata result = check generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), REASONING_DEPLOYMENT, (), 512, HIGH, ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateViaResponsesV1HappyPath() returns error? {
    anydata result = check generateLlmResponseViaResponses(v1ResponsesConnector, (), true, API_KEY,
        (), (), DEPLOYMENT_ID, 0.5d, 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateViaResponsesV1WithApiVersionOptIn() returns error? {
    anydata result = check generateLlmResponseViaResponses(v1ResponsesConnector, (), true, API_KEY,
        (), "v1", DEPLOYMENT_ID, (), 512, (), ratePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateViaResponsesConnectionFailure() {
    anydata|ai:Error result = generateLlmResponseViaResponses((), unreachableClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), ratePrompt(), int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("LLM call failed"));
}

@test:Config
function testGenerateViaResponsesStatusFailed() {
    ai:Prompt prompt = `TRIGGER_STATUS_FAILED do work`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("The upstream model failed"));
}

@test:Config
function testGenerateViaResponsesNoRelevantResponse() {
    // A response with no getResults function_call (a plain message) yields "no relevant response".
    ai:Prompt prompt = `TRIGGER_OUTPUT_MESSAGE do work`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes(NO_RELEVANT_RESPONSE_FROM_THE_LLM));
}

@test:Config
function testGenerateViaResponsesMalformedArguments() {
    ai:Prompt prompt = `TRIGGER_GEN_BAD_ARGS do work`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes(NO_RELEVANT_RESPONSE_FROM_THE_LLM));
}

@test:Config
function testGenerateViaResponsesTypeMismatch() {
    ai:Prompt prompt = `TRIGGER_GEN_TYPE_MISMATCH do work`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Invalid value returned from the LLM Client"));
}

@test:Config
function testGenerateViaResponsesUnsupportedDocument() {
    // An unsupported document fails while building the request content (before the LLM call / status check).
    ai:FileDocument doc = {content: "raw"};
    ai:Prompt prompt = `Summarize ${doc}`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error, "an unsupported document must fail before the LLM call");
}

@test:Config
function testGenerateViaResponsesAudioUnsupported() {
    // Audio content cannot be represented on the Responses API and must fail before the call.
    ai:AudioDocument aud = {content: sampleBinaryData, metadata: {"format": "mp3"}};
    ai:Prompt prompt = `Describe ${aud}`;
    anydata|ai:Error result = generateLlmResponseViaResponses((), legacyResponsesRawClient, false, API_KEY,
        API_VERSION, (), DEPLOYMENT_ID, (), 512, (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Audio input is not supported"));
}

// ===== postChatCompletion / postResponsesRequest: uninitialised-client guards =====

@test:Config
function testPostChatCompletionV1ClientNotInitialised() {
    chat:ChatCompletionsBody request = {model: DEPLOYMENT_ID, messages: []};
    chat:InlineResponse200|error result = postChatCompletion((), (), true, API_KEY, DEPLOYMENT_ID, (), (), request);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("not initialized"));
}

@test:Config
function testPostChatCompletionLegacyClientNotInitialised() {
    chat:ChatCompletionsBody request = {model: DEPLOYMENT_ID, messages: []};
    chat:InlineResponse200|error result = postChatCompletion((), (), false, API_KEY, DEPLOYMENT_ID,
        API_VERSION, (), request);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("not initialized"));
}

@test:Config
function testPostResponsesV1ClientNotInitialised() {
    responses:OpenAICreateResponse request = {model: DEPLOYMENT_ID, input: []};
    responses:InlineResponse200|error result = postResponsesRequest((), (), true, API_KEY, (), (), request);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("not initialized"));
}

@test:Config
function testPostResponsesLegacyClientNotInitialised() {
    responses:OpenAICreateResponse request = {model: DEPLOYMENT_ID, input: []};
    responses:InlineResponse200|error result = postResponsesRequest((), (), false, API_KEY, API_VERSION, (), request);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("not initialized"));
}
