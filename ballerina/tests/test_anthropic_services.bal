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

import ballerina/http;
import ballerina/test;

// Mock of the Azure Anthropic (Claude) surface. Two services model the two service-URL shapes the provider
// resolves:
//
//   1. `/llm/azureanthropic/anthropic` - a path-carrying service URL, which `resolveAnthropicBase` uses
//      verbatim. This is the surface almost every test uses.
//   2. `/anthropic` - reached by passing the bare origin `http://localhost:8080`, which the provider completes
//      with `/anthropic` exactly as it completes a bare Azure resource origin.
//
// Both dispatch to one handler, so every wire assertion below applies to both.

// Deployment names that let the mock assert deployment-specific wire expectations.
const ANTHROPIC_DEPLOYMENT = "claude-sonnet-4-6";
// Requests for these deployments must carry exactly the `thinking` object shown, so a converter that emitted
// the same object for every configuration would fail.
const ANTHROPIC_ADAPTIVE_THINKING_DEPLOYMENT = "claude-adaptive-thinking-model";
final readonly & map<json> ANTHROPIC_EXPECTED_ADAPTIVE_THINKING = {
    "type": "adaptive",
    "display": "summarized"
};
const ANTHROPIC_EXTENDED_THINKING_DEPLOYMENT = "claude-extended-thinking-model";
final readonly & map<json> ANTHROPIC_EXPECTED_EXTENDED_THINKING = {"type": "enabled", "budget_tokens": 2048};
const ANTHROPIC_DISABLED_THINKING_DEPLOYMENT = "claude-disabled-thinking-model";
final readonly & map<json> ANTHROPIC_EXPECTED_DISABLED_THINKING = {"type": "disabled"};
// Requests for this deployment must carry exactly this `temperature`.
const ANTHROPIC_TEMPERATURE_DEPLOYMENT = "claude-temperature-model";
const decimal ANTHROPIC_EXPECTED_TEMPERATURE = 0.3;
// Requests for this deployment must not carry `stop_sequences`.
const ANTHROPIC_NO_STOP_DEPLOYMENT = "claude-no-stop-model";
// Requests for this deployment must carry `output_config.effort`.
const ANTHROPIC_EFFORT_DEPLOYMENT = "claude-effort-model";
// Requests for this deployment must not carry `temperature` (the newer Claude models reject it).
const ANTHROPIC_NO_TEMPERATURE_DEPLOYMENT = "claude-opus-5";
// Requests for this deployment must carry the custom `anthropic-version` value below instead of the default.
const ANTHROPIC_CUSTOM_VERSION_DEPLOYMENT = "claude-custom-version-model";
const ANTHROPIC_CUSTOM_VERSION = "2024-10-22";

// Requests for this deployment must carry the joined system instructions in the top-level `system` field.
const ANTHROPIC_SYSTEM_DEPLOYMENT = "claude-system-model";
const ANTHROPIC_EXPECTED_SYSTEM = "You are a helpful assistant.\n\nBe concise.";

const ANTHROPIC_MOCK_RESPONSE_PREFIX = "This is a mock response for: ";
// A prompt owned by the Anthropic tests. The shared expectation map in `test_utils.bal` is keyed by prefix and
// its "What is" entry would shadow a document prompt, so the PDF case gets its own prompt and expectations.
const ANTHROPIC_PDF_PROMPT = "Summarize this document.";
const ANTHROPIC_PDF_RESULT = "This is a sample document description.";
const ANTHROPIC_WEATHER_TOOL = "get_weather";

service /llm/azureanthropic/anthropic on mockListener {

    // Messages API - `POST {base}/v1/messages`. The whole request is taken so that the headers and query
    // parameters can be asserted alongside the body. The success payload is wrapped in `http:Ok` so the mock
    // answers with 200, matching the real service (a `post` resource returning a bare value replies 201).
    resource function post v1/messages(http:Request request) returns http:Ok|http:Response|error {
        return respondToAnthropicMessages(request);
    }
}

