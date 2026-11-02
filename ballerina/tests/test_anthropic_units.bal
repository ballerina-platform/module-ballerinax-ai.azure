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

// Unit tests for the Azure Anthropic helpers. These pin the conversion, validation and normalization rules
// directly (no HTTP), complementing the end-to-end tests.

// ===== resolveAnthropicBase =====

@test:Config
function testResolveAnthropicBaseCompletesBareOrigin() {
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com"),
            "https://my-resource.services.ai.azure.com/anthropic",
            "a bare Azure resource origin must be completed with '/anthropic'");
    test:assertEquals(resolveAnthropicBase("http://localhost:8080"), "http://localhost:8080/anthropic",
            "a bare origin with a port must be completed with '/anthropic'");
}

@test:Config
function testResolveAnthropicBaseKeepsDocumentedBaseUrl() {
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com/anthropic"),
            "https://my-resource.services.ai.azure.com/anthropic",
            "the documented base URL must be left unchanged");
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com/anthropic/"),
            "https://my-resource.services.ai.azure.com/anthropic",
            "a single trailing slash must be trimmed");
}

// The deployment details show the full target URI, so accept it and strip the route.
@test:Config
function testResolveAnthropicBaseTrimsTargetUriSuffix() {
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com/anthropic/v1/messages"),
            "https://my-resource.services.ai.azure.com/anthropic",
            "the '/v1/messages' route must be trimmed off the base URL");
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com/anthropic/v1/messages/"),
            "https://my-resource.services.ai.azure.com/anthropic");
    test:assertEquals(resolveAnthropicBase("https://my-resource.services.ai.azure.com/anthropic/v1"),
            "https://my-resource.services.ai.azure.com/anthropic",
            "a '/v1' suffix must be trimmed off the base URL");
}

// Regression guard: a gateway/API Management base path must be used verbatim.
@test:Config
function testResolveAnthropicBaseKeepsCallerOwnedPathVerbatim() {
    test:assertEquals(resolveAnthropicBase("https://gw.example.com/claude"),
            "https://gw.example.com/claude",
            "a gateway base path must be used verbatim");
    test:assertEquals(resolveAnthropicBase("http://localhost:8080/llm/azureanthropic/anthropic"),
            "http://localhost:8080/llm/azureanthropic/anthropic",
            "a multi-segment base path must be used verbatim");
}

// ===== validateThinking =====

