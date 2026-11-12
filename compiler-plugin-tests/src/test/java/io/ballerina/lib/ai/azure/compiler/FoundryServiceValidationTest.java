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

package io.ballerina.lib.ai.azure.compiler;

import io.ballerina.projects.DiagnosticResult;
import io.ballerina.projects.Project;
import io.ballerina.projects.ProjectEnvironmentBuilder;
import io.ballerina.projects.directory.ProjectLoader;
import io.ballerina.projects.environment.Environment;
import io.ballerina.projects.environment.EnvironmentBuilder;
import io.ballerina.tools.diagnostics.Diagnostic;
import io.ballerina.tools.diagnostics.DiagnosticSeverity;
import io.ballerina.tools.text.LinePosition;
import org.testng.Assert;
import org.testng.annotations.Test;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;


/**
 * Tests the compile-time validation of {@code azure:FoundryInvocationService}.
 *
 * <p>Each test compiles a small Ballerina package against a Ballerina distribution that holds the freshly built
 * {@code ballerinax/ai.azure} bala (see the {@code prepareBallerinaDistribution} task) and asserts the exact Foundry
 * diagnostics: code, severity, message and position, in source order.
 */
public class FoundryServiceValidationTest {

    private static final Path RESOURCE_DIRECTORY = Paths.get("src", "test", "resources", "ballerina_sources",
            "foundry_service_validation").toAbsolutePath();
    private static final Path DISTRIBUTION_PATH = Paths.get(System.getProperty("ai.azure.test.distribution",
            Paths.get("build", "ballerina-runtime").toString())).toAbsolutePath();
    private static final String FOUNDRY_CODE_PREFIX = "AI_AZURE_FOUNDRY_";

    // The diagnostic codes and messages are written out here rather than taken from the plugin's templates, so a
    // broken template (a wrong code, a quote MessageFormat swallows, a typo) fails the tests.
    private static final String MISSING_INVOKE_RESOURCE = "AI_AZURE_FOUNDRY_101";
    private static final String UNSUPPORTED_RESOURCE = "AI_AZURE_FOUNDRY_102";
    private static final String REMOTE_FUNCTION_NOT_ALLOWED = "AI_AZURE_FOUNDRY_103";
    private static final String UNSUPPORTED_PARAMETER = "AI_AZURE_FOUNDRY_104";
    private static final String DUPLICATE_PAYLOAD_PARAMETER = "AI_AZURE_FOUNDRY_105";
    private static final String DUPLICATE_CONTEXT_PARAMETER = "AI_AZURE_FOUNDRY_106";
    private static final String INVALID_PAYLOAD_TYPE = "AI_AZURE_FOUNDRY_107";
    private static final String PAYLOAD_NOT_ALLOWED = "AI_AZURE_FOUNDRY_108";
    private static final String INVALID_PATH_PARAMETER_TYPE = "AI_AZURE_FOUNDRY_109";
    private static final String INVALID_RETURN_TYPE = "AI_AZURE_FOUNDRY_110";
    private static final String STREAM_RETURN_TYPE = "AI_AZURE_FOUNDRY_111";
    private static final String INVALID_BASE_PATH = "AI_AZURE_FOUNDRY_112";

    private static final String INVOKE = "post invocations";
    private static final String GET = "get invocations/[string invocationId]";
    private static final String CANCEL = "post invocations/[string invocationId]/cancel";
    private static final String PAYLOAD_AND_CONTEXT = "an `@http:Payload` parameter and an `azure:FoundryContext` "
            + "parameter";
    private static final String CONTEXT_ONLY = "an `azure:FoundryContext` parameter";

    @Test
    public void testValidService() {
        assertDiagnostics("01_valid_service");
    }

    @Test
    public void testMissingInvokeResource() {
        assertDiagnostics("02_missing_invoke_resource",
                expect(MISSING_INVOKE_RESOURCE, 21, 9, missingInvokeResource()));
    }

