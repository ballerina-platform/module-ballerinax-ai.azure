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
 * This class provides the native function to generate a response from an Azure AI model.
 *
 * @since 1.0.0
 */
public class Generator {
    public static Object generate(Environment env, BObject modelProvider,
                                  BObject prompt, BTypedesc expectedResponseTypedesc) {
        return env.getRuntime().callFunction(
                new Module("ballerinax", "ai.azure", "1"), "generateLlmResponse", null,
                modelProvider.get(StringUtils.fromString("llmClient")), 
                modelProvider.get(StringUtils.fromString("deploymentId")), 
                modelProvider.get(StringUtils.fromString("apiVersion")),
                modelProvider.get(StringUtils.fromString("temperature")), 
                modelProvider.get(StringUtils.fromString("generatorConfig")),
                modelProvider.get(StringUtils.fromString("maxTokens")),
                prompt, expectedResponseTypedesc);
    }
}
