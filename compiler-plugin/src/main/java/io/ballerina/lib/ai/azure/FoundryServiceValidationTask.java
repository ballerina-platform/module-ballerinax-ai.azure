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

import io.ballerina.compiler.api.SemanticModel;
import io.ballerina.compiler.api.symbols.AnnotationSymbol;
import io.ballerina.compiler.api.symbols.ModuleSymbol;
import io.ballerina.compiler.api.symbols.ParameterSymbol;
import io.ballerina.compiler.api.symbols.PathParameterSymbol;
import io.ballerina.compiler.api.symbols.ResourceMethodSymbol;
import io.ballerina.compiler.api.symbols.ServiceDeclarationSymbol;
import io.ballerina.compiler.api.symbols.Symbol;
import io.ballerina.compiler.api.symbols.TypeDefinitionSymbol;
import io.ballerina.compiler.api.symbols.TypeDescKind;
import io.ballerina.compiler.api.symbols.TypeReferenceTypeSymbol;
import io.ballerina.compiler.api.symbols.TypeSymbol;
import io.ballerina.compiler.api.symbols.UnionTypeSymbol;
import io.ballerina.compiler.api.symbols.resourcepath.PathSegmentList;
import io.ballerina.compiler.syntax.tree.BasicLiteralNode;
import io.ballerina.compiler.syntax.tree.ClassDefinitionNode;
import io.ballerina.compiler.syntax.tree.DefaultableParameterNode;
import io.ballerina.compiler.syntax.tree.FunctionDefinitionNode;
import io.ballerina.compiler.syntax.tree.IncludedRecordParameterNode;
import io.ballerina.compiler.syntax.tree.Node;
import io.ballerina.compiler.syntax.tree.NodeList;
import io.ballerina.compiler.syntax.tree.ObjectConstructorExpressionNode;
import io.ballerina.compiler.syntax.tree.ParameterNode;
import io.ballerina.compiler.syntax.tree.RequiredParameterNode;
import io.ballerina.compiler.syntax.tree.ResourcePathParameterNode;
import io.ballerina.compiler.syntax.tree.RestParameterNode;
import io.ballerina.compiler.syntax.tree.ReturnTypeDescriptorNode;
import io.ballerina.compiler.syntax.tree.ServiceDeclarationNode;
import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.compiler.syntax.tree.Token;
import io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic;
import io.ballerina.projects.plugins.AnalysisTask;
import io.ballerina.projects.plugins.SyntaxNodeAnalysisContext;
import io.ballerina.tools.diagnostics.DiagnosticSeverity;
import io.ballerina.tools.diagnostics.Location;
import io.ballerina.tools.text.LineRange;
import io.ballerina.tools.text.TextRange;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;

import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.DUPLICATE_CONTEXT_PARAMETER;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.DUPLICATE_PAYLOAD_PARAMETER;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.INVALID_BASE_PATH;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.INVALID_PATH_PARAMETER_TYPE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.INVALID_PAYLOAD_TYPE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.INVALID_RETURN_TYPE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.MISSING_INVOKE_RESOURCE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.MISSING_READINESS_RESOURCE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.PAYLOAD_NOT_ALLOWED;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.READINESS_PARAMETER_NOT_ALLOWED;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.REMOTE_FUNCTION_NOT_ALLOWED;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.STREAM_RETURN_TYPE;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.UNSUPPORTED_PARAMETER;
import static io.ballerina.lib.ai.azure.diagnostics.FoundryDiagnostic.UNSUPPORTED_RESOURCE;

