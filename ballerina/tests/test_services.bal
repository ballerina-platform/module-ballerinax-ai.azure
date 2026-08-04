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

import ballerina/http;
import ballerina/test;
import ballerinax/azure.openai.embeddings;

// The two Azure OpenAI mock surfaces share a single listener. Two distinct services model the two wire surfaces
// the `OpenAiModelProvider` targets:
//
//   1. `legacyAzureOpenAiService` — the **legacy** Azure OpenAI service (deployment-scoped routes that REQUIRE an
//      `api-version` query parameter). Hosts Chat Completions, Responses, and Embeddings. Chat and Responses are
//      served both with and without an `/openai` base-path segment, because `resolveLegacyBase` uses a
//      path-carrying service URL verbatim (`/llm/azureopenai/...`) while a service URL that already ends with
//      `/openai` keeps that segment. Both shapes share one handler, so the wire assertions apply to both.
//   2. `v1AzureOpenAiService` — the **v1 GA** Azure OpenAI service (`/openai/v1/...` routes that must NOT carry an
//      `api-version` query parameter and send the deployment as `model` in the body).
//
// Because the v1 base path (`/llm/azureopenai/openai/v1`) is more specific than the legacy base path
// (`/llm/azureopenai`), Ballerina's longest-prefix service dispatch routes each request to the correct surface.
listener http:Listener mockListener = new (8080);

// Deployment ids that let a mock assert surface-specific wire expectations (reasoning models omit `temperature`
// and must carry a reasoning effort; the custom-tokens deployment pins the exact token-limit value on the wire).
const REASONING_DEPLOYMENT = "gpt-5";
const CUSTOM_TOKENS_DEPLOYMENT = "custom-tokens-model";
const int CUSTOM_MAX_TOKENS = 1234;

// The reasoning-effort values accepted by the Azure OpenAI specification.
final readonly & string[] VALID_REASONING_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh"];

// Parallel (multiple) tool call fixtures. The two `getWeather` calls are correlated with their results through
// these ids on both the Chat Completions and the Responses surfaces.
const PARALLEL_TOOL_NAME = "getWeather";
const PARIS_CALL_ID = "call_paris_id";
const TOKYO_CALL_ID = "call_tokyo_id";
const PARALLEL_TOOLS_ANSWER = "Paris is sunny at 25°C and Tokyo is rainy at 18°C.";

// ===== 1. Legacy Azure OpenAI service =====

service /llm/azureopenai on mockListener {

    // Chat Completions — legacy deployment-scoped route. The `api-version` query parameter is REQUIRED here;
    // declaring it non-optional makes the mock reject (and the test fail) if the provider ever drops it.
    resource function post deployments/[string deploymentId]/chat/completions(
            string api\-version, @http:Payload json payload) returns json|error {
        return handleLegacyChatCompletion(deploymentId, api\-version, payload);
    }

    // Chat Completions — same route under an `/openai` base path, exercised by service URLs that already end with
    // `/openai` (and by the bare-origin completion, which produces the same shape).
    resource function post openai/deployments/[string deploymentId]/chat/completions(
            string api\-version, @http:Payload json payload) returns json|error {
        return handleLegacyChatCompletion(deploymentId, api\-version, payload);
    }

    // Responses — legacy preview route. The `api-version` query parameter is REQUIRED here.
    resource function post responses(string api\-version, @http:Payload json payload)
            returns json|error {
        return handleLegacyResponses(api\-version, payload);
    }

    // Responses — same route under an `/openai` base path.
    resource function post openai/responses(string api\-version, @http:Payload json payload)
            returns json|error {
        return handleLegacyResponses(api\-version, payload);
    }

    // Embeddings — legacy deployment-scoped route. The `api-version` query parameter is REQUIRED here; declaring
    // it non-optional makes the mock reject (and the test fail) if the provider ever drops it.
    resource function post deployments/[string deploymentId]/embeddings(string api\-version,
            embeddings:Deploymentid_embeddings_body payload) returns embeddings:Inline_response_200|error {
        test:assertTrue(api\-version.length() > 0,
                "Embeddings (legacy): the api-version query parameter must be forwarded");
        // The legacy deployment-scoped route carries the deployment in the URL, so a body-level `model` must not
        // be sent.
        test:assertTrue(payload?.model is (),
                "Embeddings (legacy): 'model' must not be present in the body (deployment is in the URL)");
        string|embeddings:InputItemsString[]? input = payload.input;
        return buildEmbeddingsResponse(input is embeddings:InputItemsString[],
                input is string && input == EMPTY_EMBED_TRIGGER);
    }
}

