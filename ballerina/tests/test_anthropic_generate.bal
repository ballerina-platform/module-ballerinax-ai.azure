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

// Coverage of `AnthropicModelProvider.generate()`.
//
// The provider-level tests below exercise the native `generate` entry point end to end, which also proves the
// compiler plugin adds the JSON schema annotation for the types used with this provider. Because the native
// dispatch goes through a Java `callFunction`, it is not attributed to Ballerina code coverage, so the module
// function it lands in (`generateAnthropicLlmResponse`) is additionally called directly further down.

type AnthropicReviewArray Review[];

type AnthropicCricketer record {|
    string name;
|};

// ===== generate(): through the provider =====

@test:Config
function testAnthropicGenerateWithBasicReturnType() returns ai:Error? {
    int rating = check anthropicProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testAnthropicGenerateWithBasicArrayReturnType() returns ai:Error? {
    int[] ratings = check anthropicProvider->generate(`Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(ratings, [9, 1]);
}

@test:Config
function testAnthropicGenerateWithRecordReturnType() returns error? {
    Review result = check anthropicProvider->generate(`Please rate this blog out of ${"10"}.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testAnthropicGenerateWithRecordArrayReturnType() returns error? {
    int maxScore = 10;
    Review expected = check review.fromJsonStringWithType(Review);
    AnthropicReviewArray result = check anthropicProvider->generate(`Please rate this blogs out of ${maxScore}.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`);
    test:assertEquals(result, [expected, expected]);
}

@test:Config
function testAnthropicGenerateWithNilableReturnType() returns error? {
    string? result = check anthropicProvider->generate(`Give me a random joke`);
    test:assertTrue(result is string);
}

@test:Config
function testAnthropicGenerateWithRecordArrayOnly() returns error? {
    AnthropicCricketer[] result = check anthropicProvider->generate(`Name 10 world class cricketers in India`);
    test:assertEquals(result.length(), 10);
}

// A text document insertion becomes its own text block; the exact block list is pinned by the mock.
@test:Config
function testAnthropicGenerateWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {content: string `Title: ${blog1.title} Content: ${blog1.content}`};
    int rating = check anthropicProvider->generate(
        `How would you rate this blog content out of 10. ${blog}.`);
    test:assertEquals(rating, 4);
}

// An image URL becomes a `url` image source.
@test:Config
function testAnthropicGenerateWithImageUrl() returns ai:Error? {
    ai:ImageDocument image = {content: sampleImageUrl, metadata: {mimeType: "image/jpg"}};
    string description = check anthropicProvider->generate(`Describe the image. ${image}.`);
    test:assertEquals(description, "This is a sample image description.");
}

// Binary image content becomes a `base64` image source carrying the metadata media type.
@test:Config
function testAnthropicGenerateWithBinaryImage() returns ai:Error? {
    ai:ImageDocument image = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    string description = check anthropicProvider->generate(`Describe the following image. ${image}.`);
    test:assertEquals(description, "This is a sample image description.");
}

// Binary file content becomes a `base64` document source, which is how PDFs are sent.
@test:Config
function testAnthropicGenerateWithPdfDocument() returns ai:Error? {
    ai:FileDocument document = {content: sampleBinaryData, metadata: {mimeType: "application/pdf"}};
    string description = check anthropicProvider->generate(`Summarize this document. ${document}.`);
    test:assertEquals(description, ANTHROPIC_PDF_RESULT);
}

@test:Config
function testAnthropicGenerateWithInvalidBasicType() {
    boolean|error result = anthropicProvider->generate(`What is ${1} + ${1}?`);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes(ERROR_MESSAGE),
            "unexpected error: " + (<error>result).message());
}

@test:Config
function testAnthropicGenerateWithUnsupportedRuntimeSchema() {
    ProductName[]|map<string>|error result = trap anthropicProvider->generate(
        `Tell me name and the age of the top 10 world class cricketers`);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes(RUNTIME_SCHEMA_NOT_SUPPORTED_ERROR_MESSAGE),
            "unexpected error: " + (<error>result).message());
}