/**
 * Validates an {@code azure:FoundryInvocationService} against the resource contract of the Foundry listener.
 *
 * <p>The service type is only {@code *http:Service}, so the compiler accepts any resource. The listener's dispatcher
 * only ever calls four resources and supplies a fixed set of arguments, and anything else is answered at run time
 * with a {@code 500} (or never reached at all). This task rejects those shapes at compile time instead:
 * <ul>
 * <li>the service must declare {@code post invocations} and {@code get readiness};</li>
 * <li>the only resources are {@code post invocations}, {@code get readiness},
 * {@code get invocations/[string invocationId]} and {@code post invocations/[string invocationId]/cancel}; remote
 * functions are not allowed;</li>
 * <li>{@code get readiness} declares no parameters;</li>
 * <li>any other resource parameter is either the {@code @http:Payload} parameter (an {@code anydata} subtype; not on
 * the get resource) or an {@code azure:FoundryContext} parameter, each at most once and in any order, and the path
 * parameter is a {@code string};</li>
 * <li>a resource returns a subtype of {@code anydata|http:Response|http:StatusCodeResponse|error}, and never a
 * stream;</li>
 * <li>a service declaration is attached at the root base path.</li>
 * </ul>
 * Only services whose type is a subtype of {@code azure:FoundryInvocationService} are validated: service
 * declarations, service classes and service object constructors. A service declaration without a type descriptor
 * takes its type from the listener's {@code attach}, so it is validated when it is attached to an
 * {@code azure:FoundryListener}. Types are resolved through the semantic model, so
 * import prefixes (for example {@code import ballerinax/ai.azure as foundry;}) and type aliases are handled.
 *
 * @since 1.6.0
 */
public class FoundryServiceValidationTask implements AnalysisTask<SyntaxNodeAnalysisContext> {

    private static final String BALLERINA_ORG = "ballerina";
    private static final String BALLERINAX_ORG = "ballerinax";
    private static final String AI_AZURE_MODULE = "ai.azure";
    private static final String HTTP_MODULE = "http";
    private static final String EMPTY_VERSION = "";
    private static final String FOUNDRY_SERVICE_TYPE = "FoundryInvocationService";
    private static final String FOUNDRY_CONTEXT_TYPE = "FoundryContext";
    private static final String FOUNDRY_LISTENER_TYPE = "FoundryListener";
    private static final String HTTP_RESPONSE_TYPE = "Response";
    private static final String HTTP_STATUS_CODE_RESPONSE_TYPE = "StatusCodeResponse";
    private static final String PAYLOAD_ANNOTATION = "Payload";

    private static final String POST = "post";
    private static final String GET = "get";
    private static final String INVOCATIONS = "invocations";
    private static final String READINESS = "readiness";
    private static final String CANCEL = "cancel";
    private static final String PATH_PARAM = "^";

    private static final String PAYLOAD_AND_CONTEXT = "an `@http:Payload` parameter and an `azure:FoundryContext` "
            + "parameter";
    private static final String CONTEXT_ONLY = "an `azure:FoundryContext` parameter";

    @Override
    public void perform(SyntaxNodeAnalysisContext context) {
        SemanticModel semanticModel = context.semanticModel();
        Optional<TypeSymbol> foundryServiceType = resolveType(semanticModel, BALLERINAX_ORG, AI_AZURE_MODULE,
                FOUNDRY_SERVICE_TYPE);
        if (foundryServiceType.isEmpty()) {
            return;
        }
        Node node = context.node();
        switch (node.kind()) {
            case SERVICE_DECLARATION -> validateServiceDeclaration(context, semanticModel, foundryServiceType.get(),
                    (ServiceDeclarationNode) node);
            case CLASS_DEFINITION -> validateServiceClass(context, semanticModel, foundryServiceType.get(),
                    (ClassDefinitionNode) node);
            case OBJECT_CONSTRUCTOR -> validateObjectConstructor(context, semanticModel, foundryServiceType.get(),
                    (ObjectConstructorExpressionNode) node);
            default -> {
            }
        }
    }

    private static void validateServiceDeclaration(SyntaxNodeAnalysisContext context, SemanticModel semanticModel,
                                                   TypeSymbol foundryServiceType, ServiceDeclarationNode service) {
        if (!isFoundryServiceDeclaration(semanticModel, foundryServiceType, service)
                || hasCompilationErrors(semanticModel)) {
            return;
        }
        validateBasePath(context, service.absoluteResourcePath());
        // Without a type descriptor, the `service` keyword stands for the service.
        Location serviceLocation = service.typeDescriptor().map(Node::location)
                .orElseGet(() -> service.serviceKeyword().location());
        new ServiceValidator(context, semanticModel).validate(service.members(), serviceLocation);
    }