@test:Config
function testValidateThinkingAcceptsValidConfigurations() {
    test:assertTrue(validateThinking((), 4096, ()) is ());
    test:assertTrue(validateThinking({'type: "adaptive"}, 4096, ()) is ());
    test:assertTrue(validateThinking({'type: "adaptive", display: "omitted"}, 4096, ()) is ());
    test:assertTrue(validateThinking({'type: "disabled"}, 4096, ()) is ());
    test:assertTrue(validateThinking({'type: "enabled", budgetTokens: 1024}, 4096, ()) is ());
}

@test:Config
function testValidateThinkingRequiresBudgetForExtendedThinking() {
    ai:Error? result = validateThinking({'type: "enabled"}, 4096, ());
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("'budgetTokens' field is required"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testValidateThinkingRejectsBudgetWithoutExtendedThinking() {
    ai:Error? adaptive = validateThinking({'type: "adaptive", budgetTokens: 2048}, 4096, ());
    test:assertTrue(adaptive is ai:Error);
    test:assertTrue((<ai:Error>adaptive).message().includes("only valid when the thinking type is"),
            "unexpected error: " + (<ai:Error>adaptive).message());
    test:assertTrue(validateThinking({'type: "disabled", budgetTokens: 2048}, 4096, ()) is ai:Error);
}

@test:Config
function testValidateThinkingRejectsTooSmallBudget() {
    ai:Error? result = validateThinking({'type: "enabled", budgetTokens: 1023}, 4096, ());
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("must be at least 1024"),
            "unexpected error: " + (<ai:Error>result).message());
}

// Thinking tokens count towards `max_tokens`, so the budget must leave room for the answer.
@test:Config
function testValidateThinkingRejectsBudgetAtOrAboveMaxTokens() {
    ai:Error? equal = validateThinking({'type: "enabled", budgetTokens: 4096}, 4096, ());
    test:assertTrue(equal is ai:Error);
    test:assertTrue((<ai:Error>equal).message().includes("must be less than 'maxTokens'"),
            "unexpected error: " + (<ai:Error>equal).message());
    test:assertTrue(validateThinking({'type: "enabled", budgetTokens: 8192}, 4096, ()) is ai:Error);
}

// The Messages API rejects a sampling temperature while thinking is on, so the pair is rejected at init.
@test:Config
function testValidateThinkingRejectsTemperatureWithThinkingOn() {
    ai:Error? adaptive = validateThinking({'type: "adaptive"}, 4096, 0.3d);
    test:assertTrue(adaptive is ai:Error);
    test:assertTrue((<ai:Error>adaptive).message().includes("cannot be combined with thinking"),
            "unexpected error: " + (<ai:Error>adaptive).message());
    test:assertTrue(validateThinking({'type: "enabled", budgetTokens: 2048}, 4096, 0.7d) is ai:Error);
}

// `disabled` thinking is the one mode a temperature may accompany.
@test:Config
function testValidateThinkingAllowsTemperatureWithThinkingOff() {
    test:assertTrue(validateThinking({'type: "disabled"}, 4096, 0.3d) is ());
    test:assertTrue(validateThinking((), 4096, 0.3d) is ());
}

// ===== toThinkingJson =====

@test:Config
function testToThinkingJsonUsesWireFieldNames() {
    test:assertEquals(toThinkingJson({'type: "adaptive"}), {"type": "adaptive"});
    test:assertEquals(toThinkingJson({'type: "adaptive", display: "summarized"}),
            {"type": "adaptive", "display": "summarized"});
    test:assertEquals(toThinkingJson({'type: "enabled", budgetTokens: 2048}),
            {"type": "enabled", "budget_tokens": 2048},
            "the budget must be sent as 'budget_tokens'");
    test:assertEquals(toThinkingJson({'type: "disabled"}), {"type": "disabled"});
}

// ===== thinkingForForcedToolUse =====

@test:Config
function testThinkingForForcedToolUseDropsExtendedThinking() {
    Thinking? result = thinkingForForcedToolUse({'type: "enabled", budgetTokens: 2048});
    test:assertTrue(result is (),
            "manual extended thinking is not supported with a forced tool choice and must be dropped");
}

@test:Config
function testThinkingForForcedToolUseKeepsOtherModes() {
    test:assertEquals(thinkingForForcedToolUse({'type: "adaptive"}), {'type: "adaptive"});
    test:assertEquals(thinkingForForcedToolUse({'type: "disabled"}), {'type: "disabled"});
    test:assertTrue(thinkingForForcedToolUse(()) is ());
}

// ===== convertToAnthropicMessages =====

@test:Config
function testConvertToAnthropicMessagesWithSingleUserMessage() returns ai:Error? {
    ai:ChatUserMessage userMessage = {role: ai:USER, content: "hello"};
    AnthropicRequestParts parts = check convertToAnthropicMessages(userMessage);
    test:assertEquals(parts.messages.length(), 1);
    test:assertEquals(parts.messages[0].role, "user");
    test:assertEquals(parts.messages[0].content, [<AnthropicTextBlock>{text: "hello"}]);
    test:assertTrue(parts.system is ());
    test:assertFalse(parts.usesFileSource);
}

@test:Config
function testConvertToAnthropicMessagesJoinsSystemMessages() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "You are helpful."},
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: "Be concise."},
        <ai:ChatUserMessage>{role: ai:USER, content: "Hi"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 1, "only the user message becomes a turn");
    test:assertEquals(parts.system, "You are helpful.\n\nBe concise.");
}

// A system message whose content is a prompt is flattened to text.
@test:Config
function testConvertToAnthropicMessagesWithPromptSystemMessage() returns ai:Error? {
    ai:TextDocument policy = {content: "be brief"};
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: ai:SYSTEM, content: `Follow: ${policy}`},
        <ai:ChatUserMessage>{role: ai:USER, content: "Hi"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.system, "Follow: be brief");
}

@test:Config
function testConvertToAnthropicMessagesMergesSameRoleTurns() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "first"},
        <ai:ChatUserMessage>{role: ai:USER, content: "second"},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "reply one"},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "reply two"},
        <ai:ChatUserMessage>{role: ai:USER, content: "third"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 3, "consecutive same-role messages must be merged");
    test:assertEquals(parts.messages[0].content.length(), 2);
    test:assertEquals(parts.messages[1].content.length(), 2);
    test:assertEquals(parts.messages[2].content.length(), 1);
}

// Both calls of a parallel turn land in one assistant turn, and both results in the following user turn.
@test:Config
function testConvertToAnthropicMessagesGroupsParallelToolCalls() returns ai:Error? {
    AnthropicRequestParts parts = check convertToAnthropicMessages(buildParallelToolCallHistory());
    test:assertEquals(parts.messages.length(), 3);

    AnthropicMessage assistantTurn = parts.messages[1];
    test:assertEquals(assistantTurn.role, "assistant");
    test:assertEquals(assistantTurn.content.length(), 2);
    AnthropicToolUseBlock firstCall = <AnthropicToolUseBlock>assistantTurn.content[0];
    AnthropicToolUseBlock secondCall = <AnthropicToolUseBlock>assistantTurn.content[1];
    test:assertEquals(firstCall.id, PARIS_CALL_ID);
    test:assertEquals(secondCall.id, TOKYO_CALL_ID);
    test:assertEquals(firstCall.input, {"city": "Paris"});

    AnthropicMessage resultTurn = parts.messages[2];
    test:assertEquals(resultTurn.role, "user");
    test:assertEquals(resultTurn.content.length(), 2);
    AnthropicToolResultBlock firstResult = <AnthropicToolResultBlock>resultTurn.content[0];
    AnthropicToolResultBlock secondResult = <AnthropicToolResultBlock>resultTurn.content[1];
    test:assertEquals(firstResult.tool_use_id, PARIS_CALL_ID);
    test:assertEquals(secondResult.tool_use_id, TOKYO_CALL_ID);
    test:assertEquals(firstResult.content, "Sunny, 25°C");
}

// When a tool call carries no id, the synthesized ids must stay distinct per call and pair with their results.
@test:Config
function testConvertToAnthropicMessagesSynthesizesDistinctToolCallIds() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "Weather in Paris and Tokyo?"},
        <ai:ChatAssistantMessage>{
            role: ai:ASSISTANT,
            toolCalls: [
                {name: "getWeather", arguments: {"city": "Paris"}},
                {name: "getWeather", arguments: {"city": "Tokyo"}}
            ]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "getWeather", content: "sunny"},
        <ai:ChatFunctionMessage>{role: "function", name: "getWeather", content: "rainy"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 3);

    AnthropicToolUseBlock firstCall = <AnthropicToolUseBlock>parts.messages[1].content[0];
    AnthropicToolUseBlock secondCall = <AnthropicToolUseBlock>parts.messages[1].content[1];
    // Synthesized ids use the `toolu_` prefix the Messages API issues itself.
    test:assertEquals(firstCall.id, "toolu_getWeather_1");
    test:assertEquals(secondCall.id, "toolu_getWeather_2");
    test:assertNotEquals(firstCall.id, secondCall.id);

    AnthropicToolResultBlock firstResult = <AnthropicToolResultBlock>parts.messages[2].content[0];
    AnthropicToolResultBlock secondResult = <AnthropicToolResultBlock>parts.messages[2].content[1];
    test:assertEquals(firstResult.tool_use_id, firstCall.id);
    test:assertEquals(secondResult.tool_use_id, secondCall.id);
}

// Blank text must never reach the wire: the Messages API rejects empty text blocks.
@test:Config
function testConvertToAnthropicMessagesDropsBlankContent() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "hi"},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "  "},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "real answer"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 2);
    test:assertEquals(parts.messages[1].content.length(), 1);
}

// Regression guard: a tool result that merges into a user turn built from a prompt must not fail. The prompt
// blocks are copied into a content-block array rather than cast, so appending a `tool_result` block is legal.
@test:Config
function testConvertToAnthropicMessagesMergesToolResultIntoPromptUserTurn() returns ai:Error? {
    ai:ImageDocument image = {content: sampleImageUrl};
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: `Look at ${image}`},
        <ai:ChatFunctionMessage>{role: "function", name: "noop", id: "toolu_1", content: "done"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 1, "the tool result merges into the preceding user turn");
    // `normalizeToolResultOrder` moves the tool result ahead of the prompt content.
    test:assertTrue(parts.messages[0].content[0] is AnthropicToolResultBlock);
    test:assertEquals(parts.messages[0].content.length(), 3);
}

// The same merge through a plain-string user turn.
@test:Config
function testConvertToAnthropicMessagesMergesToolResultIntoTextUserTurn() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "plain text"},
        <ai:ChatFunctionMessage>{role: "function", name: "noop", id: "toolu_1", content: "done"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 1);
    test:assertEquals(parts.messages[0].content.length(), 2);
}

// A tool result with no content omits the optional `content` field rather than sending an empty string.
@test:Config
function testConvertToAnthropicMessagesOmitsEmptyToolResultContent() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "hi"},
        <ai:ChatAssistantMessage>{
            role: ai:ASSISTANT,
            toolCalls: [{id: "toolu_1", name: "noop", arguments: ()}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "noop", id: "toolu_1", content: ""}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    AnthropicToolResultBlock result = <AnthropicToolResultBlock>parts.messages[2].content[0];
    test:assertTrue(result?.content is (), "an empty tool result must omit the 'content' field");
    AnthropicToolUseBlock call = <AnthropicToolUseBlock>parts.messages[1].content[0];
    test:assertEquals(call.input, {}, "a tool call with no arguments must send an empty object");
}

@test:Config
function testConvertToAnthropicMessagesFailsForSystemOnlyConversation() {
    ai:ChatMessage[] messages = [<ai:ChatSystemMessage>{role: ai:SYSTEM, content: "instructions only"}];
    AnthropicRequestParts|ai:Error result = convertToAnthropicMessages(messages);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("At least one user or assistant message"),
            "unexpected error: " + (<ai:Error>result).message());
}

@test:Config
function testConvertToAnthropicMessagesFlagsFileSource() returns ai:Error? {
    ai:FileDocument document = {content: <ai:FileId>{fileId: "file_1"}};
    ai:ChatUserMessage userMessage = {role: ai:USER, content: `Summarize ${document}`};
    AnthropicRequestParts parts = check convertToAnthropicMessages(userMessage);
    test:assertTrue(parts.usesFileSource, "a file-id document source requires the Files API beta header");
}

// A history ending on an assistant turn is converted as-is, which the Messages API reads as a response prefill.
// It is kept rather than dropped because prefilling is a legitimate feature on the models that still allow it
// (Claude Opus 4.6 / Sonnet 4.6 and later reject it, and the service error says so).
@test:Config
function testConvertToAnthropicMessagesKeepsTrailingAssistantTurnAsPrefill() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: ai:USER, content: "Complete this: the capital of France is"},
        <ai:ChatAssistantMessage>{role: ai:ASSISTANT, content: "The capital of France is"}
    ];
    AnthropicRequestParts parts = check convertToAnthropicMessages(messages);
    test:assertEquals(parts.messages.length(), 2);
    test:assertEquals(parts.messages[1].role, "assistant");
}

// ===== normalizeToolResultOrder =====

// The Messages API requires the tool results of the preceding assistant turn to lead the user turn that answers
// it, so a history whose messages arrive out of order is reordered.
@test:Config
function testNormalizeToolResultOrderMovesToolResultsFirst() {
    AnthropicMessage[] messages = [
        {
            role: "user",
            content: [
                <AnthropicTextBlock>{text: "and also this"},
                <AnthropicToolResultBlock>{tool_use_id: "toolu_1", content: "result"}
            ]
        }
    ];
    normalizeToolResultOrder(messages);
    test:assertTrue(messages[0].content[0] is AnthropicToolResultBlock);
    test:assertTrue(messages[0].content[1] is AnthropicTextBlock);
}

@test:Config
function testNormalizeToolResultOrderLeavesOtherTurnsUnchanged() {
    AnthropicMessage[] messages = [
        {role: "user", content: [<AnthropicTextBlock>{text: "only text"}]},
        {
            role: "assistant",
            content: [<AnthropicToolUseBlock>{id: "toolu_1", name: "noop", input: {}}]
        }
    ];
    normalizeToolResultOrder(messages);
    test:assertTrue(messages[0].content[0] is AnthropicTextBlock);
    test:assertTrue(messages[1].content[0] is AnthropicToolUseBlock);
}

// ===== generateAnthropicContent =====

@test:Config
function testGenerateAnthropicContentInterleavesTextAndDocuments() returns ai:Error? {
    ai:TextDocument document = {content: "doc body"};
    ai:ImageDocument image = {content: sampleImageUrl};
    AnthropicPromptBlock[] blocks = check generateAnthropicContent(`Read ${document} then ${image}.`);
    test:assertEquals(blocks.length(), 5);
    test:assertEquals(blocks[0], <AnthropicTextBlock>{text: "Read "});
    test:assertEquals(blocks[1], <AnthropicTextBlock>{text: "doc body"});
    test:assertEquals(blocks[2], <AnthropicTextBlock>{text: " then "});
    test:assertEquals(blocks[3], <AnthropicImageBlock>{'source: {url: sampleImageUrl}});
    test:assertEquals(blocks[4], <AnthropicTextBlock>{text: "."});
}

// Adjacent insertions produce blank literal text, which must not become an (illegal) empty text block.
@test:Config
function testGenerateAnthropicContentDropsBlankLiterals() returns ai:Error? {
    ai:ImageDocument first = {content: sampleImageUrl};
    ai:ImageDocument second = {content: sampleImageUrl};
    AnthropicPromptBlock[] blocks = check generateAnthropicContent(`${first}${second}`);
    test:assertEquals(blocks.length(), 2);
    test:assertTrue(blocks[0] is AnthropicImageBlock);
    test:assertTrue(blocks[1] is AnthropicImageBlock);
}

@test:Config
function testGenerateAnthropicContentWithDocumentArray() returns ai:Error? {
    ai:TextChunk first = {content: "c1"};
    ai:TextChunk second = {content: "c2"};
    AnthropicPromptBlock[] blocks = check generateAnthropicContent(
        `Chunks: ${<ai:TextChunk[]>[first, second]} done`);
    test:assertEquals(blocks.length(), 4);
    test:assertEquals(blocks[1], <AnthropicTextBlock>{text: "c1"});
    test:assertEquals(blocks[2], <AnthropicTextBlock>{text: "c2"});
}

@test:Config
function testGenerateAnthropicContentWithScalarInsertion() returns ai:Error? {
    int count = 42;
    AnthropicPromptBlock[] blocks = check generateAnthropicContent(`Count is ${count}.`);
    test:assertEquals(blocks, [<AnthropicTextBlock>{text: "Count is 42."}]);
}

// A text document with no content adds no block.
@test:Config
function testGenerateAnthropicContentWithEmptyTextDocument() returns ai:Error? {
    ai:TextDocument document = {content: ""};
    AnthropicPromptBlock[] blocks = check generateAnthropicContent(`${document}`);
    test:assertEquals(blocks.length(), 0);
}

// ===== buildAnthropicUserContent =====

@test:Config
function testBuildAnthropicUserContentWithPlainString() returns ai:Error? {
    AnthropicPromptBlock[] blocks = check buildAnthropicUserContent("plain text");
    test:assertEquals(blocks, [<AnthropicTextBlock>{text: "plain text"}]);
}

@test:Config
function testBuildAnthropicUserContentWithBlankString() returns ai:Error? {
    AnthropicPromptBlock[] blocks = check buildAnthropicUserContent("   ");
    test:assertEquals(blocks.length(), 0, "a blank message must not produce an empty text block");
}

// ===== document blocks =====

@test:Config
function testBuildAnthropicDocumentBlockVariants() returns ai:Error? {
    AnthropicDocumentBlock urlBlock =
        check buildAnthropicDocumentBlock({content: "https://example.com/a.pdf"});
    test:assertEquals(urlBlock, <AnthropicDocumentBlock>{'source: {url: "https://example.com/a.pdf"}});

    AnthropicDocumentBlock fileBlock =
        check buildAnthropicDocumentBlock({content: <ai:FileId>{fileId: "file_9"}});
    test:assertEquals(fileBlock, <AnthropicDocumentBlock>{'source: {file_id: "file_9"}});

    AnthropicDocumentBlock base64Block = check buildAnthropicDocumentBlock({
        content: sampleBinaryData,
        metadata: {mimeType: "application/pdf"}
    });
    test:assertEquals(base64Block, <AnthropicDocumentBlock>{
        'source: {media_type: "application/pdf", data: sampleBinaryStr}
    });
}

@test:Config
function testBuildAnthropicImageBlockVariants() returns ai:Error? {
    AnthropicImageBlock urlBlock = check buildAnthropicImageBlock({content: sampleImageUrl});
    test:assertEquals(urlBlock, <AnthropicImageBlock>{'source: {url: sampleImageUrl}});

    AnthropicImageBlock base64Block = check buildAnthropicImageBlock({
        content: sampleBinaryData,
        metadata: {mimeType: "image/png"}
    });
    test:assertEquals(base64Block, <AnthropicImageBlock>{
        'source: {media_type: "image/png", data: sampleBinaryStr}
    });
}

// ===== convertToAnthropicTools =====

@test:Config
function testConvertToAnthropicTools() {
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "weather",
            parameters: {"type": "object", "properties": {"city": {"type": "string"}}}
        },
        {name: "no_params", description: "a tool with no parameters"}
    ];
    AnthropicTool[] result = convertToAnthropicTools(tools);
    test:assertEquals(result.length(), 2);
    test:assertEquals(result[0].name, "get_weather");
    test:assertEquals(result[0].input_schema, {"type": "object", "properties": {"city": {"type": "string"}}});
    test:assertEquals(result[1].input_schema, {"type": "object", "properties": {}},
            "a parameterless tool must still describe an object schema");
}

@test:Config
function testGetAnthropicGetResultsTool() {
    AnthropicTool[] tools = getAnthropicGetResultsTool({"type": "object", "properties": {}});
    test:assertEquals(tools.length(), 1);
    test:assertEquals(tools[0].name, GET_RESULTS_TOOL);
    test:assertTrue(tools[0]?.description is string);
}

// ===== buildAnthropicRequest =====

@test:Config
function testBuildAnthropicRequestOmitsUnsetFields() {
    AnthropicRequestParts parts = {
        messages: [{role: "user", content: [<AnthropicTextBlock>{text: "hi"}]}],
        system: (),
        usesFileSource: false
    };
    map<json> request = buildAnthropicRequest("claude-opus-5", 512, (), (), (), parts, (), (), ());
    test:assertEquals(request["model"], "claude-opus-5");
    test:assertEquals(request["max_tokens"], 512);
    test:assertFalse(request.hasKey("system"));
    test:assertFalse(request.hasKey("temperature"),
            "temperature must be omitted when unset: the newer Claude models reject it");
    test:assertFalse(request.hasKey("thinking"));
    test:assertFalse(request.hasKey("output_config"));
    test:assertFalse(request.hasKey("stop_sequences"));
    test:assertFalse(request.hasKey("tools"));
    test:assertFalse(request.hasKey("tool_choice"));
}

@test:Config
function testBuildAnthropicRequestCarriesEveryConfiguredField() {
    AnthropicRequestParts parts = {
        messages: [{role: "user", content: [<AnthropicTextBlock>{text: "hi"}]}],
        system: "be brief",
        usesFileSource: false
    };
    AnthropicTool[] tools = [{name: "getResults", input_schema: {"type": "object"}}];
    map<json> request = buildAnthropicRequest("claude-sonnet-4-6", 1024, 0.7d,
            {'type: "enabled", budgetTokens: 512}, "medium", parts, tools,
            {'type: "tool", name: "getResults"}, "STOP");
    test:assertEquals(request["system"], "be brief");
    test:assertEquals(request["temperature"], 0.7d);
    test:assertEquals(request["thinking"], {"type": "enabled", "budget_tokens": 512});
    test:assertEquals(request["output_config"], {"effort": "medium"});
    test:assertEquals(request["stop_sequences"], ["STOP"]);
    test:assertEquals(request["tool_choice"], {"type": "tool", "name": "getResults"});
    test:assertTrue(request["tools"] is json[]);
}

// A blank stop sequence is dropped rather than sent as an empty `stop_sequences` entry.
@test:Config
function testBuildAnthropicRequestDropsBlankStopSequence() {
    AnthropicRequestParts parts = {
        messages: [{role: "user", content: [<AnthropicTextBlock>{text: "hi"}]}],
        system: (),
        usesFileSource: false
    };
    map<json> blank = buildAnthropicRequest("claude-opus-5", 512, (), (), (), parts, (), (), "   ");
    test:assertFalse(blank.hasKey("stop_sequences"));
    map<json> real = buildAnthropicRequest("claude-opus-5", 512, (), (), (), parts, (), (), "STOP");
    test:assertEquals(real["stop_sequences"], ["STOP"]);
}

// An empty tool list must not put `tools` (or a tool choice) on the wire.
@test:Config
function testBuildAnthropicRequestIgnoresEmptyToolList() {
    AnthropicRequestParts parts = {
        messages: [{role: "user", content: [<AnthropicTextBlock>{text: "hi"}]}],
        system: (),
        usesFileSource: false
    };
    map<json> request = buildAnthropicRequest("claude-opus-5", 512, (), (), (), parts, [],
            {'type: "auto"}, ());
    test:assertFalse(request.hasKey("tools"));
    test:assertFalse(request.hasKey("tool_choice"));
}

// ===== response conversion =====

@test:Config
function testConvertAnthropicResponseConcatenatesTextBlocks() returns ai:Error? {
    AnthropicMessagesResponse response = {
        id: "msg_1",
        content: [
            {'type: "text", text: "Hello "},
            {'type: "thinking", "thinking": "reasoning"},
            {'type: "text", text: "world"}
        ],
        stop_reason: "end_turn"
    };
    ai:ChatAssistantMessage message = check convertAnthropicResponseToAssistantMessage(response);
    test:assertEquals(message.content, "Hello world");
    test:assertTrue(message.toolCalls is ());
}

@test:Config
function testConvertAnthropicResponseReadsToolUseBlocks() returns ai:Error? {
    AnthropicMessagesResponse response = {
        id: "msg_2",
        content: [
            {'type: "tool_use", id: "toolu_1", name: "getWeather", input: {"city": "Paris"}},
            {'type: "tool_use", id: "toolu_2", name: "getWeather", input: {"city": "Tokyo"}}
        ],
        stop_reason: "tool_use"
    };
    ai:ChatAssistantMessage message = check convertAnthropicResponseToAssistantMessage(response);
    ai:FunctionCall[] calls = <ai:FunctionCall[]>message.toolCalls;
    test:assertEquals(calls.length(), 2);
    test:assertEquals(calls[0], {id: "toolu_1", name: "getWeather", arguments: {"city": "Paris"}});
    test:assertEquals(calls[1].id, "toolu_2");
}

// A tool call with no input is normalized to an empty argument map.
@test:Config
function testConvertAnthropicResponseWithMissingToolInput() returns ai:Error? {
    AnthropicMessagesResponse response = {
        content: [{'type: "tool_use", id: "toolu_1", name: "noop"}],
        stop_reason: "tool_use"
    };
    ai:ChatAssistantMessage message = check convertAnthropicResponseToAssistantMessage(response);
    ai:FunctionCall[] calls = <ai:FunctionCall[]>message.toolCalls;
    test:assertEquals(calls[0].arguments, {});
}

@test:Config
function testConvertAnthropicResponseFailsForEmptyContent() {
    AnthropicMessagesResponse response = {content: [], stop_reason: "end_turn"};
    ai:ChatAssistantMessage|ai:Error result = convertAnthropicResponseToAssistantMessage(response);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Empty response from the model"));
}

@test:Config
function testConvertAnthropicResponseIgnoresUnknownBlockTypes() {
    AnthropicMessagesResponse response = {
        content: [{'type: "server_tool_use", id: "srvtoolu_1", name: "web_search"}],
        stop_reason: "end_turn"
    };
    ai:ChatAssistantMessage|ai:Error result = convertAnthropicResponseToAssistantMessage(response);
    test:assertTrue(result is ai:Error, "a response with no text and no client tool call is unusable");
}

// ===== checkAnthropicStopReason =====

@test:Config
function testCheckAnthropicStopReasonAcceptsNormalCompletions() {
    test:assertTrue(checkAnthropicStopReason({content: [], stop_reason: "end_turn"}) is ());
    test:assertTrue(checkAnthropicStopReason({content: [], stop_reason: "tool_use"}) is ());
    test:assertTrue(checkAnthropicStopReason({content: [], stop_reason: "max_tokens"}) is ());
    test:assertTrue(checkAnthropicStopReason({content: [], stop_reason: "stop_sequence"}) is ());
    test:assertTrue(checkAnthropicStopReason({content: []}) is (), "an absent stop reason is not an error");
}

@test:Config
function testCheckAnthropicStopReasonRejectsRefusal() {
    ai:Error? withDetails = checkAnthropicStopReason({
        content: [],
        stop_reason: "refusal",
        stop_details: {'type: "refusal", category: "bio", explanation: "declined"}
    });
    test:assertTrue(withDetails is ai:Error);
    string message = (<ai:Error>withDetails).message();
    test:assertTrue(message.includes("category: bio"), "unexpected error: " + message);
    test:assertTrue(message.includes("declined"), "unexpected error: " + message);

    ai:Error? withoutDetails = checkAnthropicStopReason({content: [], stop_reason: "refusal"});
    test:assertTrue(withoutDetails is ai:Error);
    test:assertTrue((<ai:Error>withoutDetails).message().includes("declined to respond"));

    // A refusal whose details carry no category or explanation still fails, without a suffix.
    ai:Error? emptyDetails = checkAnthropicStopReason({
        content: [],
        stop_reason: "refusal",
        stop_details: {'type: "refusal"}
    });
    test:assertTrue(emptyDetails is ai:Error);
}

@test:Config
function testCheckAnthropicStopReasonRejectsContextWindowExceeded() {
    ai:Error? result = checkAnthropicStopReason({
        content: [],
        stop_reason: "model_context_window_exceeded"
    });
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("context window"));
}

// ===== buildAnthropicErrorMessage =====

@test:Config
function testBuildAnthropicErrorMessageSurfacesEnvelope() {
    string message = buildAnthropicErrorMessage(400, {
        'type: "error",
        'error: {'type: "invalid_request_error", message: "max_tokens is required"}
    });
    test:assertTrue(message.includes("status 400"), message);
    test:assertTrue(message.includes("invalid_request_error"), message);
    test:assertTrue(message.includes("max_tokens is required"), message);
}

@test:Config
function testBuildAnthropicErrorMessageWithoutErrorType() {
    string message = buildAnthropicErrorMessage(429, {'error: {message: "rate limited"}});
    test:assertTrue(message.includes("rate limited"), message);
}

// A body that is not the documented envelope is kept rather than discarded: it is the only diagnostic there is.
@test:Config
function testBuildAnthropicErrorMessageKeepsNonEnvelopeBody() {
    test:assertEquals(buildAnthropicErrorMessage(503, "upstream unavailable"),
            "Anthropic Messages API request failed with status 503: \"upstream unavailable\"");
    test:assertEquals(buildAnthropicErrorMessage(400, {'error: "not-an-object"}),
            "Anthropic Messages API request failed with status 400: {\"error\":\"not-an-object\"}");
    test:assertEquals(buildAnthropicErrorMessage(502, error("no json"), "<html>bad gateway</html>"),
            "Anthropic Messages API request failed with status 502: <html>bad gateway</html>");
}

@test:Config
function testBuildAnthropicErrorMessageFallsBackToStatus() {
    test:assertEquals(buildAnthropicErrorMessage(500, error("no payload")),
            "Anthropic Messages API request failed with status 500");
    test:assertEquals(buildAnthropicErrorMessage(500, error("no payload"), error("no text either")),
            "Anthropic Messages API request failed with status 500");
    test:assertEquals(buildAnthropicErrorMessage(500, ()),
            "Anthropic Messages API request failed with status 500");
}

// ===== findGetResultsArguments =====

@test:Config
function testFindGetResultsArguments() {
    AnthropicMessagesResponse response = {
        content: [
            {'type: "text", text: "here you go"},
            {'type: "tool_use", id: "toolu_1", name: GET_RESULTS_TOOL, input: {"result": 4}}
        ]
    };
    test:assertEquals(findGetResultsArguments(response), {"result": 4});
}

@test:Config
function testFindGetResultsArgumentsWithoutToolCall() {
    AnthropicMessagesResponse response = {content: [{'type: "text", text: "no tool call"}]};
    test:assertTrue(findGetResultsArguments(response) is ());
}

@test:Config
function testFindGetResultsArgumentsWithNonObjectInput() {
    AnthropicMessagesResponse response = {
        content: [{'type: "tool_use", id: "toolu_1", name: GET_RESULTS_TOOL, input: [1, 2]}]
    };
    test:assertTrue(findGetResultsArguments(response) is ());
}

// ===== init validation =====

@test:Config
function testAnthropicProviderRejectsNonPositiveMaxTokens() {
    AnthropicModelProvider|ai:Error provider =
        new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_DEPLOYMENT, maxTokens = 0);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("'maxTokens' argument must be a positive integer"),
            "unexpected error: " + (<ai:Error>provider).message());
}

// The `anthropic-version` header is required by the Messages API, so a blank value is rejected up front rather
// than sent as an empty header.
@test:Config
function testAnthropicProviderRejectsBlankAnthropicVersion() {
    AnthropicModelProvider|ai:Error provider = new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_DEPLOYMENT,
        anthropicVersion = "   ");
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("'anthropicVersion' argument must not be blank"),
            "unexpected error: " + (<ai:Error>provider).message());
}

@test:Config
function testAnthropicProviderRejectsInvalidThinking() {
    AnthropicModelProvider|ai:Error provider = new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_DEPLOYMENT,
        thinking = {'type: "enabled"});
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("'budgetTokens' field is required"),
            "unexpected error: " + (<ai:Error>provider).message());
}

@test:Config
function testAnthropicProviderInitFailsForMalformedServiceUrl() {
    AnthropicModelProvider|ai:Error provider = new ("http://invalid host/anthropic", API_KEY,
        ANTHROPIC_DEPLOYMENT);
    test:assertTrue(provider is ai:Error);
    test:assertTrue((<ai:Error>provider).message().includes("Failed to initialize"),
            "unexpected error: " + (<ai:Error>provider).message());
}