// Shared legacy Chat Completions handler. Both legacy chat routes (with and without an `/openai` base-path
// segment) delegate here, so the wire assertions apply to every legacy base URL shape.
function handleLegacyChatCompletion(string deploymentId, string apiVersion, json payload)
        returns json|error {
    // Regression guard for the max_tokens -> max_completion_tokens fix: verify the wire body carries the
    // correct token-limit field for the api-version. Applies to both the chat() and generate() paths.
    assertChatCompletionTokenField(apiVersion, payload);
    // The legacy deployment-scoped route carries the deployment in the URL, so a body-level `model` must not
    // be sent.
    test:assertTrue(payload.model is error,
            "Chat Completions (legacy): 'model' must not be present in the body (deployment is in the URL)");
    validateChatWireParams(deploymentId, payload);
    return respondToChatCompletion(deploymentId, payload);
}

// Shared legacy Responses handler; both legacy responses routes delegate here.
function handleLegacyResponses(string apiVersion, json payload) returns json|error {
    test:assertTrue(apiVersion.length() > 0,
            "Responses API (legacy preview): the api-version query parameter must be forwarded");
    validateResponsesWireParams(payload);
    return handleResponsesApiRequest(payload);
}

// ===== 2. V1 Azure OpenAI service =====

service /llm/azureopenai/openai/v1 on mockListener {

    // Chat Completions — v1 GA route. The deployment is sent as `model` in the body. An `api-version` query
    // parameter is only present when the caller opted into a `preview`/`v1` surface; a date-based api-version must
    // never reach this route.
    resource function post chat/completions(@http:Payload json payload, string? api\-version = ())
            returns json|error {
        string model = check payload.model.ensureType();
        assertV1ApiVersion(api\-version);
        test:assertTrue(payload.max_completion_tokens !is error,
                "Chat Completions (v1): 'max_completion_tokens' expected");
        test:assertTrue(payload.max_tokens is error,
                "Chat Completions (v1): deprecated 'max_tokens' must not be present");
        validateChatWireParams(model, payload);
        return respondToChatCompletion(model, payload);
    }

    // Responses — v1 GA route. An `api-version` query parameter is only present on a `preview`/`v1` opt-in.
    resource function post responses(@http:Payload json payload, string? api\-version = ()) returns json|error {
        assertV1ApiVersion(api\-version);
        validateResponsesWireParams(payload);
        return handleResponsesApiRequest(payload);
    }

    // Embeddings — v1 GA route. The deployment is sent as `model` in the body. An `api-version` query parameter is
    // only present when the caller opted into a `preview`/`v1` surface; a date-based api-version must never reach
    // this route.
    resource function post embeddings(@http:Payload json payload, string? api\-version = ())
            returns embeddings:Inline_response_200|error {
        assertV1ApiVersion(api\-version);
        string model = check payload.model.ensureType();
        test:assertTrue(model.length() > 0,
                "Embeddings (v1): the deployment must be sent as 'model' in the body");
        json input = check payload.input;
        return buildEmbeddingsResponse(input is json[], input is string && input == EMPTY_EMBED_TRIGGER);
    }
}

// ===== Embeddings mock response logic =====