    // A declaration with a type descriptor is a Foundry service when that type is a subtype of the Foundry service
    // type. A declaration without one (`service on foundryListener { ... }`) takes its type from the listener's
    // `attach`, so it is a Foundry service when it is attached to an `azure:FoundryListener`.
    private static boolean isFoundryServiceDeclaration(SemanticModel semanticModel, TypeSymbol foundryServiceType,
                                                       ServiceDeclarationNode service) {
        Optional<Symbol> symbol = semanticModel.symbol(service);
        ServiceDeclarationSymbol serviceSymbol = symbol.isPresent()
                && symbol.get() instanceof ServiceDeclarationSymbol declaration ? declaration : null;
        if (service.typeDescriptor().isPresent()) {
            Optional<TypeSymbol> serviceType = serviceSymbol != null ? serviceSymbol.typeDescriptor()
                    : semanticModel.typeOf(service.typeDescriptor().get());
            return serviceType.isPresent() && serviceType.get().subtypeOf(foundryServiceType);
        }
        if (serviceSymbol != null && serviceSymbol.typeDescriptor().isPresent()
                && serviceSymbol.typeDescriptor().get().subtypeOf(foundryServiceType)) {
            return true;
        }
        Optional<TypeSymbol> foundryListenerType = resolveType(semanticModel, BALLERINAX_ORG, AI_AZURE_MODULE,
                FOUNDRY_LISTENER_TYPE);
        if (foundryListenerType.isEmpty()) {
            return false;
        }
        List<TypeSymbol> listenerTypes = new ArrayList<>();
        for (Node expression : service.expressions()) {
            semanticModel.typeOf(expression).ifPresent(listenerTypes::add);
        }
        if (serviceSymbol != null) {
            listenerTypes.addAll(serviceSymbol.listenerTypes());
        }
        for (TypeSymbol listenerType : listenerTypes) {
            // `new azure:FoundryListener(...)` can be typed `azure:FoundryListener|error`, so check each member.
            List<TypeSymbol> members = new ArrayList<>();
            collectMembers(listenerType, members);
            for (TypeSymbol member : members) {
                if (member.subtypeOf(foundryListenerType.get())) {
                    return true;
                }
            }
        }
        return false;
    }

    private static void validateServiceClass(SyntaxNodeAnalysisContext context, SemanticModel semanticModel,
                                             TypeSymbol foundryServiceType, ClassDefinitionNode serviceClass) {
        if (!hasQualifier(serviceClass.classTypeQualifiers(), SyntaxKind.SERVICE_KEYWORD)) {
            return;
        }
        Optional<Symbol> symbol = semanticModel.symbol(serviceClass);
        if (symbol.isEmpty() || !(symbol.get() instanceof TypeSymbol classType)
                || !classType.subtypeOf(foundryServiceType) || hasCompilationErrors(semanticModel)) {
            return;
        }
        new ServiceValidator(context, semanticModel).validate(serviceClass.members(),
                serviceClass.className().location());
    }

    private static void validateObjectConstructor(SyntaxNodeAnalysisContext context, SemanticModel semanticModel,
                                                  TypeSymbol foundryServiceType,
                                                  ObjectConstructorExpressionNode constructor) {
        if (!hasQualifier(constructor.objectTypeQualifiers(), SyntaxKind.SERVICE_KEYWORD)) {
            return;
        }
        Optional<TypeSymbol> type = semanticModel.typeOf(constructor);
        if (type.isEmpty() || !type.get().subtypeOf(foundryServiceType) || hasCompilationErrors(semanticModel)) {
            return;
        }
        Node first = constructor.objectTypeQualifiers().isEmpty() ? constructor.objectKeyword()
                : constructor.objectTypeQualifiers().get(0);
        Node last = constructor.typeReference().map(Node.class::cast).orElse(constructor.objectKeyword());
        new ServiceValidator(context, semanticModel).validate(constructor.members(), span(first, last));
    }

