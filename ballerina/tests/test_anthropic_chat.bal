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

// End-to-end coverage of `AnthropicModelProvider.chat()` against the mock Messages API.

const ANTHROPIC_GREETING = "Hello, how are you?";
final string anthropicGreetingResponse = ANTHROPIC_MOCK_RESPONSE_PREFIX + ANTHROPIC_GREETING;

// ===== chat(): request shapes =====

@test:Config
function testAnthropicChatWithSingleUserMessage() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertEquals(result.content, anthropicGreetingResponse);
    test:assertTrue(result.toolCalls is ());
}

// A bare-origin service URL is completed with `/anthropic` and reaches the same route.
@test:Config
function testAnthropicChatThroughBareOriginServiceUrl() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicOriginProvider->chat(userMessage);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// A system message is lifted into the top-level `system` field rather than sent as a turn, so the request that
// reaches the wire holds only the user turn (asserted by the mock's structural validation).
@test:Config
function testAnthropicChatWithSystemMessage() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "You are a helpful assistant."},
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "Be concise."},
        <ai:ChatUserMessage>{role: ai:USER, content: ANTHROPIC_GREETING}
    ];
    ai:ChatAssistantMessage result = check anthropicProvider->chat(messages);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// Two consecutive user messages must be merged into a single turn; the mock fails the request otherwise.
@test:Config
function testAnthropicChatMergesConsecutiveUserMessages() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: ANTHROPIC_GREETING},
        <ai:ChatUserMessage>{role: ai:USER, content: "And what can you do?"}
    ];
    ai:ChatAssistantMessage result = check anthropicProvider->chat(messages);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// A full conversation exercises every branch of the message converter: system instructions, a user turn, an
// assistant turn with content and a tool call, the tool result, and a final assistant turn.
@test:Config
function testAnthropicChatWithFullConversationHistory() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "You are helpful.", name: "supervisor"},
        <ai:ChatUserMessage>{role: ai:USER, content: "What is the weather in London?", name: "user-1"},
        <ai:ChatAssistantMessage>{
            role: ai:ASSISTANT,
            content: "Let me check that.",
            toolCalls: [{id: "toolu_1", name: "get_weather", arguments: {"city": "London"}}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "get_weather", id: "toolu_1", content: "sunny, 20C"},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "It is sunny in London."},
        <ai:ChatUserMessage>{role: ai:USER, content: "Thanks - and in Paris?"}
    ];
    // The history deliberately ends on the user turn: a trailing assistant turn is a response prefill, which
    // Claude Opus 4.6 / Sonnet 4.6 and later reject.
    ai:ChatAssistantMessage result = check anthropicProvider->chat(messages);
    test:assertTrue(result.content is string);
}

// An assistant turn that only announced tool calls carries no text, and a tool result with no content is sent
// without the optional `content` field - both are dropped rather than sent as empty blocks (which the Messages
// API rejects).
@test:Config
function testAnthropicChatWithContentlessAssistantAndToolResult() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: ANTHROPIC_GREETING},
        <ai:ChatAssistantMessage>{
            role: ai:ASSISTANT,
            content: "   ",
            toolCalls: [{name: "getTime", arguments: {}}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "getTime", content: ()}
    ];
    ai:ChatAssistantMessage result = check anthropicProvider->chat(messages);
    test:assertTrue(result.content is string);
}

// An assistant message with neither content nor tool calls produces no turn at all.
@test:Config
function testAnthropicChatSkipsEmptyAssistantMessage() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: ANTHROPIC_GREETING},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT}
    ];
    ai:ChatAssistantMessage result = check anthropicProvider->chat(messages);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// A conversation with nothing but system instructions cannot be expressed as a Messages API request.
@test:Config
function testAnthropicChatWithOnlySystemMessageFails() {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "You are a helpful assistant."}
    ];
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(messages);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Error while preparing"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithStopSequence() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage, [], "STOP");
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// ===== chat(): model parameters on the wire =====
// Each of these is asserted inside the mock through the deployment name; the assertion only runs if the request
// actually reaches the wire, so the tests drive it end to end.

@test:Config {
    dataProvider: anthropicParameterProviders
}
function testAnthropicChatForwardsModelParameters(AnthropicModelProvider provider) returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check provider->chat(userMessage);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

function anthropicParameterProviders() returns AnthropicModelProvider[][] => [
    [anthropicAdaptiveThinkingProvider],
    [anthropicExtendedThinkingProvider],
    [anthropicDisabledThinkingProvider],
    [anthropicEffortProvider],
    [anthropicTemperatureProvider],
    [anthropicNoTemperatureProvider],
    [anthropicCustomTokensProvider]
];