// The `/anthropic` base a bare origin resolves to.
service /anthropic on mockListener {

    resource function post v1/messages(http:Request request) returns http:Ok|http:Response|error {
        return respondToAnthropicMessages(request);
    }
}

// ===== Shared handler =====

function respondToAnthropicMessages(http:Request request) returns http:Ok|http:Response|error {
    json|http:Response result = check handleAnthropicMessages(request);
    if result is http:Response {
        return result;
    }
    return <http:Ok>{body: result};
}

function handleAnthropicMessages(http:Request request) returns json|http:Response|error {
    json payload = check request.getJsonPayload();
    assertAnthropicRequestHeaders(request, payload);
    // Unlike the Azure OpenAI surfaces, the Anthropic route must never carry an `api-version` query parameter.
    test:assertFalse(request.getQueryParams().hasKey("api-version"),
            "Anthropic Messages API: the request must not carry an 'api-version' query parameter");

    string deploymentId = check payload.model.ensureType();
    validateAnthropicWireParams(deploymentId, payload);
    json[] messages = check (check payload.messages).ensureType();
    validateAnthropicMessages(messages);

    string initialText = getFirstUserText(messages);

    // Trigger-driven responses for the response-handling coverage tests. These are matched first so that they
    // also bypass the schema/content validation of the structured-generation branch below. The response is
    // wrapped in a 1-tuple because `()` is itself a valid `json`, so a bare `json?` could not distinguish
    // "no trigger matched".
    [json|http:Response]? triggered = getAnthropicTriggerResponse(initialText);
    if triggered is [json|http:Response] {
        return triggered[0];
    }

    // Structured generation: the `getResults` tool is offered and forced.
    json|error toolsJson = payload.tools;
    if toolsJson is json[] && hasGetResultsTool(toolsJson) {
        return handleAnthropicGetResults(payload, toolsJson, initialText);
    }

    if initialText.startsWith(TRIGGER_PARALLEL_TOOL_CALLS) {
        return buildAnthropicParallelToolUseResponse();
    }
    if initialText.startsWith(TRIGGER_PARALLEL_HISTORY) {
        return handleAnthropicParallelHistory(messages);
    }
    if toolsJson is json[] && toolsJson.length() > 0 {
        return buildAnthropicToolUseResponse(ANTHROPIC_WEATHER_TOOL, {"city": "London"}, "toolu_weather");
    }
    return buildAnthropicTextResponse(ANTHROPIC_MOCK_RESPONSE_PREFIX + initialText);
}

// ===== Wire assertions =====

// Not `isolated`: it reads the mutable `http:Request`.
function assertAnthropicRequestHeaders(http:Request request, json payload) {
    string|error apiKey = request.getHeader("x-api-key");
    test:assertTrue(apiKey is string && apiKey.length() > 0,
            "Anthropic Messages API: the deployment key must be sent in the 'x-api-key' header");
    string|error anthropicVersion = request.getHeader("anthropic-version");
    test:assertTrue(anthropicVersion is string,
            "Anthropic Messages API: the 'anthropic-version' header is required");
    if anthropicVersion is string {
        json|error model = payload.model;
        string expectedVersion = model is json && model == ANTHROPIC_CUSTOM_VERSION_DEPLOYMENT
            ? ANTHROPIC_CUSTOM_VERSION
            : DEFAULT_ANTHROPIC_VERSION;
        test:assertEquals(anthropicVersion, expectedVersion,
                "Anthropic Messages API: unexpected 'anthropic-version' header");
    }
    // The Files API beta must be opted into exactly when the request references an uploaded file by id.
    string|error betaHeader = request.getHeader("anthropic-beta");
    if requestUsesFileSource(payload) {
        test:assertEquals(betaHeader is string ? betaHeader : (), "files-api-2025-04-14",
                "Anthropic Messages API: a 'file' document source requires the Files API beta header");
    } else {
        test:assertTrue(betaHeader is error,
                "Anthropic Messages API: the Files API beta header must only be sent when it is needed");
    }
}