    // The listener accepts only the root base path (none, `/`, or a string made only of `/`): Foundry calls
    // `/readiness` and `/invocations` at the root. FoundryListener.attach rejects any other base path at run time.
    private static void validateBasePath(SyntaxNodeAnalysisContext context, NodeList<Node> basePath) {
        if (basePath.isEmpty()) {
            return;
        }
        boolean isRoot;
        if (basePath.size() == 1 && basePath.get(0).kind() == SyntaxKind.STRING_LITERAL) {
            // Match the literal's value, as FoundryListener.isRootBasePath does, not its source text.
            String text = ((BasicLiteralNode) basePath.get(0)).literalToken().text();
            String value = unescapeStringLiteral(text.length() >= 2 ? text.substring(1, text.length() - 1) : text);
            isRoot = value.trim().matches("/*");
        } else {
            isRoot = true;
            for (Node segment : basePath) {
                if (segment.kind() != SyntaxKind.SLASH_TOKEN) {
                    isRoot = false;
                    break;
                }
            }
        }
        if (!isRoot) {
            Location location = span(basePath.get(0), basePath.get(basePath.size() - 1));
            context.reportDiagnostic(FoundryDiagnostic.createDiagnostic(INVALID_BASE_PATH, location,
                    sourceText(basePath)));
        }
    }

    /**
     * Validates the members of one Foundry service.
     */
    private static final class ServiceValidator {
        private final SyntaxNodeAnalysisContext context;
        private final SemanticModel semanticModel;
        private final TypeSymbol anydataType;
        private final TypeSymbol errorType;
        private final TypeSymbol stringType;
        private final Optional<TypeSymbol> httpResponseType;
        private final Optional<TypeSymbol> statusCodeResponseType;
        // `anydata|error|http:Response|http:StatusCodeResponse`.
        private final Optional<TypeSymbol> supportedReturnType;

        ServiceValidator(SyntaxNodeAnalysisContext context, SemanticModel semanticModel) {
            this.context = context;
            this.semanticModel = semanticModel;
            this.anydataType = semanticModel.types().ANYDATA;
            this.errorType = semanticModel.types().ERROR;
            this.stringType = semanticModel.types().STRING;
            this.httpResponseType = resolveType(semanticModel, BALLERINA_ORG, HTTP_MODULE, HTTP_RESPONSE_TYPE);
            this.statusCodeResponseType = resolveType(semanticModel, BALLERINA_ORG, HTTP_MODULE,
                    HTTP_STATUS_CODE_RESPONSE_TYPE);
            this.supportedReturnType = httpResponseType.isPresent() && statusCodeResponseType.isPresent()
                    ? Optional.of(semanticModel.types().builder().UNION_TYPE.withMemberTypes(anydataType, errorType,
                    httpResponseType.get(), statusCodeResponseType.get()).build())
                    : Optional.empty();
        }

        void validate(NodeList<Node> members, Location serviceLocation) {
            boolean hasInvokeResource = false;
            boolean hasReadinessResource = false;
            for (Node member : members) {
                if (member.kind() == SyntaxKind.RESOURCE_ACCESSOR_DEFINITION) {
                    ResourceKind kind = validateResource((FunctionDefinitionNode) member);
                    hasInvokeResource |= kind == ResourceKind.INVOKE;
                    hasReadinessResource |= kind == ResourceKind.READINESS;
                } else if (member.kind() == SyntaxKind.OBJECT_METHOD_DEFINITION) {
                    FunctionDefinitionNode method = (FunctionDefinitionNode) member;
                    if (hasQualifier(method.qualifierList(), SyntaxKind.REMOTE_KEYWORD)) {
                        report(REMOTE_FUNCTION_NOT_ALLOWED, method.functionName().location(),
                                method.functionName().text().trim());
                    }
                }
            }
            if (!hasInvokeResource) {
                report(MISSING_INVOKE_RESOURCE, serviceLocation);
            }
            if (!hasReadinessResource) {
                report(MISSING_READINESS_RESOURCE, serviceLocation);
            }
        }

