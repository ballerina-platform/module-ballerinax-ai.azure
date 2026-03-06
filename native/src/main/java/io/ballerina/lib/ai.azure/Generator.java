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
 * @since 1.0.0
 */
public class Generator {
    private static final Module MODULE = new Module("ballerinax", "ai.azure", "1");

    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        boolean responsesUnsupported = modelProvider.getBooleanValue(
                StringUtils.fromString("responsesApiUnsupported"));

        if (!responsesUnsupported) {
            Object result = env.getRuntime().callFunction(
                    MODULE, "generateLlmResponseViaResponses", null,
                    modelProvider.get(StringUtils.fromString("responsesClient")),
                    modelProvider.get(StringUtils.fromString("deploymentId")),
                    modelProvider.get(StringUtils.fromString("apiVersion")),
                    prompt, expectedResponseTypedesc,
                    modelProvider.get(StringUtils.fromString("reasoning")));

            if (result instanceof BError) {
                BError error = (BError) result;
                if (isModelNotSupportedError(error)) {
                    modelProvider.set(StringUtils.fromString("responsesApiUnsupported"), true);
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
                modelProvider.get(StringUtils.fromString("llmClient")),
                modelProvider.get(StringUtils.fromString("deploymentId")),
                modelProvider.get(StringUtils.fromString("apiVersion")),
                modelProvider.get(StringUtils.fromString("temperature")),
                modelProvider.get(StringUtils.fromString("maxTokens")),
                prompt, expectedResponseTypedesc);
    }

    private static boolean isModelNotSupportedError(BError error) {
        String message = error.getMessage().toLowerCase(Locale.ROOT);
        if (message.contains("model_not_found") || message.contains("not supported")) {
            return true;
        }
        Throwable cause = error.getCause();
        if (cause != null) {
            String causeMsg = ((BError) cause).getMessage().toLowerCase(Locale.ROOT);
            return causeMsg.contains("model_not_found") || causeMsg.contains("not supported");
        }
        return false;
    }
}