// Validates the model-level request parameters.
//
// `temperature`, `thinking` and `output_config` are all optional on the wire and are only sent when the caller
// configured them, so each is asserted through a deployment name that pins the expectation.
isolated function validateAnthropicWireParams(string deploymentId, json payload) {
    test:assertTrue(payload.max_tokens is int,
            "Anthropic Messages API: 'max_tokens' is required on every request");
    if deploymentId == CUSTOM_TOKENS_DEPLOYMENT {
        test:assertEquals(payload.max_tokens, CUSTOM_MAX_TOKENS,
                "Anthropic Messages API: the configured maxTokens must reach the wire");
    }
    // A forced tool choice is the one case where a configured thinking object is legitimately absent: manual
    // extended thinking is rejected alongside it, so the provider drops it.
    boolean forcedToolChoice = payload.tool_choice is map<json>;
    map<json>? expectedThinking = getExpectedAnthropicThinking(deploymentId);
    if expectedThinking is map<json> && !(forcedToolChoice && expectedThinking["type"] == "enabled") {
        test:assertEquals(payload.thinking, expectedThinking,
                "Anthropic Messages API: unexpected 'thinking' object on the wire");
    }
    if deploymentId == ANTHROPIC_TEMPERATURE_DEPLOYMENT {
        test:assertEquals(payload.temperature, ANTHROPIC_EXPECTED_TEMPERATURE,
                "Anthropic Messages API: the configured temperature must reach the wire");
    }
    if deploymentId == ANTHROPIC_NO_STOP_DEPLOYMENT {
        test:assertTrue(payload.stop_sequences is error,
                "Anthropic Messages API: a blank stop sequence must not reach the wire");
    }
    if deploymentId == ANTHROPIC_EFFORT_DEPLOYMENT {
        json|error outputConfig = payload.output_config;
        test:assertTrue(outputConfig is map<json>,
                "Anthropic Messages API: the effort must be sent as 'output_config.effort'");
        if outputConfig is map<json> {
            test:assertTrue(outputConfig["effort"] is string,
                    "Anthropic Messages API: 'output_config.effort' is required for the effort deployment");
        }
    }
    if deploymentId == ANTHROPIC_SYSTEM_DEPLOYMENT {
        test:assertEquals(payload.system, ANTHROPIC_EXPECTED_SYSTEM,
                "Anthropic Messages API: system messages must be joined into the top-level 'system' field");
    }
    if deploymentId == ANTHROPIC_NO_TEMPERATURE_DEPLOYMENT {
        test:assertTrue(payload.temperature is error,
                "Anthropic Messages API: 'temperature' must be omitted when the caller did not configure it");
    }
}

// Validates the structural rules of the Messages API that the converter is responsible for upholding.
isolated function validateAnthropicMessages(json[] messages) {
    test:assertTrue(messages.length() > 0, "Anthropic Messages API: at least one message is required");
    string previousRole = "";
    foreach json message in messages {
        map<json> messageMap = <map<json>>message;
        string role = messageMap["role"].toString();
        test:assertTrue(role == "user" || role == "assistant",
                string `Anthropic Messages API: unexpected message role '${role}'`);
        test:assertNotEquals(role, previousRole,
                "Anthropic Messages API: consecutive same-role turns must be merged into one turn");
        previousRole = role;

        json content = messageMap["content"];
        test:assertTrue(content is json[], "Anthropic Messages API: message content must be a block array");
        json[] blocks = <json[]>content;
        test:assertTrue(blocks.length() > 0, "Anthropic Messages API: message content must not be empty");
        boolean seenNonToolResult = false;
        foreach json block in blocks {
            map<json> blockMap = <map<json>>block;
            string blockType = blockMap["type"].toString();
            if blockType == "text" {
                string text = blockMap["text"].toString();
                test:assertTrue(text.trim().length() > 0,
                        "Anthropic Messages API: text blocks must carry non-whitespace text");
            } else if blockType == "tool_result" {
                test:assertEquals(role, "user",
                        "Anthropic Messages API: 'tool_result' blocks belong to a user turn");
                test:assertFalse(seenNonToolResult,
                        "Anthropic Messages API: 'tool_result' blocks must lead the user turn");
                test:assertTrue(blockMap["tool_use_id"] is string,
                        "Anthropic Messages API: 'tool_result' requires a 'tool_use_id'");
            } else if blockType == "tool_use" {
                test:assertEquals(role, "assistant",
                        "Anthropic Messages API: 'tool_use' blocks belong to an assistant turn");
                test:assertTrue(blockMap["id"] is string && blockMap["name"] is string,
                        "Anthropic Messages API: 'tool_use' requires an 'id' and a 'name'");
                test:assertTrue(blockMap["input"] is map<json>,
                        "Anthropic Messages API: 'tool_use' input must be a JSON object");
            } else {
                test:assertTrue(blockType == "image" || blockType == "document",
                        string `Anthropic Messages API: unexpected content block type '${blockType}'`);
                json blockSource = blockMap["source"];
                test:assertTrue(blockSource is map<json>,
                        string `Anthropic Messages API: a '${blockType}' block requires a 'source'`);
            }
            if blockType != "tool_result" {
                seenNonToolResult = true;
            }
        }
    }
}