        // Validates one resource and returns which of the supported resources it is.
        private ResourceKind validateResource(FunctionDefinitionNode resource) {
            String accessor = resource.functionName().text().trim().toLowerCase(Locale.ROOT);
            List<String> shape = pathShape(resource.relativeResourcePath());
            String label = resourceLabel(resource);
            ResourceKind kind;
            if (POST.equals(accessor) && shape.equals(List.of(INVOCATIONS))) {
                kind = ResourceKind.INVOKE;
            } else if (GET.equals(accessor) && shape.equals(List.of(READINESS))) {
                kind = ResourceKind.READINESS;
            } else if (GET.equals(accessor) && shape.equals(List.of(INVOCATIONS, PATH_PARAM))) {
                kind = ResourceKind.GET;
            } else if (POST.equals(accessor) && shape.equals(List.of(INVOCATIONS, PATH_PARAM, CANCEL))) {
                kind = ResourceKind.CANCEL;
            } else {
                report(UNSUPPORTED_RESOURCE, resourceLocation(resource), label);
                return ResourceKind.UNSUPPORTED;
            }
            Optional<Symbol> symbol = semanticModel.symbol(resource);
            ResourceMethodSymbol resourceSymbol = symbol.isPresent()
                    && symbol.get() instanceof ResourceMethodSymbol method ? method : null;
            if (kind == ResourceKind.READINESS) {
                validateReadinessParameters(resource, label);
            } else {
                validatePathParameters(resource, resourceSymbol, label);
                validateParameters(resource, label, kind != ResourceKind.GET);
            }
            if (resourceSymbol != null) {
                validateReturnType(resource, resourceSymbol, label);
            }
            return kind;
        }

        // The readiness probe carries no payload and no platform headers, so the dispatcher passes the readiness
        // resource no arguments: every parameter is rejected, whatever its kind or annotation.
        private void validateReadinessParameters(FunctionDefinitionNode resource, String label) {
            for (ParameterNode parameter : resource.functionSignature().parameters()) {
                report(READINESS_PARAMETER_NOT_ALLOWED, parameter.location(), label, parameterName(parameter));
            }
        }

        private void validatePathParameters(FunctionDefinitionNode resource, ResourceMethodSymbol resourceSymbol,
                                            String label) {
            List<ResourcePathParameterNode> pathParams = new ArrayList<>();
            for (Node segment : resource.relativeResourcePath()) {
                if (segment.kind() == SyntaxKind.RESOURCE_PATH_SEGMENT_PARAM) {
                    pathParams.add((ResourcePathParameterNode) segment);
                }
            }
            List<PathParameterSymbol> pathParamSymbols = resourceSymbol != null
                    && resourceSymbol.resourcePath() instanceof PathSegmentList segments
                    ? segments.pathParameters() : List.of();
            for (int i = 0; i < pathParams.size(); i++) {
                ResourcePathParameterNode pathParam = pathParams.get(i);
                TypeSymbol type = pathParameterType(pathParam, pathParamSymbols, i);
                if (type == null) {
                    continue;
                }
                // The dispatcher passes the decoded path segment as a string. `string` is required (rather than
                // any type that accepts every string, which the runtime would also call) so the contract stays
                // the one the listener documents.
                if (!(type.subtypeOf(stringType) && stringType.subtypeOf(type))) {
                    String name = pathParam.paramName().map(token -> token.text().trim()).orElse("");
                    report(INVALID_PATH_PARAMETER_TYPE, pathParam.typeDescriptor().location(), label, name,
                            pathParam.typeDescriptor().toSourceCode().trim());
                }
            }
        }

        private TypeSymbol pathParameterType(ResourcePathParameterNode pathParam,
                                             List<PathParameterSymbol> pathParamSymbols, int index) {
            Optional<Symbol> symbol = semanticModel.symbol(pathParam);
            if (symbol.isPresent() && symbol.get() instanceof PathParameterSymbol pathParamSymbol) {
                return pathParamSymbol.typeDescriptor();
            }
            return index < pathParamSymbols.size() ? pathParamSymbols.get(index).typeDescriptor() : null;
        }

