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

// ===== api-version validation on the legacy surface =====

// An empty (whitespace-only) api-version is treated the same as a missing one on the legacy surface.
@test:Config
function testLegacyServiceUrlWithEmptyApiVersionFails() {
    OpenAiModelProvider|ai:Error provider =
        new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, "   ", apiType = CHAT_COMPLETION);
    test:assertTrue(provider is ai:Error, "a blank api-version must be rejected for a legacy URL");
    test:assertTrue((<ai:Error>provider).message().includes("'apiVersion' argument is required"));
}

@test:Config
function testLegacyResponsesUrlWithoutApiVersionFails() {
    OpenAiModelProvider|ai:Error provider =
        new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, apiType = RESPONSES);
    test:assertTrue(provider is ai:Error, "the Responses legacy route also requires an api-version");
}

// ===== v1 surface: api-version handling =====

// A date-based api-version is ignored (with a warning) on the v1 GA surface; init still succeeds.
@test:Config
function testV1ServiceUrlIgnoresDateApiVersion() returns ai:Error? {
    OpenAiModelProvider provider =
        check new (SERVICE_URL_V1, API_KEY, DEPLOYMENT_ID, "2024-10-21", apiType = CHAT_COMPLETION);
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// A trailing slash on the service URL is normalised before the `/v1` suffix check.
@test:Config
function testV1ServiceUrlWithTrailingSlash() returns ai:Error? {
    OpenAiModelProvider provider =
        check new (SERVICE_URL_V1 + "/", API_KEY, DEPLOYMENT_ID, apiType = CHAT_COMPLETION);
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// ===== legacy base-path normalisation =====

// A legacy service URL that already ends with `/openai` must not get a second `/openai` appended.
@test:Config
function testLegacyServiceUrlAlreadyEndingWithOpenai() returns ai:Error? {
    OpenAiModelProvider provider =
        check new ("http://localhost:8080/llm/azureopenai/openai", API_KEY, DEPLOYMENT_ID, API_VERSION,
            apiType = CHAT_COMPLETION);
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check provider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// ===== client initialisation failures (malformed service URL) =====
// A URL with a space in the authority is syntactically invalid, so the underlying client fails to initialise for
// each (apiType, surface) combination.

@test:Config
function testChatV1ClientInitFailure() {
    OpenAiModelProvider|ai:Error provider =
        new ("http://invalid host/v1", API_KEY, DEPLOYMENT_ID, apiType = CHAT_COMPLETION);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Chat Completions (v1)"));
}

@test:Config
function testChatLegacyClientInitFailure() {
    OpenAiModelProvider|ai:Error provider =
        new ("http://invalid host", API_KEY, DEPLOYMENT_ID, API_VERSION, apiType = CHAT_COMPLETION);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Chat Completions"));
}

@test:Config
function testResponsesV1ClientInitFailure() {
    OpenAiModelProvider|ai:Error provider =
        new ("http://invalid host/v1", API_KEY, DEPLOYMENT_ID, apiType = RESPONSES);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Responses (v1)"));
}

@test:Config
function testResponsesLegacyClientInitFailure() {
    OpenAiModelProvider|ai:Error provider =
        new ("http://invalid host", API_KEY, DEPLOYMENT_ID, API_VERSION, apiType = RESPONSES);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Responses"));
}

// ===== EmbeddingProvider: api-version resolution =====
// The embedding provider resolves the api-version exactly like the model provider: it is required on the legacy
// deployment-scoped route and optional on the v1 GA surface (`/v1`-suffixed service URL).

// A legacy (non-`/v1`) service URL requires an `api-version`; omitting it must fail fast at init.
@test:Config
function testEmbeddingLegacyServiceUrlWithoutApiVersionFails() {
    EmbeddingProvider|ai:Error provider = new (SERVICE_URL, API_KEY, (), DEPLOYMENT_ID);
    test:assertTrue(provider is ai:Error, "expected init to fail when api-version is omitted for a legacy URL");
    test:assertTrue((<ai:Error>provider).message().includes("'apiVersion' argument is required"),
            "unexpected error message: " + (<ai:Error>provider).message());
}

// An empty (whitespace-only) api-version is treated the same as a missing one on the legacy surface.
@test:Config
function testEmbeddingLegacyServiceUrlWithEmptyApiVersionFails() {
    EmbeddingProvider|ai:Error provider = new (SERVICE_URL, API_KEY, "   ", DEPLOYMENT_ID);
    test:assertTrue(provider is ai:Error, "a blank api-version must be rejected for a legacy URL");
    test:assertTrue((<ai:Error>provider).message().includes("'apiVersion' argument is required"));
}

// A date-based api-version is ignored (with a warning) on the v1 GA surface; the request must not carry it (the
// mock's `assertV1ApiVersion` guard fails the test if it does).
@test:Config
function testEmbeddingV1ServiceUrlIgnoresDateApiVersion() returns error? {
    EmbeddingProvider provider = check new (SERVICE_URL_V1, API_KEY, "2024-10-21", DEPLOYMENT_ID);
    ai:Embedding embedding = check provider->embed(<ai:TextChunk>{content: "Hello, world!"});
    float[] vectors = check embedding.cloneWithType();
    test:assertEquals(vectors.length(), 1536);
}

// `preview` and `v1` are the opt-in v1 surfaces and ARE forwarded as `?api-version=` on the v1 route.
@test:Config {
    dataProvider: v1ApiVersionOptIns
}
function testEmbeddingV1ServiceUrlForwardsOptInApiVersion(string optIn) returns error? {
    EmbeddingProvider provider = check new (SERVICE_URL_V1, API_KEY, optIn, DEPLOYMENT_ID);
    ai:Embedding embedding = check provider->embed(<ai:TextChunk>{content: "Hello, world!"});
    float[] vectors = check embedding.cloneWithType();
    test:assertEquals(vectors.length(), 1536);
}

function v1ApiVersionOptIns() returns string[][] => [["preview"], ["v1"]];

// A trailing slash on the service URL is normalised before the `/v1` suffix check.
@test:Config
function testEmbeddingV1ServiceUrlWithTrailingSlash() returns error? {
    EmbeddingProvider provider = check new (SERVICE_URL_V1 + "/", API_KEY, (), DEPLOYMENT_ID);
    ai:Embedding embedding = check provider->embed(<ai:TextChunk>{content: "Hello, world!"});
    float[] vectors = check embedding.cloneWithType();
    test:assertEquals(vectors.length(), 1536);
}

// ===== EmbeddingProvider: client initialisation failures (malformed service URL) =====

@test:Config
function testEmbeddingV1ClientInitFailure() {
    EmbeddingProvider|ai:Error provider = new ("http://invalid host/v1", API_KEY, (), DEPLOYMENT_ID);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Embeddings (v1)"),
            "unexpected error message: " + (<ai:Error>provider).message());
}

@test:Config
function testEmbeddingLegacyClientInitFailure() {
    EmbeddingProvider|ai:Error provider = new ("http://invalid host", API_KEY, API_VERSION, DEPLOYMENT_ID);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Failed to initialize"),
            "unexpected error message: " + (<ai:Error>provider).message());
}