// Shared mock embeddings response builder for both surfaces (legacy deployment-scoped and v1 GA). `isBatch`
// selects the two-vector batch response; `isEmpty` drives the "no embeddings generated" branch.
isolated function buildEmbeddingsResponse(boolean isBatch, boolean isEmpty) returns embeddings:Inline_response_200 {
    if isEmpty {
        return {data: [], model: "text-embedding-3-small", usage: {prompt_tokens: 0, total_tokens: 0}, 'object: "list"};
    }
    embeddings:Inline_response_200_data[] data = from int i in 0 ..< 2
        select {
            embedding: from int j in 0 ..< 1536
                select 0.1 + j * 0.1,
            index: i,
            'object: "list"
        };
    return {
        data: isBatch ? data : [data[0]],
        model: "text-embedding-3-small",
        usage: {
            prompt_tokens: 15,
            total_tokens: 15
        },
        'object: "list"
    };
}

// ===== Wire-parameter validation =====

// On the v1 GA surface the only accepted `api-version` values are the opt-in surfaces `preview` and `v1`; a
// date-based api-version must never be forwarded here.
isolated function assertV1ApiVersion(string? apiVersion) {
    if apiVersion is string {
        test:assertTrue(apiVersion == "preview" || apiVersion == "v1",
                string `V1 surface: only 'preview'/'v1' api-versions are allowed, found '${apiVersion}'`);
    }
}

// Asserts that a reasoning effort value carried on the wire is one accepted by the Azure OpenAI specification.
isolated function assertValidReasoningEffort(json effort) {
    string effortStr = effort.toString();
    test:assertTrue(VALID_REASONING_EFFORTS.indexOf(effortStr) is int,
            string `Unexpected reasoning effort on the wire: '${effortStr}'`);
}

// Validates Chat Completions wire parameters. Reasoning models (identified by the reasoning deployment id) must
// carry a reasoning effort; the custom-tokens deployment pins the exact token-limit value. Any reasoning effort
// present, on any deployment, must be a spec-valid value.
//
// Note: `temperature` is intentionally NOT asserted-absent here. The `azure.openai.chat` connector models the
// request body's `temperature` as a required field defaulting to `1`, so the value `1` is always serialized even
// when the caller passes `temperature = ()`. Azure reasoning models accept the default temperature (`1`), so this
// is spec-compliant; the `temperature = ()` usage documented on the provider simply leaves the default in place
// on this path rather than removing the field.
isolated function validateChatWireParams(string deploymentId, json payload) {
    json|error reasoningEffort = payload.reasoning_effort;
    if reasoningEffort is json {
        assertValidReasoningEffort(reasoningEffort);
    }
    if deploymentId == REASONING_DEPLOYMENT {
        test:assertTrue(reasoningEffort is json,
                "Chat Completions: a reasoning model request must carry 'reasoning_effort'");
    }
    if deploymentId == CUSTOM_TOKENS_DEPLOYMENT {
        json|error mct = payload.max_completion_tokens;
        json|error mt = payload.max_tokens;
        json tokenValue = mct is json ? mct : (mt is json ? mt : ());
        test:assertEquals(tokenValue, CUSTOM_MAX_TOKENS,
                "Chat Completions: the configured maxTokens must reach the wire");
    }
}

// Validates Responses API wire parameters. This module always sends `store: false`; reasoning models carry a
// nested `reasoning.effort` object; the custom-tokens deployment pins `max_output_tokens`. As on the Chat
// Completions path, `temperature` defaults to `1` in the connector's request type and is therefore not
// asserted-absent for reasoning models (the default is spec-compliant for reasoning models).
isolated function validateResponsesWireParams(json payload) {
    test:assertEquals(payload.store, false, "Responses API: 'store' must be sent as false");
    string? model = ();
    json|error modelJson = payload.model;
    if modelJson is json {
        model = modelJson.toString();
    }
    json|error reasoning = payload.reasoning;
    if reasoning is map<json> {
        json|error effort = reasoning.effort;
        if effort is json {
            assertValidReasoningEffort(effort);
        }
    }
    if model == REASONING_DEPLOYMENT {
        test:assertTrue(reasoning is map<json>,
                "Responses API: a reasoning model request must carry a 'reasoning' object");
    }
    if model == CUSTOM_TOKENS_DEPLOYMENT {
        test:assertEquals(payload.max_output_tokens, CUSTOM_MAX_TOKENS,
                "Responses API: the configured maxTokens must reach the wire as 'max_output_tokens'");
    }
}

// ===== Chat Completions mock response logic =====

// Shared classify-and-respond logic for both Chat Completions mock routes (legacy and v1 GA).
isolated function respondToChatCompletion(string deploymentId, json payload) returns json|error {
    json[] messages = check (check payload.messages).ensureType();

    // Classify the tools provided in the request.
    boolean hasGetResultsTool = false;
    boolean hasOtherTool = false;
    json|error toolsJson = payload.tools;
    if toolsJson is json[] {
        foreach json tool in toolsJson {
            json fn = check tool.'function;
            string? toolName = check fn.name.ensureType();
            if toolName == GET_RESULTS_TOOL {
                hasGetResultsTool = true;
            } else {
                hasOtherTool = true;
            }
        }
    }

    if hasGetResultsTool {
        // generate() path: validate the content and schema, then return the structured result as a tool call.
        json[] contentParts = check (check messages[0].content).ensureType();
        string initialText = check contentParts[0].text.ensureType();
        // generate() argument-parsing error triggers bypass the schema/content validation below.
        if initialText.startsWith(TRIGGER_GEN_BAD_ARGS) {
            return getChatCompletionGetResultsResponse("this-is-not-json");
        }
        if initialText.startsWith(TRIGGER_GEN_TYPE_MISMATCH) {
            return getChatCompletionGetResultsResponse("{\"result\": \"not-an-int\"}");
        }
        if initialText.startsWith(TRIGGER_GEN_EMPTY_CHOICES) {
            return getEmptyChoicesChatCompletionResponse();
        }
        test:assertEquals(contentParts, getExpectedContentParts(initialText),
                string `Chat Completions: content mismatch for prompt, ${initialText}`);

        json[] toolsArr = check toolsJson.ensureType();
        json toolFn = check toolsArr[0].'function;
        map<json>? parameters = check (check toolFn.parameters).cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected getResults tool");
        }
        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Chat Completions: schema mismatch for prompt, ${initialText}`);
        return getTestServiceResponse(initialText);
    }

    // chat() path: return a get_weather tool call when tools are present, otherwise a text response (or a
    // trigger-driven response for the edge-case coverage tests).
    string userContent = getUserMessageContent(messages);
    // The parallel tool calling triggers must be matched before the generic single-tool-call branch below, since
    // they too are sent with tools present and need to override its response.
    if userContent.startsWith(TRIGGER_PARALLEL_TOOL_CALLS) {
        return getParallelToolCallsResponse();
    }
    if userContent.startsWith(TRIGGER_PARALLEL_HISTORY) {
        return handleParallelToolCallHistory(messages);
    }
    if hasOtherTool {
        return getChatCompletionToolCallResponse("get_weather", "{\"city\": \"London\"}");
    }

    if userContent.startsWith(TRIGGER_STREAMING) {
        return getStreamingChatCompletionResponse();
    }
    if userContent.startsWith(TRIGGER_EMPTY_CHOICES) {
        return getEmptyChoicesChatCompletionResponse();
    }
    if userContent.startsWith(TRIGGER_FUNCTION_CALL) {
        return getDeprecatedFunctionCallResponse();
    }
    if userContent.startsWith(TRIGGER_BAD_TOOL_ARGS) {
        return getChatCompletionToolCallResponse("get_weather", "this-is-not-json");
    }
    return getChatCompletionContentResponse(userContent);
}

// Asserts that a Chat Completions request body carries exactly the token-limit field appropriate for its
// api-version: `max_completion_tokens` (and never `max_tokens`) for api-versions >= 2024-08-01-preview, and
// `max_tokens` (and never `max_completion_tokens`) for older versions. The expected field is derived from the
// production `usesMaxCompletionTokens` selector (independently pinned by the unit tests in
// `test_token_params.bal`); this integration guard additionally proves the selected body actually reaches the
// wire through the raw HTTP client. A `null` `max_tokens` (which reasoning models also reject) would leave the
// key present and therefore fail the `assertFalse` below.
isolated function assertChatCompletionTokenField(string apiVersion, json payload) {
    boolean maxTokensPresent = payload.max_tokens !is error;
    boolean maxCompletionTokensPresent = payload.max_completion_tokens !is error;
    if usesMaxCompletionTokens(apiVersion) {
        test:assertTrue(maxCompletionTokensPresent,
                string `Chat Completions: 'max_completion_tokens' expected for api-version '${apiVersion}'`);
        test:assertFalse(maxTokensPresent,
                string `Chat Completions: 'max_tokens' must be absent for api-version '${apiVersion}'`);
    } else {
        test:assertTrue(maxTokensPresent,
                string `Chat Completions: 'max_tokens' expected for api-version '${apiVersion}'`);
        test:assertFalse(maxCompletionTokensPresent,
                string `Chat Completions: 'max_completion_tokens' must be absent for api-version '${apiVersion}'`);
    }
}

// Returns the content of the first user message (used to determine the mock chat response).
isolated function getUserMessageContent(json[] messages) returns string {
    foreach json message in messages {
        json|error role = message.role;
        json|error content = message.content;
        if role is json && role == "user" && content is string {
            return content;
        }
    }
    return "";
}

// ===== Responses API mock response logic =====

// Shared handler for the Azure OpenAI Responses API mock.
function handleResponsesApiRequest(json payload) returns json|error {
    json[] inputItems = check (check payload.input).ensureType();
    if inputItems.length() == 0 {
        test:assertFail("Expected input items in the payload");
    }

    // Find the first user message's content to determine the test case.
    string initialText = "";
    json firstItem = inputItems[0];
    string? role = check firstItem.role.ensureType();
    if role == "user" {
        json itemContent = check firstItem.content;
        if itemContent is string {
            initialText = itemContent;
        } else {
            json[] contentParts = check itemContent.ensureType();
            if contentParts.length() > 0 {
                json firstPart = contentParts[0];
                string? partType = check firstPart.'type.ensureType();
                if partType == "input_text" {
                    initialText = check firstPart.text.ensureType();
                }
            }
        }
    }

    // Trigger-driven responses for the edge-case coverage tests (status handling and output parsing).
    // The response is wrapped in a 1-tuple because `()` is itself a valid `json`, so a bare `json?` could not
    // distinguish "no trigger matched" from "the trigger response is null".
    [json]? triggerResponse = getResponsesTriggerResponse(initialText);
    if triggerResponse is [json] {
        return triggerResponse[0];
    }

    // Parallel tool calls are dispatched here rather than through `getResponsesTriggerResponse`, because the
    // follow-up turn needs the whole input item list (not just the first user message) to assert the
    // reconstructed history.
    if initialText.startsWith(TRIGGER_PARALLEL_TOOL_CALLS) {
        return getParallelToolCallsResponsesResponse();
    }
    if initialText.startsWith(TRIGGER_PARALLEL_HISTORY) {
        return handleParallelToolCallHistoryViaResponses(inputItems);
    }

    // Classify the provided tools.
    json|error toolsJson = payload.tools;
    boolean hasGetResultsTool = false;
    if toolsJson is json[] && toolsJson.length() > 0 {
        foreach json tool in toolsJson {
            string? toolType = check tool.'type.ensureType();
            if toolType == "function" {
                string? toolName = check tool.name.ensureType();
                if toolName == GET_RESULTS_TOOL {
                    hasGetResultsTool = true;
                }
            }
        }
    }

    if hasGetResultsTool {
        json[] toolsArr = check toolsJson.ensureType();
        json firstTool = toolsArr[0];
        map<json>? parameters = check (check firstTool.parameters).cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected tool");
        }
        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Responses API: Test failed for prompt with initial content, ${initialText}`);
        return getTestResponsesApiResponseWithToolCall(initialText);
    }

    if toolsJson is json[] && toolsJson.length() > 0 {
        return getTestResponsesApiToolCallChatResponse();
    }

    return getTestResponsesApiChatResponse(initialText);
}