        private void validateParameters(FunctionDefinitionNode resource, String label, boolean acceptsPayload) {
            String allowed = acceptsPayload ? PAYLOAD_AND_CONTEXT : CONTEXT_ONLY;
            boolean hasPayload = false;
            boolean hasContext = false;
            for (ParameterNode parameter : resource.functionSignature().parameters()) {
                String name = parameterName(parameter);
                if (parameter.kind() == SyntaxKind.REST_PARAM || parameter.kind() == SyntaxKind.INCLUDED_RECORD_PARAM) {
                    report(UNSUPPORTED_PARAMETER, parameter.location(), label, name, allowed);
                    continue;
                }
                Optional<Symbol> symbol = semanticModel.symbol(parameter);
                if (symbol.isEmpty() || !(symbol.get() instanceof ParameterSymbol parameterSymbol)) {
                    continue;
                }
                TypeSymbol type = parameterSymbol.typeDescriptor();
                if (hasPayloadAnnotation(parameterSymbol)) {
                    if (!acceptsPayload) {
                        report(PAYLOAD_NOT_ALLOWED, parameter.location(), label);
                    } else if (hasPayload) {
                        report(DUPLICATE_PAYLOAD_PARAMETER, parameter.location(), label);
                    } else if (!type.subtypeOf(anydataType)) {
                        Node typeNode = parameterTypeNode(parameter);
                        Location location = typeNode != null ? typeNode.location() : parameter.location();
                        String typeText = typeNode != null ? typeNode.toSourceCode().trim() : type.signature();
                        report(INVALID_PAYLOAD_TYPE, location, label, name, typeText);
                    }
                    hasPayload = true;
                } else if (isFoundryContext(type)) {
                    if (hasContext) {
                        report(DUPLICATE_CONTEXT_PARAMETER, parameter.location(), label);
                    }
                    hasContext = true;
                } else {
                    report(UNSUPPORTED_PARAMETER, parameter.location(), label, name, allowed);
                }
            }
        }

        private void validateReturnType(FunctionDefinitionNode resource, ResourceMethodSymbol resourceSymbol,
                                        String label) {
            Optional<ReturnTypeDescriptorNode> returnTypeNode = resource.functionSignature().returnTypeDesc();
            Optional<TypeSymbol> returnType = resourceSymbol.typeDescriptor().returnTypeDescriptor();
            if (returnTypeNode.isEmpty() || returnType.isEmpty()) {
                // No return type is `()`, which is sent as `202 Accepted` (for readiness, as the default
                // `200 {"status":"healthy"}`).
                return;
            }
            List<TypeSymbol> members = new ArrayList<>();
            collectMembers(returnType.get(), members);
            boolean returnsStream = false;
            boolean allMembersSupported = true;
            for (TypeSymbol member : members) {
                if (resolve(member).typeKind() == TypeDescKind.STREAM) {
                    returnsStream = true;
                } else if (!isSupportedReturnMember(member)) {
                    allMembersSupported = false;
                }
            }
            // The whole type is checked first, so a type that isn't a union of supported members but is still a
            // subtype of the supported union (such as `readonly & (json|error)`) is accepted.
            boolean supported = (supportedReturnType.isPresent() && returnType.get().subtypeOf(
                    supportedReturnType.get())) || allMembersSupported;
            Node typeNode = returnTypeNode.get().type();
            Location location = typeNode.location();
            // The type as the author wrote it, which is clearer than the resolved signature for a named type.
            String signature = typeNode.toSourceCode().trim();
            if (returnsStream) {
                report(STREAM_RETURN_TYPE, location, label, signature);
            } else if (!supported) {
                report(INVALID_RETURN_TYPE, location, label, signature);
            }
        }

        private boolean isSupportedReturnMember(TypeSymbol member) {
            if (member.subtypeOf(anydataType) || member.subtypeOf(errorType)) {
                return true;
            }
            if (httpResponseType.isPresent() && member.subtypeOf(httpResponseType.get())) {
                return true;
            }
            return statusCodeResponseType.isPresent() && member.subtypeOf(statusCodeResponseType.get());
        }

        private void report(FoundryDiagnostic diagnostic, Location location, Object... args) {
            context.reportDiagnostic(FoundryDiagnostic.createDiagnostic(diagnostic, location, args));
        }
    }

    // The path shape as the runtime reports it: literal segments by name, `^` for a path parameter and `^^` for a
    // rest path parameter. The root path `.` has no segments.
    private static List<String> pathShape(NodeList<Node> relativePath) {
        List<String> shape = new ArrayList<>();
        for (Node segment : relativePath) {
            switch (segment.kind()) {
                case IDENTIFIER_TOKEN -> shape.add(unescapeIdentifier(((Token) segment).text().trim()));
                case RESOURCE_PATH_SEGMENT_PARAM -> shape.add(PATH_PARAM);
                case RESOURCE_PATH_REST_PARAM -> shape.add(PATH_PARAM + PATH_PARAM);
                default -> {
                }
            }
        }
        return shape;
    }