// The exact `thinking` object expected for a deployment, or `()` when the deployment does not pin one.
isolated function getExpectedAnthropicThinking(string deploymentId) returns map<json>? {
    match deploymentId {
        ANTHROPIC_ADAPTIVE_THINKING_DEPLOYMENT => {
            return ANTHROPIC_EXPECTED_ADAPTIVE_THINKING;
        }
        ANTHROPIC_EXTENDED_THINKING_DEPLOYMENT => {
            return ANTHROPIC_EXPECTED_EXTENDED_THINKING;
        }
        ANTHROPIC_DISABLED_THINKING_DEPLOYMENT => {
            return ANTHROPIC_EXPECTED_DISABLED_THINKING;
        }
    }
    return ();
}

isolated function requestUsesFileSource(json payload) returns boolean {
    json|error messages = payload.messages;
    if messages !is json[] {
        return false;
    }
    foreach json message in messages {
        json|error content = message.content;
        if content !is json[] {
            continue;
        }
        foreach json block in content {
            json|error blockSource = block.'source;
            if blockSource is map<json> && blockSource["type"] == "file" {
                return true;
            }
        }
    }
    return false;
}

// Returns the text of the first text block of the first user turn, which the mock routes on.
isolated function getFirstUserText(json[] messages) returns string {
    foreach json message in messages {
        map<json> messageMap = <map<json>>message;
        if messageMap["role"] != "user" {
            continue;
        }
        json content = messageMap["content"];
        if content !is json[] {
            continue;
        }
        foreach json block in content {
            map<json> blockMap = <map<json>>block;
            if blockMap["type"] == "text" {
                return blockMap["text"].toString();
            }
        }
    }
    return "";
}

isolated function hasGetResultsTool(json[] tools) returns boolean {
    foreach json tool in tools {
        json|error name = tool.name;
        if name is json && name == GET_RESULTS_TOOL {
            return true;
        }
    }
    return false;
}

// ===== Structured generation (`getResults`) =====

function handleAnthropicGetResults(json payload, json[] tools, string initialText) returns json|error {
    // A forced tool choice must be sent, and manual extended thinking is not supported alongside it.
    json|error toolChoice = payload.tool_choice;
    test:assertTrue(toolChoice is map<json>, "Anthropic Messages API: 'generate' must force the getResults tool");
    if toolChoice is map<json> {
        test:assertEquals(toolChoice["type"], "tool");
        test:assertEquals(toolChoice["name"], GET_RESULTS_TOOL);
    }
    json|error thinking = payload.thinking;
    if thinking is map<json> {
        test:assertNotEquals(thinking["type"], "enabled",
                "Anthropic Messages API: manual extended thinking is rejected with a forced tool choice");
    }

    // The argument-parsing error triggers bypass the schema/content validation below.
    if initialText.startsWith(TRIGGER_GEN_BAD_ARGS) {
        return buildAnthropicToolUseResponse(GET_RESULTS_TOOL, "this-is-not-an-object", "toolu_bad_args");
    }
    if initialText.startsWith(TRIGGER_GEN_TYPE_MISMATCH) {
        return buildAnthropicToolUseResponse(GET_RESULTS_TOOL, {"result": "not-an-int"}, "toolu_mismatch");
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_NO_TOOL_USE) {
        return buildAnthropicTextResponse("I will not call the tool.");
    }

    json firstTool = tools[0];
    map<json> inputSchema = check (check firstTool.input_schema).cloneWithType();
    test:assertEquals(inputSchema, getExpectedAnthropicParameterSchema(initialText),
            string `Anthropic Messages API: schema mismatch for prompt, ${initialText}`);

    json[]? expectedBlocks = getExpectedAnthropicContentBlocks(initialText);
    if expectedBlocks is json[] {
        json[] messages = check (check payload.messages).ensureType();
        json actualBlocks = check messages[0].content;
        test:assertEquals(actualBlocks, expectedBlocks,
                string `Anthropic Messages API: content mismatch for prompt, ${initialText}`);
    }

    json result = check getAnthropicMockResult(initialText).fromJsonString();
    return buildAnthropicToolUseResponse(GET_RESULTS_TOOL, result, "toolu_getresults");
}