// Maps an edge-case trigger prompt to a Responses API response that exercises a specific status/output branch.
// Returns `()` for ordinary prompts (which are handled by the normal classification logic).
isolated function getResponsesTriggerResponse(string initialText) returns [json]? {
    if initialText.startsWith(TRIGGER_STATUS_FAILED_NOERR) {
        return [buildResponsesStatusResponse("failed", (), ())];
    }
    if initialText.startsWith(TRIGGER_STATUS_FAILED) {
        return [buildResponsesStatusResponse("failed", "The upstream model failed", ())];
    }
    if initialText.startsWith(TRIGGER_STATUS_INCOMPLETE_NODETAIL) {
        return [buildResponsesStatusResponse("incomplete", (), ())];
    }
    if initialText.startsWith(TRIGGER_STATUS_INCOMPLETE) {
        return [buildResponsesStatusResponse("incomplete", (), "max_output_tokens")];
    }
    if initialText.startsWith(TRIGGER_STATUS_CANCELLED) {
        return [buildResponsesStatusResponse("cancelled", (), ())];
    }
    if initialText.startsWith(TRIGGER_STATUS_INPROGRESS) {
        return [buildResponsesStatusResponse("in_progress", (), ())];
    }
    if initialText.startsWith(TRIGGER_STATUS_QUEUED) {
        return [buildResponsesStatusResponse("queued", (), ())];
    }
    if initialText.startsWith(TRIGGER_EMPTY_OUTPUT) {
        return [getResponsesEmptyOutputResponse()];
    }
    if initialText.startsWith(TRIGGER_BAD_ARGS) {
        return [getResponsesBadArgsResponse()];
    }
    if initialText.startsWith(TRIGGER_OUTPUT_MESSAGE) {
        return [getResponsesOutputMessageVariantResponse()];
    }
    if initialText.startsWith(TRIGGER_CONTENT_AND_TOOL) {
        return [getResponsesContentAndToolResponse()];
    }
    if initialText.startsWith(TRIGGER_GEN_BAD_ARGS) {
        return [getResponsesGetResultsResponse("this-is-not-json")];
    }
    if initialText.startsWith(TRIGGER_GEN_TYPE_MISMATCH) {
        return [getResponsesGetResultsResponse("{\"result\": \"not-an-int\"}")];
    }
    if initialText.startsWith(TRIGGER_ARGS_NOT_OBJECT) {
        return [getResponsesFunctionCallArgsResponse("[1, 2, 3]")];
    }
    return ();
}

