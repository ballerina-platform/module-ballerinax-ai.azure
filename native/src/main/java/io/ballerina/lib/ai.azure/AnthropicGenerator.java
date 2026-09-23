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
import io.ballerina.runtime.api.values.BTypedesc;

/**
 * This class provides the native function backing {@code AnthropicModelProvider.generate}.
 *
 * <p>Claude models on Azure are served through the Anthropic Messages API, which has a single route, so unlike
 * {@link Generator} there is no API surface to select: the call is forwarded to the module's
 * {@code generateAnthropicLlmResponse} function with the provider's configuration.
 *
 * @since 1.5.0
 */
public class AnthropicGenerator {
    private static final Module MODULE = new Module("ballerinax", "ai.azure", "1");

    private static final String GENERATE_FUNCTION = "generateAnthropicLlmResponse";

    private static final String ANTHROPIC_CLIENT = "anthropicClient";
    private static final String API_KEY = "apiKey";
    private static final String ANTHROPIC_VERSION = "anthropicVersion";
    private static final String DEPLOYMENT_ID = "deploymentId";
    private static final String MAX_TOKENS = "maxTokens";
    private static final String TEMPERATURE = "temperature";
    private static final String THINKING = "thinking";
    private static final String EFFORT = "effort";

    private AnthropicGenerator() {
    }

    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        return env.getRuntime().callFunction(
                MODULE, GENERATE_FUNCTION, null,
                modelProvider.get(StringUtils.fromString(ANTHROPIC_CLIENT)),
                modelProvider.get(StringUtils.fromString(API_KEY)),
                modelProvider.get(StringUtils.fromString(ANTHROPIC_VERSION)),
                modelProvider.get(StringUtils.fromString(DEPLOYMENT_ID)),
                modelProvider.get(StringUtils.fromString(MAX_TOKENS)),
                modelProvider.get(StringUtils.fromString(TEMPERATURE)),
                modelProvider.get(StringUtils.fromString(THINKING)),
                modelProvider.get(StringUtils.fromString(EFFORT)),
                prompt, expectedResponseTypedesc);
    }
}