    private static String unescapeIdentifier(String identifier) {
        String value = identifier.startsWith("'") ? identifier.substring(1) : identifier;
        if (value.indexOf('\\') < 0) {
            return value;
        }
        StringBuilder unescaped = new StringBuilder(value.length());
        int i = 0;
        while (i < value.length()) {
            char c = value.charAt(i);
            if (c == '\\' && i + 1 < value.length()) {
                c = value.charAt(i + 1);
                i++;
            }
            unescaped.append(c);
            i++;
        }
        return unescaped.toString();
    }

    // The value of the body of a Ballerina string literal: backslash followed by `\`, `"`, `n`, `t` or `r`, and the
    // numeric escape (backslash, `u`, a hex code point in braces). Any other sequence is kept as written (the
    // compiler has already rejected an invalid escape).
    private static String unescapeStringLiteral(String body) {
        if (body.indexOf('\\') < 0) {
            return body;
        }
        StringBuilder value = new StringBuilder(body.length());
        int i = 0;
        while (i < body.length()) {
            char c = body.charAt(i);
            if (c != '\\' || i + 1 >= body.length()) {
                value.append(c);
                i++;
                continue;
            }
            char next = body.charAt(i + 1);
            switch (next) {
                case '\\', '"' -> value.append(next);
                case 'n' -> value.append('\n');
                case 't' -> value.append('\t');
                case 'r' -> value.append('\r');
                case 'u' -> {
                    int close = body.indexOf('}', i);
                    if (i + 2 < body.length() && body.charAt(i + 2) == '{' && close > i + 3) {
                        try {
                            value.appendCodePoint(Integer.parseInt(body.substring(i + 3, close), 16));
                            i = close + 1;
                            continue;
                        } catch (IllegalArgumentException e) {
                            // Not a valid code point: keep the sequence as written.
                        }
                    }
                    value.append(c).append(next);
                }
                default -> value.append(c).append(next);
            }
            i += 2;
        }
        return value.toString();
    }

    private static String resourceLabel(FunctionDefinitionNode resource) {
        String path = sourceText(resource.relativeResourcePath());
        return resource.functionName().text().trim() + (path.isEmpty() ? "" : " " + path);
    }

    private static Location resourceLocation(FunctionDefinitionNode resource) {
        NodeList<Node> path = resource.relativeResourcePath();
        return path.isEmpty() ? resource.functionName().location()
                : span(resource.functionName(), path.get(path.size() - 1));
    }

    private static String parameterName(ParameterNode parameter) {
        Optional<Token> name = switch (parameter.kind()) {
            case REQUIRED_PARAM -> ((RequiredParameterNode) parameter).paramName();
            case DEFAULTABLE_PARAM -> ((DefaultableParameterNode) parameter).paramName();
            case REST_PARAM -> ((RestParameterNode) parameter).paramName();
            case INCLUDED_RECORD_PARAM -> ((IncludedRecordParameterNode) parameter).paramName();
            default -> Optional.empty();
        };
        return name.map(token -> token.text().trim()).orElse(parameter.toSourceCode().trim());
    }

    private static Node parameterTypeNode(ParameterNode parameter) {
        return switch (parameter.kind()) {
            case REQUIRED_PARAM -> ((RequiredParameterNode) parameter).typeName();
            case DEFAULTABLE_PARAM -> ((DefaultableParameterNode) parameter).typeName();
            default -> null;
        };
    }

    private static boolean hasPayloadAnnotation(ParameterSymbol parameter) {
        for (AnnotationSymbol annotation : parameter.annotations()) {
            Optional<ModuleSymbol> module = annotation.getModule();
            if (module.isPresent() && BALLERINA_ORG.equals(module.get().id().orgName())
                    && HTTP_MODULE.equals(module.get().id().moduleName())
                    && annotation.getName().map(PAYLOAD_ANNOTATION::equals).orElse(false)) {
                return true;
            }
        }
        return false;
    }