// Builds a completed Responses API response with a function_call output item carrying caller-supplied raw
// arguments (used to drive the chat() output converter's argument-parsing error branches).
isolated function getResponsesFunctionCallArgsResponse(string arguments) returns json => {
    id: "resp_fc_args",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "fc_args",
            'type: "function_call",
            name: "get_weather",
            arguments: arguments,
            call_id: "call_args",
            status: "completed"
        }
    ],
    output_text: ""
};

// Builds a Responses API function_call output item for the getResults tool with caller-supplied raw arguments.
isolated function getResponsesGetResultsResponse(string arguments) returns json => {
    id: "resp_getresults",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "fc_getresults",
            'type: "function_call",
            name: GET_RESULTS_TOOL,
            arguments: arguments,
            call_id: "call_getresults",
            status: "completed"
        }
    ],
    output_text: ""
};

// ===== Chat Completions response builders =====

// Builds a Chat Completions response carrying a single tool call.
isolated function getChatCompletionToolCallResponse(string name, string arguments) returns json => {
    id: "chat-tool-call-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "tool_calls",
            index: 0,
            // Azure returns `logprobs: null` (present, null) when logprobs are not requested.
            logprobs: (),
            message: {
                role: "assistant",
                content: (),
                tool_calls: [
                    {
                        id: "call_weather_123",
                        'type: "function",
                        'function: {
                            name: name,
                            arguments: arguments
                        }
                    }
                ]
            }
        }
    ],
    usage: {
        prompt_tokens: 20,
        completion_tokens: 10,
        total_tokens: 30
    }
};

