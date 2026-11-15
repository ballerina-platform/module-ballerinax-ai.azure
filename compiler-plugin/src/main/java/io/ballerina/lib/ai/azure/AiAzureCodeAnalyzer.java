/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
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

import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.projects.plugins.CodeAnalysisContext;
import io.ballerina.projects.plugins.CodeAnalyzer;

import java.util.List;

/**
 * Validates the services of the Ballerina Azure AI package at compile time.
 *
 * @since 1.6.0
 */
public class AiAzureCodeAnalyzer extends CodeAnalyzer {

    @Override
    public void init(CodeAnalysisContext context) {
        context.addSyntaxNodeAnalysisTask(new FoundryServiceValidationTask(), List.of(SyntaxKind.SERVICE_DECLARATION,
                SyntaxKind.CLASS_DEFINITION, SyntaxKind.OBJECT_CONSTRUCTOR));
    }
}
