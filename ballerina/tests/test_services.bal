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

service /llm on new http:Listener(8080) {

    // Chat Completions API mock endpoint — legacy deployment-scoped route used when the service URL does NOT end
    // with `/v1`. The `api-version` query parameter is REQUIRED on this route.
    resource function post azureopenai/openai/deployments/[string deploymentId]/chat/completions(
            string api\-version, @http:Payload json payload) returns json|error {
        // Regression guard for the max_tokens -> max_completion_tokens fix: verify the wire body carries the
        // correct token-limit field for the api-version. Applies to both the chat() and generate() paths.
        assertChatCompletionTokenField(api\-version, payload);
        // The legacy deployment-scoped route carries the deployment in the URL, so a body-level `model` must not
        // be sent.
        test:assertTrue(payload.model is error,
                "Chat Completions (legacy): 'model' must not be present in the body (deployment is in the URL)");
        return respondToChatCompletion(payload);
    }

    // Chat Completions API mock endpoint — v1 GA surface used when the service URL ends with `/v1`. This route
    // must NOT carry an `api-version` query parameter, and the deployment is sent as `model` in the body.
    resource function post azureopenai/openai/v1/chat/completions(@http:Payload json payload) returns json|error {
        string? model = check payload.model.ensureType();
        test:assertEquals(model, DEPLOYMENT_ID,
                "Chat Completions (v1): the deployment must be sent as 'model' in the body");
        // The v1 GA surface always uses `max_completion_tokens`.
        test:assertTrue(payload.max_completion_tokens !is error,
                "Chat Completions (v1): 'max_completion_tokens' expected");
        test:assertTrue(payload.max_tokens is error,
                "Chat Completions (v1): deprecated 'max_tokens' must not be present");
        return respondToChatCompletion(payload);
    }

    // Responses API mock endpoint — legacy preview route. Used when the service URL does NOT end with `/v1`.
    // The `api-version` query parameter is REQUIRED on this route; declaring it as a non-optional parameter makes
    // the mock reject (and the test fail) if the provider ever drops it.
    resource function post azureopenai/openai/responses(string api\-version, @http:Payload json payload)
            returns json|error {
        test:assertEquals(api\-version, API_VERSION,
                "Responses API (legacy preview): unexpected or missing api-version query parameter");
        return handleResponsesApiRequest(payload);
    }

    // Responses API mock endpoint — v1 GA surface. Used when the service URL ends with `/v1`.
    // This route must NOT carry an `api-version` query parameter.
    resource function post azureopenai/openai/v1/responses(@http:Payload json payload)
            returns json|error {
        return handleResponsesApiRequest(payload);
    }

    resource function post deployments/[string deploymentId]/embeddings(string api\-version, embeddings:Deploymentid_embeddings_body payload)
        returns embeddings:Inline_response_200|error {
        embeddings:Inline_response_200_data[] data = from int i in 0 ..< 2
            select {
                embedding: from int j in 0 ..< 1536
                    select 0.1 + j * 0.1,
                index: i,
                'object: "list"
            };
        return {
            data: payload.input is embeddings:InputItemsString[] ? data : [data[0]],
            model: "text-embedding-3-small",
            usage: {
                prompt_tokens: 15,
                total_tokens: 15
            },
            'object: "list"
        };
    }
}

// Shared classify-and-respond logic for both Chat Completions mock routes (legacy and v1 GA).
isolated function respondToChatCompletion(json payload) returns json|error {
    json[] messages = check (check payload.messages).ensureType();

    // Regression guard for reasoning_effort: none of the test providers request an effort, and the new connector
    // does not default it, so it must never reach the wire.
    test:assertTrue(payload.reasoning_effort is error,
            "Chat Completions: reasoning_effort must be absent when no effort was requested");

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

    // chat() path: return a get_weather tool call when tools are present, otherwise a text response.
    if hasOtherTool {
        return getChatCompletionToolCallResponse("get_weather", "{\"city\": \"London\"}");
    }
    return getChatCompletionContentResponse(getUserMessageContent(messages));
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