// Builds a Chat Completions response carrying two parallel tool calls, as Azure returns when a model decides to
// invoke the same function for two different arguments in one turn.
isolated function getParallelToolCallsResponse() returns json => {
    id: "parallel-test-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "tool_calls",
            index: 0,
            logprobs: (),
            message: {
                role: "assistant",
                content: (),
                tool_calls: [
                    {
                        id: PARIS_CALL_ID,
                        'type: "function",
                        'function: {name: PARALLEL_TOOL_NAME, arguments: "{\"city\": \"Paris\"}"}
                    },
                    {
                        id: TOKYO_CALL_ID,
                        'type: "function",
                        'function: {name: PARALLEL_TOOL_NAME, arguments: "{\"city\": \"Tokyo\"}"}
                    }
                ]
            }
        }
    ],
    usage: {
        prompt_tokens: 20,
        completion_tokens: 10,
        total_tokens: 30
    }
};

// Asserts that a chat history containing an assistant message with two tool calls plus their two results reaches
// the wire in the shape the Chat Completions API requires: the assistant message must use the `tool_calls` array
// (not the deprecated singular `function_call`), and each result must be a `role: "tool"` message carrying the
// `tool_call_id` of the call it answers.
isolated function handleParallelToolCallHistory(json[] messages) returns json|error {
    test:assertEquals(messages.length(), 4, "Expected the full 4-message history on the wire");

    map<json> assistant = check messages[1].ensureType();
    // The assistant message must use the plural `tool_calls` array and must NOT fall back to the deprecated
    // singular `function_call`, which cannot express more than one call.
    test:assertFalse(assistant.hasKey("function_call"),
            "Assistant message must not use the deprecated 'function_call' field");
    json[] toolCallsInHistory = check assistant["tool_calls"].ensureType();
    test:assertEquals(toolCallsInHistory.length(), 2, "Both tool calls must be in history");

    map<json> firstResult = check messages[2].ensureType();
    test:assertEquals(firstResult["role"], "tool", "First tool result must have role 'tool'");
    test:assertEquals(firstResult["tool_call_id"], PARIS_CALL_ID, "First result must reference call_paris_id");

    map<json> secondResult = check messages[3].ensureType();
    test:assertEquals(secondResult["role"], "tool", "Second tool result must have role 'tool'");
    test:assertEquals(secondResult["tool_call_id"], TOKYO_CALL_ID, "Second result must reference call_tokyo_id");

    return getChatCompletionContentResponse2(PARALLEL_TOOLS_ANSWER);
}

// Builds a Chat Completions response whose assistant content is returned verbatim (unlike
// `getChatCompletionContentResponse`, which prefixes a mock marker).
isolated function getChatCompletionContentResponse2(string content) returns json => {
    id: "parallel-test-id-2",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "stop",
            index: 0,
            logprobs: (),
            message: {
                role: "assistant",
                content: content
            }
        }
    ],
    usage: {
        prompt_tokens: 20,
        completion_tokens: 10,
        total_tokens: 30
    }
};

// ===== Parallel (multiple) tool calls: Responses surface =====

// Asserts that a history carrying an assistant message with two tool calls plus their two results reaches the
// wire in the shape the Responses API requires. This differs fundamentally from Chat Completions: there is no
// assistant `tool_calls` array and no `role: "tool"` message. Each call becomes a flat `function_call` input item
// and each result a `function_call_output` item, correlated by `call_id`. That difference is precisely why this
// surface needs its own coverage rather than relying on the Chat Completions tests.
isolated function handleParallelToolCallHistoryViaResponses(json[] inputItems) returns json|error {
    string[] functionCallIds = [];
    string[] functionOutputIds = [];

    foreach json item in inputItems {
        if item !is map<json> {
            continue;
        }
        string itemType = item["type"].toString();
        if itemType == "function_call" {
            test:assertEquals(item["name"], PARALLEL_TOOL_NAME,
                    "Responses API (parallel tools): unexpected tool name in the reconstructed history");
            test:assertTrue(item["arguments"] is string,
                    "Responses API (parallel tools): 'arguments' must be sent as a JSON string");
            // The optional item `id` must be a server-assigned `fc_...` id; sending the `call_...` correlation
            // id there makes Azure reject the turn, so the provider must omit it.
            json? itemId = item["id"];
            test:assertTrue(itemId is () || itemId.toString().startsWith("fc"),
                    "Responses API (parallel tools): a function_call item 'id' must be omitted or an 'fc_...' id");
            functionCallIds.push(item["call_id"].toString());
        } else if itemType == "function_call_output" {
            test:assertTrue(item["output"] is string,
                    "Responses API (parallel tools): 'output' must be sent as a string");
            functionOutputIds.push(item["call_id"].toString());
        }
    }

    test:assertEquals(functionCallIds, [PARIS_CALL_ID, TOKYO_CALL_ID],
            "Responses API (parallel tools): one 'function_call' item per call is required, in order");
    test:assertEquals(functionOutputIds, [PARIS_CALL_ID, TOKYO_CALL_ID],
            "Responses API (parallel tools): each 'function_call_output' must reference its originating call_id");

    return getParallelToolCallsResponsesFollowUpResponse();
}

