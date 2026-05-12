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
import ballerina/ai.observe;
import ballerina/http;
import ballerinax/azure.openai.responses as responses;

// Raw-HTTP variants of the structured-output ("generate") helpers used by the legacy `OpenAiModelProvider`.
// These mirror `generateLlmResponse` / `generateLlmResponseViaResponses` but hit the legacy Azure OpenAI
// deployment-scoped endpoints via a plain `http:Client` instead of the v1-spec connectors.

# Generates a structured response from the LLM via the legacy Azure OpenAI Chat Completions endpoint
# (`POST {serviceUrl}/openai/deployments/{deploymentId}/chat/completions?api-version=...`).
#
# + httpClient - The HTTP client targeting the Azure OpenAI resource base URL
# + apiKey - The Azure OpenAI API key (sent as the `api-key` header)
# + deploymentId - The Azure deployment ID
# + apiVersion - The Azure API version
# + temperature - The sampling temperature for the response
# + maxTokens - The maximum number of tokens to generate in the response
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response or an error
isolated function generateLlmResponseHttp(http:Client httpClient, string apiKey, string deploymentId,
        string apiVersion, decimal temperature, int maxTokens, ai:Prompt prompt,
        typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    span.addProvider("azure.ai.openai");
    span.addTemperature(temperature);

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    map<json> request = {
        messages: [{role: ai:USER, "content": content.toJson()}],
        temperature: temperature,
        max_tokens: maxTokens,
        functions: [
            {
                name: GET_RESULTS_TOOL,
                parameters: responseSchema.schema,
                description: "Tool to call with the response from a large language model (LLM) for a user prompt."
            }
        ],
        function_call: {name: GET_RESULTS_TOOL}
    };
    span.addInputMessages(request["messages"]);

    string path = string `/openai/deployments/${deploymentId}/chat/completions?api-version=${apiVersion}`;
    json|error response = httpClient->post(path, request, headers = {"api-key": apiKey});
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), cause = response.cause(), detail = response.detail());
        span.close(err);
        return err;
    }

    LegacyChatCompletionResponse|error typedResponse = response.cloneWithType();
    if typedResponse is error {
        ai:Error err = error("Error while parsing the LLM response", typedResponse);
        span.close(err);
        return err;
    }

    LegacyChatChoice[] choices = typedResponse.choices ?: [];
    if choices.length() == 0 {
        ai:Error err = error("No completion choices");
        span.close(err);
        return err;
    }
    string? finishReason = choices[0].finish_reason;
    if finishReason is string {
        span.addFinishReason(finishReason);
    }
    string? responseId = typedResponse.id;
    if responseId is string {
        span.addResponseId(responseId);
    }
    LegacyChatUsage? usage = typedResponse.usage;
    if usage is LegacyChatUsage {
        int? inputTokens = usage.prompt_tokens;
        if inputTokens is int {
            span.addInputTokenCount(inputTokens);
        }
        int? outputTokens = usage.completion_tokens;
        if outputTokens is int {
            span.addOutputTokenCount(outputTokens);
        }
    }

    LegacyFunctionCall? functionCall = choices[0].message?.function_call;
    if functionCall is () {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    map<json>|error arguments = functionCall.arguments.fromJsonStringWithType();
    if arguments is error {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}

# Generates a structured response from the LLM via the legacy Azure OpenAI Responses endpoint
# (`POST {serviceUrl}/openai/responses?api-version=...`).
#
# + httpClient - The HTTP client targeting the Azure OpenAI resource base URL
# + apiKey - The Azure OpenAI API key (sent as the `api-key` header)
# + deploymentId - The Azure deployment ID (used as the model name)
# + apiVersion - The Azure API version
# + temperature - The sampling temperature for the response
# + maxTokens - The maximum number of tokens to generate in the response
# + reasoning - Reasoning configuration for reasoning models, if any
# + prompt - The user prompt
# + expectedResponseTypedesc - The expected response type descriptor
# + return - The parsed response or an error
isolated function generateLlmResponseViaResponsesHttp(http:Client httpClient, string apiKey, string deploymentId,
        string apiVersion, decimal temperature, int maxTokens, (responses:OpenAI\.Reasoning & readonly)? reasoning,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(deploymentId);
    span.addProvider("azure.ai.openai");

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    responses:OpenAI\.Tool|error getResultsTool = {
        'type: "function",
        name: GET_RESULTS_TOOL,
        parameters: responseSchema.schema,
        description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
        strict: false
    }.cloneWithType();
    if getResultsTool is error {
        ai:Error err = error("Failed to create getResults tool: " + getResultsTool.message());
        span.close(err);
        return err;
    }

    responses:OpenAI\.ToolChoiceParam|error toolChoice = {
        'type: "function",
        name: GET_RESULTS_TOOL
    }.cloneWithType();
    if toolChoice is error {
        ai:Error err = error("Failed to create tool choice: " + toolChoice.message());
        span.close(err);
        return err;
    }

    foreach DocumentContentPart part in content {
        if part is AudioContentPart {
            ai:Error err = error("Audio input is not supported in the Responses API.");
            span.close(err);
            return err;
        }
    }

    json[] responsesContent = convertContentPartsForResponses(content);
    responses:OpenAI\.InputParam inputMessage = [
        {
            "role": ai:USER,
            "content": responsesContent,
            'type: "message"
        }
    ];

    responses:OpenAI\.CreateResponse request = {
        model: deploymentId,
        input: inputMessage,
        tools: [getResultsTool],
        tool_choice: toolChoice,
        temperature: temperature,
        max_output_tokens: maxTokens,
        store: false
    };
    if reasoning is responses:OpenAI\.Reasoning {
        request.reasoning = reasoning;
    }
    span.addInputMessages([inputMessage].toJson());

    string path = string `/openai/responses?api-version=${apiVersion}`;
    json|error response = httpClient->post(path, request.toJson(), headers = {"api-key": apiKey});
    if response is error {
        ai:Error err = error("LLM call failed: " + response.message(), detail = response.detail(), cause = response.cause());
        span.close(err);
        return err;
    }

    responses:inline_response_200_5|error typedResponse = response.cloneWithType();
    if typedResponse is error {
        ai:Error err = error("Error while parsing the Responses API response", typedResponse);
        span.close(err);
        return err;
    }

    span.addResponseId(typedResponse.id);
    responses:OpenAI\.ResponseUsage? usage = typedResponse.usage;
    if usage is responses:OpenAI\.ResponseUsage {
        span.addInputTokenCount(usage.input_tokens);
        span.addOutputTokenCount(usage.output_tokens);
    }

    string? toolArguments = ();
    foreach responses:OpenAI\.OutputItem item in typedResponse.output {
        if item.'type == "function_call" {
            string? itemName = <string?>item["name"];
            if itemName == GET_RESULTS_TOOL {
                toolArguments = <string?>item["arguments"];
                break;
            }
        }
    }

    if toolArguments is () {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    map<json>|error arguments = toolArguments.fromJsonStringWithType();
    if arguments is error {
        ai:Error err = error(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}