    // Whether the type is `azure:FoundryContext`, directly or through a type alias. The runtime matches the record
    // type by name and module, so a structurally equal record of another module doesn't qualify, nor does a union
    // such as `azure:FoundryContext?`.
    private static boolean isFoundryContext(TypeSymbol type) {
        TypeSymbol current = type;
        while (current instanceof TypeReferenceTypeSymbol reference) {
            Optional<ModuleSymbol> module = reference.getModule();
            if (module.isPresent() && BALLERINAX_ORG.equals(module.get().id().orgName())
                    && AI_AZURE_MODULE.equals(module.get().id().moduleName())
                    && FOUNDRY_CONTEXT_TYPE.equals(reference.definition().getName().orElse(null))) {
                return true;
            }
            current = reference.typeDescriptor();
        }
        return false;
    }

    private static TypeSymbol resolve(TypeSymbol type) {
        TypeSymbol current = type;
        while (current instanceof TypeReferenceTypeSymbol reference) {
            current = reference.typeDescriptor();
        }
        return current;
    }

    // Flattens unions (including named ones, such as `http:StatusCodeResponse` or a user's alias) into their members.
    private static void collectMembers(TypeSymbol type, List<TypeSymbol> members) {
        if (resolve(type) instanceof UnionTypeSymbol union) {
            for (TypeSymbol member : union.memberTypeDescriptors()) {
                collectMembers(member, members);
            }
            return;
        }
        members.add(type);
    }

    private static boolean hasQualifier(NodeList<Token> qualifiers, SyntaxKind kind) {
        for (Token qualifier : qualifiers) {
            if (qualifier.kind() == kind) {
                return true;
            }
        }
        return false;
    }

    // Checked only once a node is known to be a Foundry service, so the other services and classes of a package that
    // imports `ai.azure` don't pay for collecting the module's diagnostics. With compilation errors, the types the
    // rules depend on may not be resolvable, and the compiler already reports the errors.
    private static boolean hasCompilationErrors(SemanticModel semanticModel) {
        return semanticModel.diagnostics().stream()
                .anyMatch(diagnostic -> diagnostic.diagnosticInfo().severity() == DiagnosticSeverity.ERROR);
    }

    private static Optional<TypeSymbol> resolveType(SemanticModel semanticModel, String org, String module,
                                                    String name) {
        Optional<Symbol> symbol = semanticModel.types().getTypeByName(org, module, EMPTY_VERSION, name);
        if (symbol.isEmpty()) {
            return Optional.empty();
        }
        // A `type X ...` definition resolves to a TypeDefinitionSymbol; a class, such as `http:Response`, resolves
        // to a ClassSymbol, which is itself a TypeSymbol.
        if (symbol.get() instanceof TypeDefinitionSymbol typeDefinition) {
            return Optional.of(typeDefinition.typeDescriptor());
        }
        if (symbol.get() instanceof TypeSymbol typeSymbol) {
            return Optional.of(typeSymbol);
        }
        return Optional.empty();
    }

    private static String sourceText(NodeList<Node> nodes) {
        StringBuilder text = new StringBuilder();
        for (Node node : nodes) {
            text.append(node.toSourceCode());
        }
        return text.toString().trim();
    }

    // A location from the start of one node to the end of another, without their leading and trailing minutiae.
    private static Location span(Node first, Node last) {
        LineRange firstRange = first.location().lineRange();
        LineRange lastRange = last.location().lineRange();
        int start = first.textRange().startOffset();
        int end = last.textRange().endOffset();
        return new SpanLocation(LineRange.from(firstRange.fileName(), firstRange.startLine(), lastRange.endLine()),
                TextRange.from(start, end - start));
    }

    /**
     * The resources the dispatcher serves, and {@code UNSUPPORTED} for any other resource.
     */
    private enum ResourceKind {
        INVOKE,
        READINESS,
        GET,
        CANCEL,
        UNSUPPORTED
    }

    /**
     * A location that covers several nodes.
     *
     * @param lineRange the line range
     * @param textRange the text range
     */
    private record SpanLocation(LineRange lineRange, TextRange textRange) implements Location {
    }
}