// Builds a Responses API response carrying TWO parallel `function_call` output items.
isolated function getParallelToolCallsResponsesResponse() returns json => {
    id: "resp_parallel_tool_calls",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: true,
    output: [
        {
            id: "fc_paris",
            'type: "function_call",
            name: PARALLEL_TOOL_NAME,
            arguments: "{\"city\": \"Paris\"}",
            call_id: PARIS_CALL_ID,
            status: "completed"
        },
        {
            id: "fc_tokyo",
            'type: "function_call",
            name: PARALLEL_TOOL_NAME,
            arguments: "{\"city\": \"Tokyo\"}",
            call_id: TOKYO_CALL_ID,
            status: "completed"
        }
    ],
    output_text: ""
};

// Builds the Responses API answer returned once both parallel tool results have been fed back.
isolated function getParallelToolCallsResponsesFollowUpResponse() returns json => {
    id: "resp_parallel_tool_calls_followup",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: true,
    output: [
        {
            id: "msg_parallel_followup",
            'type: "message",
            role: "assistant",
            status: "completed",
            content: [
                {
                    'type: "output_text",
                    text: PARALLEL_TOOLS_ANSWER,
                    annotations: []
                }
            ]
        }
    ],
    output_text: PARALLEL_TOOLS_ANSWER
};

// Builds a Chat Completions response carrying a plain text assistant message.
isolated function getChatCompletionContentResponse(string content) returns json => {
    id: "chat-content-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "stop",
            index: 0,
            // Azure returns `logprobs: null` (present, null) when logprobs are not requested.
            logprobs: (),
            message: {
                role: "assistant",
                content: "This is a mock response for: " + content
            }
        }
    ],
    usage: {
        prompt_tokens: 20,
        completion_tokens: 10,
        total_tokens: 30
    }
};

// Builds a streaming (`chat.completion.chunk`) response, which this module does not support and must reject.
isolated function getStreamingChatCompletionResponse() returns json => {
    id: "chat-chunk-id",
    'object: "chat.completion.chunk",
    created: 1234567890,
    model: "gpt-4o",
    choices: []
};

// Builds a (non-streaming) response with no choices.
isolated function getEmptyChoicesChatCompletionResponse() returns json => {
    id: "chat-empty-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: []
};

// Builds a response using the deprecated top-level `function_call` field (backward-compatibility path).
isolated function getDeprecatedFunctionCallResponse() returns json => {
    id: "chat-fn-call-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "function_call",
            index: 0,
            logprobs: (),
            message: {
                role: "assistant",
                content: (),
                function_call: {
                    name: "get_weather",
                    arguments: "{\"city\": \"Paris\"}"
                }
            }
        }
    ]
};

// Builds a Chat Completions getResults tool-call response with caller-supplied raw arguments (used by the
// generate() argument-parsing error tests).
isolated function getChatCompletionGetResultsResponse(string arguments) returns json => {
    id: "chat-getresults-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "tool_calls",
            index: 0,
            logprobs: (),
            message: {
                role: "assistant",
                content: (),
                tool_calls: [
                    {
                        id: "tool-call-id",
                        'type: "function",
                        'function: {
                            name: GET_RESULTS_TOOL,
                            arguments: arguments
                        }
                    }
                ]
            }
        }
    ]
};

// ===== Responses API response builders =====