// The expected `getResults` schema for a prompt. Prompts owned by the Anthropic tests are resolved here; every
// other prompt falls back to the map shared with the Azure OpenAI tests.
isolated function getExpectedAnthropicParameterSchema(string message) returns map<json> {
    if message.startsWith(ANTHROPIC_PDF_PROMPT) {
        return {"type": "object", "properties": {"result": {"type": "string"}}};
    }
    return getExpectedParameterSchema(message);
}

// The mock `getResults` tool input for a prompt, resolved the same way as the schema above.
isolated function getAnthropicMockResult(string message) returns string {
    if message.startsWith(ANTHROPIC_PDF_PROMPT) {
        return string `{"result": "${ANTHROPIC_PDF_RESULT}"}`;
    }
    return getTheMockLLMResult(message);
}

// The Anthropic content blocks expected for the multimodal prompts used by the tests. Text-only prompts are not
// listed: their exact text is already pinned by the schema/response assertions, and returning `()` here skips
// the block comparison for them.
isolated function getExpectedAnthropicContentBlocks(string message) returns json[]? {
    if message.startsWith("How would you rate this blog content out of 10.") {
        return [
            {"type": "text", "text": "How would you rate this blog content out of 10. "},
            {"type": "text", "text": string `Title: ${blog1.title} Content: ${blog1.content}`},
            {"type": "text", "text": "."}
        ];
    }
    if message.startsWith("Describe the image.") {
        return [
            {"type": "text", "text": "Describe the image. "},
            {"type": "image", "source": {"type": "url", "url": sampleImageUrl}},
            {"type": "text", "text": "."}
        ];
    }
    if message.startsWith("Describe the following image.") {
        return [
            {"type": "text", "text": "Describe the following image. "},
            {
                "type": "image",
                "source": {"type": "base64", "media_type": "image/png", "data": sampleBinaryStr}
            },
            {"type": "text", "text": "."}
        ];
    }
    if message.startsWith(ANTHROPIC_PDF_PROMPT) {
        return [
            {"type": "text", "text": ANTHROPIC_PDF_PROMPT + " "},
            {
                "type": "document",
                "source": {"type": "base64", "media_type": "application/pdf", "data": sampleBinaryStr}
            },
            {"type": "text", "text": "."}
        ];
    }
    return ();
}

// ===== Parallel tool calls =====

