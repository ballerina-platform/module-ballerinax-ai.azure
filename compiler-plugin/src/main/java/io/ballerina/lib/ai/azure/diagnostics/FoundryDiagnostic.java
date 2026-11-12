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

package io.ballerina.lib.ai.azure.diagnostics;

import io.ballerina.tools.diagnostics.Diagnostic;
import io.ballerina.tools.diagnostics.DiagnosticFactory;
import io.ballerina.tools.diagnostics.DiagnosticInfo;
import io.ballerina.tools.diagnostics.DiagnosticSeverity;
import io.ballerina.tools.diagnostics.Location;

import static io.ballerina.tools.diagnostics.DiagnosticSeverity.ERROR;

/**
 * Compilation diagnostics for an {@code azure:FoundryInvocationService}.
 *
 * <p>Each message is a {@link java.text.MessageFormat} template. The codes use the {@code AI_AZURE_FOUNDRY_} prefix
 * so they can't clash with the diagnostics of {@code ballerina/http}, {@code ballerina/ai} or other packages.
 *
 * @since 1.6.0
 */
public enum FoundryDiagnostic {

    MISSING_INVOKE_RESOURCE("AI_AZURE_FOUNDRY_101",
            "an `azure:FoundryInvocationService` must declare a `resource function post invocations`, which "
                    + "serves `POST /invocations`.", ERROR),
    UNSUPPORTED_RESOURCE("AI_AZURE_FOUNDRY_102",
            "the resource ''{0}'' is not supported in an `azure:FoundryInvocationService`, which serves only "
                    + "`post invocations`, `get invocations/[string invocationId]` and "
                    + "`post invocations/[string invocationId]/cancel`.", ERROR),
    REMOTE_FUNCTION_NOT_ALLOWED("AI_AZURE_FOUNDRY_103",
            "the remote function ''{0}'' is not allowed in an `azure:FoundryInvocationService`; declare "
                    + "resource functions instead.", ERROR),
    UNSUPPORTED_PARAMETER("AI_AZURE_FOUNDRY_104",
            "the parameter ''{1}'' of the resource ''{0}'' is not supported. Declare only {2}.", ERROR),
    DUPLICATE_PAYLOAD_PARAMETER("AI_AZURE_FOUNDRY_105",
            "the resource ''{0}'' declares more than one `@http:Payload` parameter.", ERROR),
    DUPLICATE_CONTEXT_PARAMETER("AI_AZURE_FOUNDRY_106",
            "the resource ''{0}'' declares more than one `azure:FoundryContext` parameter.", ERROR),
    INVALID_PAYLOAD_TYPE("AI_AZURE_FOUNDRY_107",
            "the `@http:Payload` parameter ''{1}'' of the resource ''{0}'' must be a subtype of `anydata` (for "
                    + "example `json`, `string`, `byte[]`, `xml` or a record), found ''{2}''.", ERROR),
    PAYLOAD_NOT_ALLOWED("AI_AZURE_FOUNDRY_108",
            "the resource ''{0}'' can''t declare an `@http:Payload` parameter, because a `GET` request has no "
                    + "body to bind.", ERROR),
    INVALID_PATH_PARAMETER_TYPE("AI_AZURE_FOUNDRY_109",
            "the path parameter ''{1}'' of the resource ''{0}'' must be of type `string`, found ''{2}''.", ERROR),
    INVALID_RETURN_TYPE("AI_AZURE_FOUNDRY_110",
            "the resource ''{0}'' must return a subtype of "
                    + "`anydata|http:Response|http:StatusCodeResponse|error`, found ''{1}''.", ERROR),
    STREAM_RETURN_TYPE("AI_AZURE_FOUNDRY_111",
            "the resource ''{0}'' returns a stream (''{1}''), but streaming responses are not supported by "
                    + "`azure:FoundryListener`; return the complete response instead.", ERROR),
    INVALID_BASE_PATH("AI_AZURE_FOUNDRY_112",
            "an `azure:FoundryInvocationService` must be attached at the root base path, because Foundry calls "
                    + "`/readiness` and `/invocations` at the root; remove the base path ''{0}''.", ERROR);

    private final String code;
    private final String message;
    private final DiagnosticSeverity severity;

    FoundryDiagnostic(String code, String message, DiagnosticSeverity severity) {
        this.code = code;
        this.message = message;
        this.severity = severity;
    }

    /**
     * Creates the diagnostic at the given location.
     *
     * @param diagnostic the kind of diagnostic
     * @param location   where the diagnostic points
     * @param args       the values of the message template's placeholders
     * @return the diagnostic
     */
    public static Diagnostic createDiagnostic(FoundryDiagnostic diagnostic, Location location, Object... args) {
        DiagnosticInfo info = new DiagnosticInfo(diagnostic.code, diagnostic.message, diagnostic.severity);
        return DiagnosticFactory.createDiagnostic(info, location, args);
    }

    public String getCode() {
        return code;
    }

    public String getMessage() {
        return message;
    }

    public DiagnosticSeverity getSeverity() {
        return severity;
    }
}