// Builds a Responses API response with a function_call output item (for generate() tests).
isolated function getTestResponsesApiResponseWithToolCall(string content) returns json {
    return {
        id: "resp_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        metadata: (),
        tool_choice: "auto",
        tools: [],
        parallel_tool_calls: false,
        output: [
            {
                id: "fc_test_id",
                'type: "function_call",
                name: GET_RESULTS_TOOL,
                arguments: getTheMockLLMResult(content),
                call_id: "call_test_id",
                status: "completed"
            }
        ],
        output_text: "",
        usage: {
            input_tokens: 100,
            output_tokens: 50,
            total_tokens: 150,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a Responses API response with a text message output item (for chat() tests).
isolated function getTestResponsesApiChatResponse(string content) returns json {
    string responseText = "This is a mock response for: " + content;
    return {
        id: "resp_chat_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        metadata: (),
        tool_choice: "auto",
        tools: [],
        parallel_tool_calls: false,
        output: [
            {
                id: "msg_test_id",
                'type: "message",
                role: "assistant",
                status: "completed",
                content: [
                    {
                        'type: "output_text",
                        text: responseText,
                        annotations: []
                    }
                ]
            }
        ],
        output_text: responseText,
        usage: {
            input_tokens: 50,
            output_tokens: 30,
            total_tokens: 80,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a Responses API response with a function_call output item (for chat() with tools tests).
isolated function getTestResponsesApiToolCallChatResponse() returns json {
    return {
        id: "resp_tool_chat_test_id",
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: "completed",
        'error: (),
        incomplete_details: (),
        instructions: (),
        metadata: (),
        tool_choice: "auto",
        tools: [],
        parallel_tool_calls: false,
        output: [
            {
                id: "fc_chat_test_id",
                'type: "function_call",
                name: "get_weather",
                arguments: "{\"city\": \"London\"}",
                call_id: "call_weather_123",
                status: "completed"
            }
        ],
        output_text: "",
        usage: {
            input_tokens: 80,
            output_tokens: 20,
            total_tokens: 100,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a Responses API response pinned to a specific non-terminal/terminal status, optionally with an error
// message (for `failed`) or incomplete-details reason (for `incomplete`).
isolated function buildResponsesStatusResponse(string status, string? errorMessage, string? incompleteReason)
        returns json {
    json errorObj = errorMessage is string ? {code: "server_error", message: errorMessage} : ();
    json incompleteObj = incompleteReason is string ? {reason: incompleteReason} : ();
    return {
        id: "resp_status_" + status,
        'object: "response",
        created_at: 1234567890,
        model: "gpt-4o",
        status: status,
        'error: errorObj,
        incomplete_details: incompleteObj,
        instructions: (),
        metadata: (),
        tool_choice: "auto",
        tools: [],
        parallel_tool_calls: false,
        output: [],
        output_text: "",
        usage: {
            input_tokens: 10,
            output_tokens: 0,
            total_tokens: 10,
            input_tokens_details: {cached_tokens: 0},
            output_tokens_details: {reasoning_tokens: 0}
        }
    };
}

// Builds a completed Responses API response whose only output item is a message with no usable text content.
isolated function getResponsesEmptyOutputResponse() returns json => {
    id: "resp_empty_output",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "msg_empty",
            'type: "message",
            role: "assistant",
            status: "completed",
            content: []
        }
    ],
    output_text: ""
};

// Builds a completed Responses API response whose function_call output carries invalid JSON arguments.
isolated function getResponsesBadArgsResponse() returns json => {
    id: "resp_bad_args",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "fc_bad",
            'type: "function_call",
            name: "get_weather",
            arguments: "this-is-not-json",
            call_id: "call_bad",
            status: "completed"
        }
    ],
    output_text: ""
};

// Builds a completed Responses API response using the `output_message` item-type variant.
isolated function getResponsesOutputMessageVariantResponse() returns json => {
    id: "resp_output_message",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "msg_variant",
            'type: "output_message",
            role: "assistant",
            status: "completed",
            content: [
                {
                    'type: "output_text",
                    text: "Variant message response.",
                    annotations: []
                }
            ]
        }
    ],
    output_text: "Variant message response."
};

// Builds a completed Responses API response carrying BOTH a text message and a function_call output item.
isolated function getResponsesContentAndToolResponse() returns json => {
    id: "resp_content_and_tool",
    'object: "response",
    created_at: 1234567890,
    model: "gpt-4o",
    status: "completed",
    'error: (),
    incomplete_details: (),
    instructions: (),
    metadata: (),
    tool_choice: "auto",
    tools: [],
    parallel_tool_calls: false,
    output: [
        {
            id: "msg_ct",
            'type: "message",
            role: "assistant",
            status: "completed",
            content: [
                {
                    'type: "output_text",
                    text: "Let me check the weather.",
                    annotations: []
                }
            ]
        },
        {
            id: "fc_ct",
            'type: "function_call",
            name: "get_weather",
            arguments: "{\"city\": \"Berlin\"}",
            call_id: "call_ct",
            status: "completed"
        }
    ],
    output_text: "Let me check the weather."
};