    @Test
    public void testUnsupportedResources() {
        assertDiagnostics("03_unsupported_resource",
                expect(UNSUPPORTED_RESOURCE, 24, 23, unsupportedResource("get status")),
                expect(UNSUPPORTED_RESOURCE, 26, 23, unsupportedResource("get invocations")),
                expect(UNSUPPORTED_RESOURCE, 28, 23, unsupportedResource("put invocations/[string invocationId]")),
                expect(UNSUPPORTED_RESOURCE, 30, 23, unsupportedResource("patch invocations/[string... ids]")),
                expect(UNSUPPORTED_RESOURCE, 32, 23,
                        unsupportedResource("get invocations/[string invocationId]/cancel")),
                expect(UNSUPPORTED_RESOURCE, 34, 23, unsupportedResource("default [string... path]")),
                expect(UNSUPPORTED_RESOURCE, 36, 23, unsupportedResource("get .")));
    }

    @Test
    public void testRemoteFunction() {
        assertDiagnostics("04_remote_function",
                expect(REMOTE_FUNCTION_NOT_ALLOWED, 24, 21, remoteFunctionNotAllowed("ping")));
    }

    @Test
    public void testUnsupportedParameters() {
        assertDiagnostics("05_unsupported_parameter",
                expect(UNSUPPORTED_PARAMETER, 23, 68, unsupportedParameter(INVOKE, "extra", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_PARAMETER, 23, 82, unsupportedParameter(INVOKE, "request", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_PARAMETER, 24, 13, unsupportedParameter(INVOKE, "headers", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_PARAMETER, 24, 35, unsupportedParameter(INVOKE, "query", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_PARAMETER, 24, 61, unsupportedParameter(INVOKE, "caller", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_PARAMETER, 26, 61, unsupportedParameter(GET, "ctx", CONTEXT_ONLY)),
                expect(UNSUPPORTED_PARAMETER, 26, 88, unsupportedParameter(GET, "count", CONTEXT_ONLY)),
                expect(UNSUPPORTED_PARAMETER, 29, 69, unsupportedParameter(CANCEL, "reasons", PAYLOAD_AND_CONTEXT)));
    }

    @Test
    public void testDuplicatePayloadParameter() {
        assertDiagnostics("06_duplicate_payload",
                expect(DUPLICATE_PAYLOAD_PARAMETER, 23, 66, duplicatePayloadParameter(INVOKE)),
                expect(DUPLICATE_PAYLOAD_PARAMETER, 26, 39, duplicatePayloadParameter(CANCEL)));
    }

    @Test
    public void testDuplicateContextParameter() {
        assertDiagnostics("07_duplicate_context",
                expect(DUPLICATE_CONTEXT_PARAMETER, 22, 68, duplicateContextParameter(INVOKE)),
                expect(DUPLICATE_CONTEXT_PARAMETER, 24, 89, duplicateContextParameter(GET)));
    }

    @Test
    public void testInvalidPayloadType() {
        assertDiagnostics("08_invalid_payload_type",
                expect(INVALID_PAYLOAD_TYPE, 23, 54, invalidPayloadType(INVOKE, "payload", "azure:FoundryContext")),
                expect(INVALID_PAYLOAD_TYPE, 25, 83, invalidPayloadType(CANCEL, "reason", "any")));
    }

    @Test
    public void testPayloadOnGetResource() {
        assertDiagnostics("09_payload_on_get",
                expect(PAYLOAD_NOT_ALLOWED, 25, 61, payloadNotAllowed(GET)));
    }

    @Test
    public void testInvalidPathParameterType() {
        assertDiagnostics("10_invalid_path_parameter_type",
                expect(INVALID_PATH_PARAMETER_TYPE, 24, 40,
                        invalidPathParameterType("get invocations/[int invocationId]", "invocationId", "int")),
                expect(INVALID_PATH_PARAMETER_TYPE, 26, 41, invalidPathParameterType(
                        "post invocations/[boolean invocationId]/cancel", "invocationId", "boolean")));
    }

    @Test
    public void testInvalidReturnType() {
        assertDiagnostics("11_invalid_return_type",
                expect(INVALID_RETURN_TYPE, 23, 50, invalidReturnType(INVOKE, "any")),
                expect(INVALID_RETURN_TYPE, 25, 71, invalidReturnType(GET, "http:Request")),
                expect(INVALID_RETURN_TYPE, 27, 79, invalidReturnType(CANCEL, "json|Holder")));
    }

    @Test
    public void testStreamReturnType() {
        assertDiagnostics("12_stream_return_type",
                expect(STREAM_RETURN_TYPE, 22, 50, streamReturnType(INVOKE, "stream<string, error?>")),
                expect(STREAM_RETURN_TYPE, 24, 71, streamReturnType(GET, "json|stream<json>|error")));
    }

    @Test
    public void testInvalidBasePath() {
        assertDiagnostics("13_invalid_base_path",
                expect(INVALID_BASE_PATH, 22, 40, invalidBasePath("/agents/v1")),
                expect(INVALID_BASE_PATH, 26, 40, invalidBasePath("\"agent\"")),
                expect(INVALID_BASE_PATH, 34, 40, invalidBasePath("\"\\u{2F}a\"")),
                expect(INVALID_BASE_PATH, 39, 9, invalidBasePath("/api")));
    }

    @Test
    public void testImportAlias() {
        assertDiagnostics("14_import_alias",
                expect(UNSUPPORTED_PARAMETER, 23, 93, unsupportedParameter(INVOKE, "extra", PAYLOAD_AND_CONTEXT)),
                expect(UNSUPPORTED_RESOURCE, 26, 23, unsupportedResource("get status")));
    }

    @Test
    public void testServiceClassAndObjectConstructor() {
        assertDiagnostics("15_service_class_and_object",
                expect(MISSING_INVOKE_RESOURCE, 20, 24, missingInvokeResource()),
                expect(UNSUPPORTED_RESOURCE, 25, 32, unsupportedResource("get health")),
                expect(UNSUPPORTED_PARAMETER, 29, 68, unsupportedParameter(INVOKE, "extra", PAYLOAD_AND_CONTEXT)));
    }

    @Test
    public void testNonFoundryServicesIgnored() {
        assertDiagnostics("16_non_foundry_services_ignored");
    }

    @Test
    public void testUntypedServiceDeclaration() {
        assertDiagnostics("17_untyped_service_declaration",
                expect(MISSING_INVOKE_RESOURCE, 24, 1, missingInvokeResource()),
                expect(UNSUPPORTED_RESOURCE, 25, 23, unsupportedResource("get status")),
                expect(UNSUPPORTED_PARAMETER, 27, 61, unsupportedParameter(GET, "extra", CONTEXT_ONLY)),
                expect(STREAM_RETURN_TYPE, 27, 83, streamReturnType(GET, "stream<json>")),
                expect(MISSING_INVOKE_RESOURCE, 30, 10, missingInvokeResource()),
                expect(REMOTE_FUNCTION_NOT_ALLOWED, 31, 30, remoteFunctionNotAllowed("ping")),
                expect(INVALID_BASE_PATH, 34, 9, invalidBasePath("/agents")),
                expect(UNSUPPORTED_PARAMETER, 35, 40, unsupportedParameter(INVOKE, "request", PAYLOAD_AND_CONTEXT)));
    }

    private static void assertDiagnostics(String packageName, ExpectedDiagnostic... expected) {
        DiagnosticResult result = compile(packageName);
        List<Diagnostic> otherErrors = result.errors().stream()
                .filter(diagnostic -> !isFoundryDiagnostic(diagnostic))
                .collect(Collectors.toList());
        Assert.assertTrue(otherErrors.isEmpty(), "Unexpected compilation errors: " + describe(otherErrors));

        List<Diagnostic> actual = result.diagnostics().stream()
                .filter(FoundryServiceValidationTest::isFoundryDiagnostic)
                .sorted(Comparator.comparingInt((Diagnostic diagnostic) -> start(diagnostic).line())
                        .thenComparingInt(diagnostic -> start(diagnostic).offset()))
                .collect(Collectors.toList());
        Assert.assertEquals(actual.size(), expected.length, "Foundry diagnostics: " + describe(actual));
        for (int i = 0; i < expected.length; i++) {
            Diagnostic diagnostic = actual.get(i);
            ExpectedDiagnostic expectation = expected[i];
            String context = "diagnostic " + i + ": " + describe(List.of(diagnostic));
            Assert.assertEquals(diagnostic.diagnosticInfo().code(), expectation.code, context);
            Assert.assertEquals(diagnostic.diagnosticInfo().severity(), DiagnosticSeverity.ERROR, context);
            Assert.assertEquals(diagnostic.message(), expectation.message, context);
            // The compiler counts lines and columns from zero.
            Assert.assertEquals(start(diagnostic).line() + 1, expectation.line, context);
            Assert.assertEquals(start(diagnostic).offset() + 1, expectation.column, context);
        }
    }

    private static DiagnosticResult compile(String packageName) {
        Environment environment = EnvironmentBuilder.getBuilder().setBallerinaHome(DISTRIBUTION_PATH).build();
        Project project = ProjectLoader.load(RESOURCE_DIRECTORY.resolve(packageName),
                ProjectEnvironmentBuilder.getBuilder(environment)).project();
        // As `bal build` does: code generators and modifiers first, then the compilation with the code analyzers.
        project.currentPackage().runCodeGenAndModifyPlugins();
        return project.currentPackage().getCompilation().diagnosticResult();
    }

    private static boolean isFoundryDiagnostic(Diagnostic diagnostic) {
        return diagnostic.diagnosticInfo().code() != null
                && diagnostic.diagnosticInfo().code().startsWith(FOUNDRY_CODE_PREFIX);
    }

    private static LinePosition start(Diagnostic diagnostic) {
        return diagnostic.location().lineRange().startLine();
    }

    private static String describe(List<Diagnostic> diagnostics) {
        return diagnostics.stream()
                .map(diagnostic -> diagnostic.diagnosticInfo().code() + " " + diagnostic.location().lineRange()
                        + " " + diagnostic.message())
                .collect(Collectors.joining(System.lineSeparator(), System.lineSeparator(), ""));
    }

    private static ExpectedDiagnostic expect(String code, int line, int column, String message) {
        return new ExpectedDiagnostic(code, line, column, message);
    }

    private static String missingInvokeResource() {
        return "an `azure:FoundryInvocationService` must declare a `resource function post invocations`, which "
                + "serves `POST /invocations`.";
    }

    private static String unsupportedResource(String resource) {
        return "the resource '" + resource + "' is not supported in an `azure:FoundryInvocationService`, which "
                + "serves only `post invocations`, `get invocations/[string invocationId]` and "
                + "`post invocations/[string invocationId]/cancel`.";
    }

    private static String remoteFunctionNotAllowed(String function) {
        return "the remote function '" + function + "' is not allowed in an `azure:FoundryInvocationService`; "
                + "declare resource functions instead.";
    }

    private static String unsupportedParameter(String resource, String parameter, String allowed) {
        return "the parameter '" + parameter + "' of the resource '" + resource + "' is not supported. Declare only "
                + allowed + ".";
    }

    private static String duplicatePayloadParameter(String resource) {
        return "the resource '" + resource + "' declares more than one `@http:Payload` parameter.";
    }

    private static String duplicateContextParameter(String resource) {
        return "the resource '" + resource + "' declares more than one `azure:FoundryContext` parameter.";
    }

    private static String invalidPayloadType(String resource, String parameter, String type) {
        return "the `@http:Payload` parameter '" + parameter + "' of the resource '" + resource + "' must be a "
                + "subtype of `anydata` (for example `json`, `string`, `byte[]`, `xml` or a record), found '" + type
                + "'.";
    }

    private static String payloadNotAllowed(String resource) {
        return "the resource '" + resource + "' can't declare an `@http:Payload` parameter, because a `GET` request "
                + "has no body to bind.";
    }

    private static String invalidPathParameterType(String resource, String parameter, String type) {
        return "the path parameter '" + parameter + "' of the resource '" + resource + "' must be of type `string`, "
                + "found '" + type + "'.";
    }

    private static String invalidReturnType(String resource, String type) {
        return "the resource '" + resource + "' must return a subtype of "
                + "`anydata|http:Response|http:StatusCodeResponse|error`, found '" + type + "'.";
    }

    private static String streamReturnType(String resource, String type) {
        return "the resource '" + resource + "' returns a stream ('" + type + "'), but streaming responses are not "
                + "supported by `azure:FoundryListener`; return the complete response instead.";
    }

    private static String invalidBasePath(String basePath) {
        return "an `azure:FoundryInvocationService` must be attached at the root base path, because Foundry calls "
                + "`/readiness` and `/invocations` at the root; remove the base path '" + basePath + "'.";
    }

    /**
     * A diagnostic a test expects: its code, its message and its one-based start position.
     */
    private static final class ExpectedDiagnostic {
        private final String code;
        private final int line;
        private final int column;
        private final String message;

        ExpectedDiagnostic(String code, int line, int column, String message) {
            this.code = code;
            this.line = line;
            this.column = column;
            this.message = message;
        }
    }
}