// Asserts that a history carrying an assistant turn with two tool calls plus their two results reaches the wire
// in the shape the Messages API requires. This differs from both Azure OpenAI surfaces: the calls are `tool_use`
// blocks inside a single assistant turn, and both results are `tool_result` blocks inside a single following
// user turn - which is precisely why this surface needs its own coverage.
function handleAnthropicParallelHistory(json[] messages) returns json|error {
    test:assertEquals(messages.length(), 3,
            "Anthropic Messages API (parallel tools): the history must collapse into three turns");

    map<json> assistantTurn = check messages[1].ensureType();
    test:assertEquals(assistantTurn["role"], "assistant");
    json[] assistantBlocks = check assistantTurn["content"].ensureType();
    test:assertEquals(assistantBlocks.length(), 2,
            "Anthropic Messages API (parallel tools): both calls belong to one assistant turn");
    string[] callIds = [];
    foreach json block in assistantBlocks {
        map<json> blockMap = check block.ensureType();
        test:assertEquals(blockMap["type"], "tool_use");
        test:assertEquals(blockMap["name"], PARALLEL_TOOL_NAME);
        callIds.push(blockMap["id"].toString());
    }
    test:assertEquals(callIds, [PARIS_CALL_ID, TOKYO_CALL_ID],
            "Anthropic Messages API (parallel tools): the tool calls must keep their order and ids");

    map<json> resultTurn = check messages[2].ensureType();
    test:assertEquals(resultTurn["role"], "user");
    json[] resultBlocks = check resultTurn["content"].ensureType();
    test:assertEquals(resultBlocks.length(), 2,
            "Anthropic Messages API (parallel tools): both results belong to one user turn");
    string[] resultIds = [];
    foreach json block in resultBlocks {
        map<json> blockMap = check block.ensureType();
        test:assertEquals(blockMap["type"], "tool_result");
        test:assertTrue(blockMap["content"] is string,
                "Anthropic Messages API (parallel tools): a tool result must carry its output");
        resultIds.push(blockMap["tool_use_id"].toString());
    }
    test:assertEquals(resultIds, [PARIS_CALL_ID, TOKYO_CALL_ID],
            "Anthropic Messages API (parallel tools): each result must reference its originating call");

    return buildAnthropicTextResponse(PARALLEL_TOOLS_ANSWER);
}

// ===== Trigger-driven responses =====

