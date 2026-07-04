/*
 * Copyright (c) 2025, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package io.ballerina.lib.ai.azure;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.api.values.BTypedesc;

/**
 * This class provides the native function to generate a response from an Azure AI model.
 *
 * <p>The {@code OpenAiModelProvider} selects its API surface through the {@code apiType} field. When it is
 * {@code CHAT_COMPLETION}, the request is routed to the Chat Completions API ({@code llmClient}); otherwise
 * (the default {@code RESPONSES}) it is routed to the Responses API. The Responses path in turn selects the
 * v1 GA connector ({@code responsesClient}) or the legacy preview raw HTTP client
 * ({@code legacyResponsesClient}) based on the {@code useV1Responses} flag.
 *
 * @since 1.0.0
 */
public class Generator {
    private static final Module MODULE = new Module("ballerinax", "ai.azure", "1");

    private static final String CHAT_COMPLETION = "CHAT_COMPLETION";

    private static final String API_TYPE = "apiType";
    private static final String RESPONSES_CLIENT = "responsesClient";
    private static final String LEGACY_RESPONSES_CLIENT = "legacyResponsesClient";
    private static final String USE_V1_RESPONSES = "useV1Responses";
    private static final String API_KEY = "apiKey";
    private static final String LLM_CLIENT = "llmClient";
    private static final String DEPLOYMENT_ID = "deploymentId";
    private static final String API_VERSION = "apiVersion";
    private static final String TEMPERATURE = "temperature";
    private static final String MAX_TOKENS = "maxTokens";
    private static final String REASONING = "reasoning";

    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        Object apiType = modelProvider.get(StringUtils.fromString(API_TYPE));
        if (apiType instanceof BString apiTypeStr && CHAT_COMPLETION.equals(apiTypeStr.getValue())) {
            return generateViaChatCompletions(env, modelProvider, prompt, expectedResponseTypedesc);
        }
        return generateViaResponses(env, modelProvider, prompt, expectedResponseTypedesc);
    }

    private static Object generateViaResponses(Environment env, BObject modelProvider,
                                               BObject prompt, BTypedesc expectedResponseTypedesc) {
        return env.getRuntime().callFunction(
                MODULE, "generateLlmResponseViaResponses", null,
                modelProvider.get(StringUtils.fromString(RESPONSES_CLIENT)),
                modelProvider.get(StringUtils.fromString(LEGACY_RESPONSES_CLIENT)),
                modelProvider.get(StringUtils.fromString(USE_V1_RESPONSES)),
                modelProvider.get(StringUtils.fromString(API_KEY)),
                modelProvider.get(StringUtils.fromString(API_VERSION)),
                modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                modelProvider.get(StringUtils.fromString(REASONING)),
                prompt, expectedResponseTypedesc);
    }

    private static Object generateViaChatCompletions(Environment env, BObject modelProvider,
                                                     BObject prompt, BTypedesc expectedResponseTypedesc) {
        return env.getRuntime().callFunction(
                MODULE, "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString(LLM_CLIENT)),
                modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                modelProvider.get(StringUtils.fromString(API_VERSION)),
                modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                prompt, expectedResponseTypedesc);
    }
}
