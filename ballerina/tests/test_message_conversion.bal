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

// Unit tests for the message/content conversion helpers shared by the Chat Completions and Responses paths.
// These pin the conversion branches directly (no HTTP), complementing the end-to-end tests.

// ===== getChatMessageStringContent =====

@test:Config
function testGetChatMessageStringContentPlainString() returns error? {
    string result = check getChatMessageStringContent("plain text");
    test:assertEquals(result, "plain text");
}

@test:Config
function testGetChatMessageStringContentWithTextDocument() returns error? {
    ai:TextDocument doc = {content: "document body"};
    // Each insertion is joined as `content + " " + followingLiteral`, so the literal's leading space adds a
    // second space before "outro".
    string result = check getChatMessageStringContent(`Intro ${doc} outro`);
    test:assertEquals(result, "Intro document body  outro");
}

@test:Config
function testGetChatMessageStringContentWithTextChunk() returns error? {
    ai:TextChunk chunk = {content: "chunk body"};
    string result = check getChatMessageStringContent(`A ${chunk} B`);
    test:assertEquals(result, "A chunk body  B");
}

@test:Config
function testGetChatMessageStringContentWithTextDocumentArray() returns error? {
    ai:TextDocument doc = {content: "d1"};
    ai:TextDocument[] docs = [doc, {content: "d2"}];
    string result = check getChatMessageStringContent(`Docs: ${docs} done`);
    test:assertEquals(result, "Docs: d1 d2  done");
}

@test:Config
function testGetChatMessageStringContentWithTextChunkArray() returns error? {
    ai:TextChunk[] chunks = [{content: "c1"}, {content: "c2"}];
    string result = check getChatMessageStringContent(`Chunks: ${chunks} done`);
    test:assertEquals(result, "Chunks: c1 c2  done");
}

@test:Config
function testGetChatMessageStringContentWithNonTextDocumentFails() {
    ai:ImageDocument img = {content: "https://example.com/i.png"};
    string|ai:Error result = getChatMessageStringContent(`Look: ${img}`);
    test:assertTrue(result is ai:Error, "a non-text document must produce an error");
    test:assertTrue((<ai:Error>result).message().includes("Only Text Documents are currently supported"));
}

@test:Config
function testGetChatMessageStringContentWithScalarInsertion() returns error? {
    int count = 42;
    string result = check getChatMessageStringContent(`Count is ${count}.`);
    test:assertEquals(result, "Count is 42.");
}

// ===== convertMessageToJson =====

@test:Config
function testConvertMessageToJsonSingleAssistantMessage() returns error? {
    ai:ChatAssistantMessage assistant = {role: "assistant", content: "hi there"};
    json result = check convertMessageToJson(assistant);
    // A non-user/system message is returned as-is; the record carries an explicit `toolCalls: ()`.
    test:assertEquals(result, {role: "assistant", content: "hi there", toolCalls: ()});
}

@test:Config
function testConvertMessageToJsonArrayMixed() returns error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "sys"},
        <ai:ChatUserMessage>{role: "user", content: "usr"},
        <ai:ChatAssistantMessage>{role: "assistant", content: "asst"}
    ];
    json result = check convertMessageToJson(messages);
    json[] arr = <json[]>result;
    test:assertEquals(arr.length(), 3);
}

// ===== convertToResponsesInput =====

@test:Config
function testConvertToResponsesInputSingleUserMessage() returns error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "hello"};
    var [items, instructions] = check convertToResponsesInput(userMsg);
    test:assertEquals(items.length(), 1);
    test:assertTrue(instructions is ());
}

@test:Config
function testConvertToResponsesInputSystemBecomesInstructions() returns error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are helpful."},
        <ai:ChatSystemMessage>{role: "system", content: "Be concise."},
        <ai:ChatUserMessage>{role: "user", content: "Hi"}
    ];
    var [items, instructions] = check convertToResponsesInput(messages);
    test:assertEquals(items.length(), 1, "only the user message becomes an input item");
    test:assertEquals(instructions, "You are helpful.\n\nBe concise.");
}

@test:Config
function testConvertToResponsesInputAssistantWithToolCallsAndContent() returns error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: "user", content: "weather?"},
        <ai:ChatAssistantMessage>{
            role: "assistant",
            content: "Let me check.",
            toolCalls: [{id: "call_1", name: "get_weather", arguments: {"city": "Paris"}}]
        },
        <ai:ChatFunctionMessage>{role: "function", name: "get_weather", id: "call_1", content: "sunny"}
    ];
    var [items, instructions] = check convertToResponsesInput(messages);
    // user message + assistant text + assistant function_call + function_call_output = 4 input items.
    test:assertEquals(items.length(), 4);
    test:assertTrue(instructions is ());
}

@test:Config
function testConvertToResponsesInputAssistantContentOnly() returns error? {
    ai:ChatMessage[] messages = [
        <ai:ChatUserMessage>{role: "user", content: "hi"},
        <ai:ChatAssistantMessage>{role: "assistant", content: "hello back"}
    ];
    var [items, _] = check convertToResponsesInput(messages);
    test:assertEquals(items.length(), 2);
}

// ===== convertContentPartsForResponses =====

@test:Config
function testConvertContentPartsForResponsesTextAndImage() returns error? {
    DocumentContentPart[] parts = [
        {'type: "text", text: "describe"},
        {'type: "image_url", image_url: {url: "https://example.com/i.png"}}
    ];
    var result = check convertContentPartsForResponses(parts);
    test:assertEquals(result.length(), 2);
}

@test:Config
function testConvertContentPartsForResponsesAudioFails() {
    DocumentContentPart[] parts = [
        {'type: "input_audio", input_audio: {format: "mp3", data: "AAAA"}}
    ];
    var result = convertContentPartsForResponses(parts);
    test:assertTrue(result is ai:Error, "audio content is unsupported by the Responses API");
    test:assertTrue((<ai:Error>result).message().includes("Audio input is not supported"));
}

// ===== buildAudioContentPart =====

@test:Config
function testBuildAudioContentPartRejectsUrl() {
    // URL-based audio content is not supported (only inline byte data is accepted).
    ai:AudioDocument aud = {content: "https://example.com/a.mp3", metadata: {"format": "mp3"}};
    var result = buildAudioContentPart(aud);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("URL-based audio content is not supported"));
}

@test:Config
function testBuildAudioContentPartRequiresFormat() {
    // The audio format must be present in metadata.
    ai:AudioDocument aud = {content: sampleBinaryData};
    var result = buildAudioContentPart(aud);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("specify the audio format"));
}

// ===== convertToResponsesTools =====

@test:Config
function testConvertToResponsesTools() {
    ai:ChatCompletionFunctions[] tools = [
        {name: "get_weather", description: "weather", parameters: {"type": "object"}},
        {name: "no_params", description: "a tool with no parameters"}
    ];
    var result = convertToResponsesTools(tools);
    test:assertEquals(result.length(), 2);
}