// Maps a trigger prompt to the response that exercises a specific response-handling branch. Returns `()` for
// ordinary prompts.
isolated function getAnthropicTriggerResponse(string initialText) returns [json|http:Response]? {
    if initialText.startsWith(TRIGGER_ANTHROPIC_REFUSAL_NO_DETAILS) {
        return [buildAnthropicRefusalResponse(false)];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_REFUSAL) {
        return [buildAnthropicRefusalResponse(true)];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_CONTEXT_EXCEEDED) {
        return [buildAnthropicStopReasonResponse("model_context_window_exceeded")];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_EMPTY_CONTENT) {
        return [buildAnthropicStopReasonResponse("end_turn")];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_TRUNCATED) {
        return [buildAnthropicStopReasonResponse("max_tokens")];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_PAUSE_TURN) {
        return [buildAnthropicPauseTurnResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_BLANK_TEXT) {
        return [buildAnthropicBlankTextResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_THINKING_BLOCKS) {
        return [buildAnthropicThinkingResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_TEXT_AND_TOOL) {
        return [buildAnthropicTextAndToolResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_TOOL_NO_NAME) {
        return [buildAnthropicNamelessToolUseResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_TOOL_BAD_INPUT) {
        return [buildAnthropicToolUseResponse(ANTHROPIC_WEATHER_TOOL, [1, 2, 3], "toolu_bad_input")];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_ERROR_ENVELOPE) {
        return [buildAnthropicErrorResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_ERROR_PLAIN) {
        return [buildAnthropicPlainErrorResponse()];
    }
    if initialText.startsWith(TRIGGER_ANTHROPIC_MALFORMED_BODY) {
        return [buildAnthropicMalformedResponse()];
    }
    return ();
}

// ===== Response builders =====

isolated function buildAnthropicTextResponse(string content) returns json => {
    id: "msg_mock_text",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [{'type: "text", text: content}],
    stop_reason: "end_turn",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 20, output_tokens: 10}
};

isolated function buildAnthropicToolUseResponse(string name, json input, string id) returns json => {
    id: "msg_mock_tool_use",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [{'type: "tool_use", id: id, name: name, input: input}],
    stop_reason: "tool_use",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 30, output_tokens: 15}
};

isolated function buildAnthropicParallelToolUseResponse() returns json => {
    id: "msg_mock_parallel",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [
        {'type: "tool_use", id: PARIS_CALL_ID, name: PARALLEL_TOOL_NAME, input: {"city": "Paris"}},
        {'type: "tool_use", id: TOKYO_CALL_ID, name: PARALLEL_TOOL_NAME, input: {"city": "Tokyo"}}
    ],
    stop_reason: "tool_use",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 30, output_tokens: 20}
};

// A response carrying both a text block and a tool call, as Claude returns when it narrates before acting.
isolated function buildAnthropicTextAndToolResponse() returns json => {
    id: "msg_mock_text_and_tool",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [
        {'type: "text", text: "Let me check the weather."},
        {'type: "tool_use", id: "toolu_berlin", name: ANTHROPIC_WEATHER_TOOL, input: {"city": "Berlin"}}
    ],
    stop_reason: "tool_use",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 25, output_tokens: 18}
};

// A response whose reasoning blocks must be skipped while the text block is kept.
isolated function buildAnthropicThinkingResponse() returns json => {
    id: "msg_mock_thinking",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [
        {'type: "thinking", thinking: "The user greeted me."},
        {'type: "redacted_thinking", data: "encrypted-reasoning"},
        {'type: "text", text: "Thought about it."}
    ],
    stop_reason: "end_turn",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 12, output_tokens: 34}
};

// A completed response whose only text block is empty, i.e. no usable content.
isolated function buildAnthropicBlankTextResponse() returns json => {
    id: "msg_mock_blank",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [{'type: "text", text: ""}],
    stop_reason: "end_turn",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 5, output_tokens: 0}
};

isolated function buildAnthropicNamelessToolUseResponse() returns json => {
    id: "msg_mock_nameless_tool",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [{'type: "tool_use", id: "toolu_nameless", input: {"city": "Oslo"}}],
    stop_reason: "tool_use",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 8, output_tokens: 4}
};

// A `pause_turn` response still carries usable text, so it must be passed through rather than rejected.
isolated function buildAnthropicPauseTurnResponse() returns json => {
    id: "msg_mock_pause_turn",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [{'type: "text", text: "Partial answer so far."}],
    stop_reason: "pause_turn",
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 10, output_tokens: 5}
};

isolated function buildAnthropicStopReasonResponse(string stopReason) returns json => {
    id: "msg_mock_" + stopReason,
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [],
    stop_reason: stopReason,
    stop_sequence: (),
    stop_details: (),
    usage: {input_tokens: 10, output_tokens: 0}
};

// The safety-classifier decline: HTTP 200 with `stop_reason: "refusal"` and no usable content.
isolated function buildAnthropicRefusalResponse(boolean withDetails) returns json => {
    id: "msg_mock_refusal",
    'type: "message",
    role: "assistant",
    model: ANTHROPIC_DEPLOYMENT,
    content: [],
    stop_reason: "refusal",
    stop_sequence: (),
    stop_details: withDetails
        ? {'type: "refusal", category: "cyber", explanation: "The request was declined by policy"}
        : (),
    usage: {input_tokens: 10, output_tokens: 0}
};

// The Anthropic error envelope, returned with a 4xx status.
isolated function buildAnthropicErrorResponse() returns http:Response {
    http:Response response = new;
    response.statusCode = http:STATUS_BAD_REQUEST;
    response.setJsonPayload({
        'type: "error",
        'error: {
            'type: "invalid_request_error",
            message: "thinking.type.enabled is not supported by this model"
        }
    });
    return response;
}

// A non-2xx response whose body is not the Anthropic error envelope.
isolated function buildAnthropicPlainErrorResponse() returns http:Response {
    http:Response response = new;
    response.statusCode = http:STATUS_SERVICE_UNAVAILABLE;
    response.setTextPayload("upstream unavailable");
    return response;
}

// A 200 response whose body cannot be bound to the Messages API response shape.
isolated function buildAnthropicMalformedResponse() returns http:Response {
    http:Response response = new;
    response.statusCode = http:STATUS_OK;
    response.setJsonPayload({id: "msg_mock_malformed", content: "not-a-block-array"});
    return response;
}