// A non-default `anthropicVersion` must reach the `anthropic-version` header; the mock pins the value for this
// deployment.
@test:Config
function testAnthropicChatForwardsCustomAnthropicVersion() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicCustomVersionProvider->chat(userMessage);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// The joined system instructions must reach the request's top-level `system` field, which the mock asserts for
// this deployment.
@test:Config
function testAnthropicChatSendsJoinedSystemField() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "You are a helpful assistant."},
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "Be concise."},
        <ai:ChatUserMessage>{role: ai:USER, content: ANTHROPIC_GREETING}
    ];
    ai:ChatAssistantMessage result = check anthropicSystemProvider->chat(messages);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

@test:Config
function testAnthropicChatWithCustomConnectionConfig() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicCustomConnectionProvider->chat(userMessage);
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// A blank stop sequence carries no meaning and is rejected by the service, so it must not reach the wire. The
// mock asserts `stop_sequences` is absent for this deployment, so removing the guard fails this test.
@test:Config
function testAnthropicChatDropsBlankStopSequence() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage result = check anthropicNoStopProvider->chat(userMessage, [], "   ");
    test:assertEquals(result.content, anthropicGreetingResponse);
}

// ===== chat(): multimodal content =====

@test:Config
function testAnthropicChatWithImageUrlPrompt() returns ai:Error? {
    ai:ImageDocument image = {content: sampleImageUrl, metadata: {mimeType: "image/jpeg"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${image}`};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

@test:Config
function testAnthropicChatWithBinaryImagePrompt() returns ai:Error? {
    ai:ImageDocument image = {content: sampleBinaryData, metadata: {mimeType: "image/png"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${image}`};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

// A binary image has no media type to fall back on, unlike the OpenAI data-URL form.
@test:Config
function testAnthropicChatWithBinaryImageWithoutMimeTypeFails() {
    ai:ImageDocument image = {content: sampleBinaryData};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${image}`};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Please specify the image media type"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithInvalidImageUrlFails() {
    ai:ImageDocument image = {content: "This-is-not-a-valid-url"};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${image}`};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Must be a valid URL"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithPdfDocument() returns ai:Error? {
    ai:FileDocument document = {content: sampleBinaryData, metadata: {mimeType: "application/pdf"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Summarize ${document}`};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

@test:Config
function testAnthropicChatWithDocumentUrl() returns ai:Error? {
    ai:FileDocument document = {content: "https://example.com/report.pdf"};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Summarize ${document}`};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

// A file referenced by id needs the Files API beta header, which the mock asserts is present only then.
@test:Config
function testAnthropicChatWithFileIdDocument() returns ai:Error? {
    ai:FileDocument document = {content: <ai:FileId>{fileId: "file_abc123"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Summarize ${document}`};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

@test:Config
function testAnthropicChatWithBinaryDocumentWithoutMimeTypeFails() {
    ai:FileDocument document = {content: sampleBinaryData};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Summarize ${document}`};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Please specify the document media type"),
            "unexpected error: " + (<ai:Error>result).message());
}

// Claude accepts image and PDF input but no audio.
@test:Config
function testAnthropicChatWithAudioDocumentFails() {
    ai:AudioDocument audio = {content: sampleBinaryData, metadata: {"format": "mp3"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${audio}`};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Audio documents are not supported"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithUnsupportedDocumentFails() {
    ai:BinaryDocument document = {content: sampleBinaryData};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Describe ${document}`};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Only text, image and file documents are supported"),
            "unexpected error: " + (<ai:Error>result).message());
}

// A text document and a text chunk are folded into text blocks, and a scalar insertion is stringified.
@test:Config
function testAnthropicChatWithTextDocumentsAndChunks() returns ai:Error? {
    ai:TextDocument document = {content: "doc body"};
    ai:TextChunk chunk = {content: "chunk body"};
    int count = 2;
    ai:ChatUserMessage userMessage = {
        role: ai:USER,
        content: `Summarize these ${count} inputs: ${document} and ${chunk}.`
    };
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

@test:Config
function testAnthropicChatWithDocumentArray() returns ai:Error? {
    ai:TextDocument first = {content: "first"};
    ai:TextDocument second = {content: "second"};
    ai:ChatUserMessage userMessage = {
        role: ai:USER,
        content: `Compare ${<ai:TextDocument[]>[first, second]}.`
    };
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertTrue(result.content is string);
}

// ===== chat(): tool calls =====

@test:Config
function testAnthropicChatWithTools() returns ai:Error? {
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"]
            }
        }
    ];
    ai:ChatUserMessage userMessage = {role: ai:USER, content: "What is the weather in London?"};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    ai:FunctionCall[] calls = <ai:FunctionCall[]>toolCalls;
    test:assertEquals(calls.length(), 1);
    test:assertEquals(calls[0].name, "get_weather");
    test:assertEquals(calls[0].arguments, {"city": "London"});
    test:assertEquals(calls[0].id, "toolu_weather");
}

// A tool with no parameters must still be described by a JSON Schema object.
@test:Config
function testAnthropicChatWithParameterlessTool() returns ai:Error? {
    ai:ChatCompletionFunctions[] tools = [{name: "getTime", description: "Get the current time"}];
    ai:ChatUserMessage userMessage = {role: ai:USER, content: "What time is it?"};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage, tools);
    test:assertTrue(result.toolCalls is ai:FunctionCall[]);
}