@test:Config
function testAnthropicGenerateWithUnsupportedDocument() {
    ai:AudioDocument audio = {content: sampleBinaryData, metadata: {"format": "mp3"}};
    string|error result = anthropicProvider->generate(`Describe the audio. ${audio}.`);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("Audio documents are not supported"),
            "unexpected error: " + (<error>result).message());
}

@test:Config
function testAnthropicGenerateConnectionFailure() {
    int|error result = anthropicUnreachableProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes("LLM call failed"),
            "unexpected error: " + (<error>result).message());
}

// Manual extended thinking is rejected by the Messages API alongside a forced tool choice, so `generate()` must
// drop it. The mock fails the request if `thinking.type` is `"enabled"` on a forced-tool-choice call.
@test:Config
function testAnthropicGenerateDropsExtendedThinking() returns ai:Error? {
    int rating = check anthropicExtendedThinkingProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

// Adaptive thinking supports forced tool use and is passed through unchanged.
@test:Config
function testAnthropicGenerateKeepsAdaptiveThinking() returns ai:Error? {
    int rating = check anthropicAdaptiveThinkingProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

// The effort level must survive the native `generate` boundary too; the mock asserts `output_config.effort` is
// present for the effort deployment.
@test:Config
function testAnthropicGenerateForwardsEffort() returns ai:Error? {
    int rating = check anthropicEffortProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

// ===== generate(): union and collection return types =====
// These drive the compiler plugin's schema generation (including its `anyOf` handling) through the new provider,
// which is a separate symbol from `OpenAiModelProvider` in the plugin.

type AnthropicJoke record {|
    string name;
|};

type AnthropicPlayer record {|
    string name;
|};

type AnthropicSquad record {|
    string name;
|};

@test:Config
function testAnthropicGenerateWithRecordUnionBasicType() returns error? {
    AnthropicJoke|string result = check anthropicProvider->generate(`Give me a random joke about cricketers`);
    test:assertTrue(result is string);
}

@test:Config
function testAnthropicGenerateWithRecordUnionNil() returns error? {
    AnthropicPlayer? result = check anthropicProvider->generate(`Name a random world class cricketer in India`);
    test:assertTrue(result is AnthropicPlayer);
}

@test:Config
function testAnthropicGenerateWithArrayUnionNil() returns error? {
    AnthropicSquad[]? result = check anthropicProvider->generate(`Name 10 world class cricketers`);
    test:assertTrue(result is AnthropicSquad[]);
}

// A text chunk insertion is folded into a text block just like a text document.
@test:Config
function testAnthropicGenerateWithTextChunk() returns error? {
    ai:TextChunk chunk = {content: string `Title: ${blog1.title} Content: ${blog1.content}`};
    int maxScore = 10;
    int rating = check anthropicProvider->generate(
        `How would you rate this text chunk content out of ${maxScore}. ${chunk}.`);
    test:assertEquals(rating, 4);
}

// A document array insertion becomes one block per document.
@test:Config
function testAnthropicGenerateWithTextDocumentArray() returns error? {
    ai:TextDocument blog = {content: string `Title: ${blog1.title} Content: ${blog1.content}`};
    int maxScore = 10;
    Review expected = check review.fromJsonStringWithType(Review);
    AnthropicReviewArray result = check anthropicProvider->generate(
        `How would you rate these text blogs out of ${maxScore}. ${<ai:TextDocument[]>[blog, blog]}. Thank you!`);
    test:assertEquals(result, [expected, expected]);
}

// An image URL that is not a valid URL must fail before the call.
@test:Config
function testAnthropicGenerateWithInvalidImageUrl() {
    ai:ImageDocument image = {content: "This-is-not-a-valid-url"};
    string|ai:Error result = anthropicProvider->generate(`Please describe the image. ${image}.`);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Must be a valid URL"),
            "unexpected error: " + (<ai:Error>result).message());
}

// ===== generate(): direct calls into the module function =====
// These cover the branches the native dispatch hides from Ballerina code coverage.

final http:Client anthropicRawClient = check new (ANTHROPIC_SERVICE_URL, toRawHttpConfig({}));
final http:Client anthropicUnreachableRawClient = check new ("http://localhost:8099/nowhere",
    toRawHttpConfig({}));

// A prompt whose schema and content the mock recognises ("Rate this blog" -> integer result 4).
function anthropicRatePrompt() returns ai:Prompt => `Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`;

@test:Config
function testGenerateAnthropicLlmResponseHappyPath() returns error? {
    anydata result = check generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, DEFAULT_MAX_TOKEN_COUNT, (), (), (), anthropicRatePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateAnthropicLlmResponseWithAllParameters() returns error? {
    anydata result = check generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_EFFORT_DEPLOYMENT, 4096, 0.5d, {'type: "adaptive"}, "max", anthropicRatePrompt(), int);
    test:assertEquals(result, 4);
}

@test:Config
function testGenerateAnthropicLlmResponseConnectionFailure() {
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicUnreachableRawClient, API_KEY,
        DEFAULT_ANTHROPIC_VERSION, ANTHROPIC_DEPLOYMENT, 4096, (), (), (), anthropicRatePrompt(), int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("LLM call failed"));
}

@test:Config
function testGenerateAnthropicLlmResponseUnsupportedDocument() {
    ai:AudioDocument audio = {content: sampleBinaryData, metadata: {"format": "mp3"}};
    ai:Prompt prompt = `Describe ${audio}`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Audio documents are not supported"));
}

// The model answered with prose instead of calling the forced tool.
@test:Config
function testGenerateAnthropicLlmResponseWithoutToolUse() {
    ai:Prompt prompt = `TRIGGER_ANTHROPIC_NO_TOOL_USE produce something`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes(NO_RELEVANT_RESPONSE_FROM_THE_LLM));
}

// The forced tool was called with input that is not a JSON object.
@test:Config
function testGenerateAnthropicLlmResponseWithNonObjectToolInput() {
    ai:Prompt prompt = `TRIGGER_GEN_BAD_ARGS produce something`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes(NO_RELEVANT_RESPONSE_FROM_THE_LLM));
}

// The forced tool was called with a well-formed object of the wrong shape.
@test:Config
function testGenerateAnthropicLlmResponseWithTypeMismatch() {
    ai:Prompt prompt = `TRIGGER_GEN_TYPE_MISMATCH produce something`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Invalid value returned from the LLM Client"));
}

// A truncated response cannot carry a complete structured result, and the generic "no relevant response"
// message hides the actionable cause.
@test:Config
function testGenerateAnthropicLlmResponseWithTruncatedResponse() {
    ai:Prompt prompt = `TRIGGER_ANTHROPIC_TRUNCATED do work`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY,
        DEFAULT_ANTHROPIC_VERSION, ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("truncated"),
            "unexpected error: " + (<ai:Error>result).message());
    test:assertTrue((<ai:Error>result).message().includes("maxTokens"),
            "the error must name the parameter to raise: " + (<ai:Error>result).message());
}

@test:Config
function testGenerateAnthropicLlmResponseWithRefusal() {
    ai:Prompt prompt = `TRIGGER_ANTHROPIC_REFUSAL do work`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("declined to respond"));
}

@test:Config
function testGenerateAnthropicLlmResponseWithErrorEnvelope() {
    ai:Prompt prompt = `TRIGGER_ANTHROPIC_ERROR_ENVELOPE do work`;
    anydata|ai:Error result = generateAnthropicLlmResponse(anthropicRawClient, API_KEY, DEFAULT_ANTHROPIC_VERSION,
        ANTHROPIC_DEPLOYMENT, 4096, (), (), (), prompt, int);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("thinking.type.enabled is not supported"));
}
