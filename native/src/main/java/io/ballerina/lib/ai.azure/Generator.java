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
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BTypedesc;

import java.util.Locale;

/**
 * This class provides the native function to generate a response from an Azure AI model.
 * Tries the Responses API first; falls back to Chat Completions if the model is not supported.
 *
 * <p>Two model provider shapes are supported:
 * <ul>
 *     <li>{@code OpenAiModelProviderV2} — uses the v1 (GA) Azure OpenAI connectors
 *         ({@code llmClient}/{@code responsesClient}).</li>
 *     <li>{@code OpenAiModelProvider} — uses a plain {@code http:Client} ({@code httpClient}) against the
 *         legacy deployment-scoped Azure OpenAI endpoints.</li>
 * </ul>
 *
 * @since 1.0.0
 */
public class Generator {
    private static final Module MODULE = new Module("ballerinax", "ai.azure", "1");
    private static final String LEGACY_PROVIDER_TYPE_NAME = "OpenAiModelProvider";

    private static final String RESPONSES_API_UNSUPPORTED = "responsesApiUnsupported";
    private static final String RESPONSES_CLIENT = "responsesClient";
    private static final String LLM_CLIENT = "llmClient";
    private static final String HTTP_CLIENT = "httpClient";
    private static final String API_KEY = "apiKey";
    private static final String DEPLOYMENT_ID = "deploymentId";
    private static final String API_VERSION = "apiVersion";
    private static final String TEMPERATURE = "temperature";
    private static final String MAX_TOKENS = "maxTokens";
    private static final String REASONING = "reasoning";

    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        if (LEGACY_PROVIDER_TYPE_NAME.equals(modelProvider.getType().getName())) {
            return generateLegacy(env, modelProvider, prompt, expectedResponseTypedesc);
        }
        return generateV2(env, modelProvider, prompt, expectedResponseTypedesc);
    }

    private static Object generateV2(Environment env, BObject modelProvider,
                                     BObject prompt, BTypedesc expectedResponseTypedesc) {
        boolean responsesUnsupported = modelProvider.getBooleanValue(StringUtils.fromString(RESPONSES_API_UNSUPPORTED));

        if (!responsesUnsupported) {
            Object result = env.getRuntime().callFunction(
                    MODULE, "generateLlmResponseViaResponses", null,
                    modelProvider.get(StringUtils.fromString(RESPONSES_CLIENT)),
                    modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                    modelProvider.get(StringUtils.fromString(API_VERSION)),
                    modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                    modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                    prompt, expectedResponseTypedesc);

            if (result instanceof BError error) {
                if (isModelNotSupportedError(error)) {
                    modelProvider.set(StringUtils.fromString(RESPONSES_API_UNSUPPORTED), true);
                    // Fall through to Chat Completions
                } else {
                    return result;
                }
            } else {
                return result;
            }
        }

        // Fallback: Chat Completions
        return env.getRuntime().callFunction(
                MODULE, "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString(LLM_CLIENT)),
                modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                modelProvider.get(StringUtils.fromString(API_VERSION)),
                modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                prompt, expectedResponseTypedesc);
    }

    private static Object generateLegacy(Environment env, BObject modelProvider,
                                         BObject prompt, BTypedesc expectedResponseTypedesc) {
        boolean responsesUnsupported = modelProvider.getBooleanValue(StringUtils.fromString(RESPONSES_API_UNSUPPORTED));

        if (!responsesUnsupported) {
            Object result = env.getRuntime().callFunction(
                    MODULE, "generateLlmResponseViaResponsesHttp", null,
                    modelProvider.get(StringUtils.fromString(HTTP_CLIENT)),
                    modelProvider.get(StringUtils.fromString(API_KEY)),
                    modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                    modelProvider.get(StringUtils.fromString(API_VERSION)),
                    modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                    modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                    modelProvider.get(StringUtils.fromString(REASONING)),
                    prompt, expectedResponseTypedesc);

            if (result instanceof BError error) {
                if (isModelNotSupportedError(error)) {
                    modelProvider.set(StringUtils.fromString(RESPONSES_API_UNSUPPORTED), true);
                    // Fall through to Chat Completions
                } else {
                    return result;
                }
            } else {
                return result;
            }
        }

        // Fallback: Chat Completions
        return env.getRuntime().callFunction(
                MODULE, "generateLlmResponseHttp", null,
                modelProvider.get(StringUtils.fromString(HTTP_CLIENT)),
                modelProvider.get(StringUtils.fromString(API_KEY)),
                modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                modelProvider.get(StringUtils.fromString(API_VERSION)),
                modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                prompt, expectedResponseTypedesc);
    }

    private static boolean isModelNotSupportedError(BError error) {
        if (containsUnsupportedMarker(error.getMessage())) {
            return true;
        }
        BError cause = error.getCause();
        return cause != null && containsUnsupportedMarker(cause.getMessage());
    }

    private static boolean containsUnsupportedMarker(Object message) {
        if (message == null) {
            return false;
        }
        String text = message.toString().toLowerCase(Locale.ROOT);
        return text.contains("model_not_found")
                || text.contains("operationnotsupported")
                || text.contains("the api deployment for this resource does not exist")
                || text.contains("unknown api version")
                || text.contains("invalid api version")
                || text.contains("not supported")
                || text.contains("404");
    }
}