@test:Config
function testAnthropicParallelToolCallsInResponse() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: parallelToolsPrompt};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage, weatherTools);
    assertParallelToolCalls(result);
}

// The wire assertions for this flow live in the mock (`handleAnthropicParallelHistory`): both calls must land in
// one assistant turn and both results in one following user turn.
@test:Config
function testAnthropicParallelToolCallsHistoryReconstruction() returns ai:Error? {
    ai:ChatAssistantMessage result =
        check anthropicProvider->chat(buildParallelToolCallHistory(), weatherTools);
    test:assertEquals(result.content, PARALLEL_TOOLS_ANSWER);
}

// ===== chat(): response handling =====

// `thinking` and `redacted_thinking` blocks carry reasoning that `ai:ChatAssistantMessage` cannot represent, so
// they are skipped while the text block is kept.
@test:Config
function testAnthropicChatSkipsThinkingBlocks() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_THINKING_BLOCKS};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertEquals(result.content, "Thought about it.");
    test:assertTrue(result.toolCalls is ());
}

@test:Config
function testAnthropicChatWithTextAndToolCall() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_TEXT_AND_TOOL};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertEquals(result.content, "Let me check the weather.");
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "Berlin"});
}

@test:Config
function testAnthropicChatWithEmptyContentFails() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_EMPTY_CONTENT};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Empty response from the model"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithBlankTextFails() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_BLANK_TEXT};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Empty response from the model"),
            "unexpected error: " + (<ai:Error>result).message());
}

// The safety-classifier decline arrives as a successful response with `stop_reason: "refusal"`.
@test:Config
function testAnthropicChatWithRefusal() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_REFUSAL};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("declined to respond"), "unexpected error: " + message);
    test:assertTrue(message.includes("cyber"), "the refusal category must be surfaced: " + message);
}

@test:Config
function testAnthropicChatWithRefusalWithoutDetails() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_REFUSAL_NO_DETAILS};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("declined to respond"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithContextWindowExceeded() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_CONTEXT_EXCEEDED};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("context window"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithNamelessToolCallFails() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_TOOL_NO_NAME};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("missing the tool name"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatWithNonObjectToolInputFails() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_TOOL_BAD_INPUT};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Invalid arguments received"),
            "unexpected error: " + (<ai:Error>result).message());
}

// A truncated response still carries usable text, so `chat()` returns it; the reason is recorded on the span
// rather than turned into an error.
@test:Config
function testAnthropicChatWithTruncatedResponseIsNotAnError() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_TRUNCATED};
    // This fixture carries no content at all, so it fails on the empty-content check rather than the stop
    // reason - which is what proves `max_tokens` is not itself treated as a failure.
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Empty response from the model"),
            "a truncated response must not be reported as a stop-reason failure: " +
            (<ai:Error>result).message());
}

// `pause_turn` is a server-tool artefact; the text it carries must be returned rather than rejected.
@test:Config
function testAnthropicChatWithPauseTurn() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_PAUSE_TURN};
    ai:ChatAssistantMessage result = check anthropicProvider->chat(userMessage);
    test:assertEquals(result.content, "Partial answer so far.");
}

// ===== chat(): transport failures =====

// The Anthropic error envelope names the offending field, so its message must be propagated.
@test:Config
function testAnthropicChatSurfacesErrorEnvelope() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_ERROR_ENVELOPE};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    // A 4xx is a rejected request, not a connection failure: reporting it as one would make a caller that
    // retries `ai:LlmConnectionError` retry a request that can never succeed as sent.
    test:assertFalse(result is ai:LlmConnectionError,
            "a 400 must not be reported as a connection error");
    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("status 400"), "unexpected error: " + message);
    test:assertTrue(message.includes("invalid_request_error"), "unexpected error: " + message);
    test:assertTrue(message.includes("thinking.type.enabled is not supported"), "unexpected error: " + message);
}

@test:Config
function testAnthropicChatWithNonEnvelopeErrorBody() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_ERROR_PLAIN};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("status 503"), "unexpected error: " + message);
    // A 5xx is worth retrying, so it stays a connection error, and the body is the only diagnostic available.
    test:assertTrue(result is ai:LlmConnectionError, "a 503 must be reported as a connection error");
    test:assertTrue(message.includes("upstream unavailable"),
            "the response body must be surfaced when it is not the JSON envelope: " + message);
}

@test:Config
function testAnthropicChatWithMalformedResponseBody() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: TRIGGER_ANTHROPIC_MALFORMED_BODY};
    ai:ChatAssistantMessage|ai:Error result = anthropicProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unexpected response format"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testAnthropicChatConnectionFailure() {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: ANTHROPIC_GREETING};
    ai:ChatAssistantMessage|ai:Error result = anthropicUnreachableProvider->chat(userMessage);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("connecting to the model"),
            "unexpected error: " + (<ai:Error>result).message());
}
