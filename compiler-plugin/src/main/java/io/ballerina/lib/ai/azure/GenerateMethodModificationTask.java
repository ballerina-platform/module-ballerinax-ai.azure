/*
 * Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
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

import io.ballerina.compiler.api.ModuleID;
import io.ballerina.compiler.api.SemanticModel;
import io.ballerina.compiler.api.symbols.ClassSymbol;
import io.ballerina.compiler.api.symbols.ErrorTypeSymbol;
import io.ballerina.compiler.api.symbols.ModuleSymbol;
import io.ballerina.compiler.api.symbols.Symbol;
import io.ballerina.compiler.api.symbols.TypeReferenceTypeSymbol;
import io.ballerina.compiler.api.symbols.TypeSymbol;
import io.ballerina.compiler.api.symbols.UnionTypeSymbol;
import io.ballerina.compiler.syntax.tree.AnnotationNode;
import io.ballerina.compiler.syntax.tree.ExpressionNode;
import io.ballerina.compiler.syntax.tree.IdentifierToken;
import io.ballerina.compiler.syntax.tree.ImportDeclarationNode;
import io.ballerina.compiler.syntax.tree.ImportOrgNameNode;
import io.ballerina.compiler.syntax.tree.ImportPrefixNode;
import io.ballerina.compiler.syntax.tree.MappingConstructorExpressionNode;
import io.ballerina.compiler.syntax.tree.MetadataNode;
import io.ballerina.compiler.syntax.tree.ModulePartNode;
import io.ballerina.compiler.syntax.tree.Node;
import io.ballerina.compiler.syntax.tree.NodeFactory;
import io.ballerina.compiler.syntax.tree.NodeList;
import io.ballerina.compiler.syntax.tree.NodeParser;
import io.ballerina.compiler.syntax.tree.NodeVisitor;
import io.ballerina.compiler.syntax.tree.QualifiedNameReferenceNode;
import io.ballerina.compiler.syntax.tree.RemoteMethodCallActionNode;
import io.ballerina.compiler.syntax.tree.SimpleNameReferenceNode;
import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.compiler.syntax.tree.TreeModifier;
import io.ballerina.compiler.syntax.tree.TypeDefinitionNode;
import io.ballerina.openapi.service.mapper.type.TypeMapper;
import io.ballerina.projects.Document;
import io.ballerina.projects.DocumentId;
import io.ballerina.projects.Module;
import io.ballerina.projects.ModuleId;
import io.ballerina.projects.Package;
import io.ballerina.projects.PackageCompilation;
import io.ballerina.projects.plugins.ModifierTask;
import io.ballerina.projects.plugins.SourceModifierContext;
import io.ballerina.tools.text.TextDocument;
import io.swagger.v3.core.util.Json;
import io.swagger.v3.core.util.OpenAPISchema2JsonSchema;
import io.swagger.v3.oas.models.media.Schema;

import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static io.ballerina.projects.util.ProjectConstants.EMPTY_STRING;

/**
 * Modifier to add JSON schema annotations
 * for types used in Azure OpenAI provider's `generate` method calls.
 * 
 * @since 1.0.0
 */
class GenerateMethodModificationTask implements ModifierTask<SourceModifierContext> {
    private static final String AI_MODULE_NAME = "ai";
    private static final String BALLERINA_ORG_NAME = "ballerina";
    private final AiAzureCodeModifier.AnalysisData analysisData;
    private final ModifierData modifierData;

    public GenerateMethodModificationTask(AiAzureCodeModifier.AnalysisData analysisData) {
        this.analysisData = analysisData;
        this.modifierData = new ModifierData();
    }

    @Override
    public void modify(SourceModifierContext modifierContext) {
        Package currentPackage = modifierContext.currentPackage();
        PackageCompilation compilation = modifierContext.compilation();
        if (compilation.diagnosticResult().errorCount() > 0) {
            return;
        }

        for (ModuleId moduleId : currentPackage.moduleIds()) {
            Module module = currentPackage.module(moduleId);
            SemanticModel semanticModel = compilation.getSemanticModel(moduleId);
            Collection<DocumentId> documentIds = module.documentIds();
            Collection<DocumentId> testDocumentIds = module.testDocumentIds();

            for (DocumentId documentId : documentIds) {
                analyzeDocument(module, documentId, semanticModel);
            }

            for (DocumentId documentId : testDocumentIds) {
                analyzeDocument(module, documentId, semanticModel);
            }

            for (DocumentId documentId : documentIds) {
                modifierContext.modifySourceFile(modifyDocument(module.document(documentId),
                        modifierData), documentId);
            }

            for (DocumentId documentId : testDocumentIds) {
                modifierContext.modifyTestSourceFile(modifyDocument(module.document(documentId),
                        modifierData), documentId);
            }
        }
    }

    private void analyzeDocument(Module module, DocumentId documentId, SemanticModel semanticModel) {
        Document document = module.document(documentId);
        Node rootNode = document.syntaxTree().rootNode();
        if (!(rootNode instanceof ModulePartNode modulePartNode)) {
            return;
        }

        analyzeGenerateMethod(document, semanticModel, modulePartNode, this.analysisData);
    }

    private static TextDocument modifyDocument(Document document, ModifierData modifierData) {
        ModulePartNode modulePartNode = document.syntaxTree().rootNode();
        DocumentId documentId = document.documentId();
        String aiImportPrefix = getAiModuleImportPrefix(modulePartNode.imports());
        boolean isAiImportPresent = aiImportPrefix != null;

        TypeDefinitionModifier typeDefinitionModifier =
                new TypeDefinitionModifier(modifierData.typeSchemas, document, modifierData,
                        isAiImportPresent ? aiImportPrefix : AI_MODULE_NAME);

        ModulePartNode finalRoot = (ModulePartNode) modulePartNode.apply(typeDefinitionModifier);
        NodeList<ImportDeclarationNode> imports = finalRoot.imports();
        if (modifierData.aiImportRequiredDocuments.contains(documentId)) {
            if (!isAiImportPresent) {
                imports = imports.add(createImportDeclarationForAIModule());
            }
        }

        finalRoot = finalRoot.modify(imports, finalRoot.members(), finalRoot.eofToken());
        return document.syntaxTree().modifyWith(finalRoot).textDocument();
    }

    private static ImportDeclarationNode createImportDeclarationForAIModule() {
        return NodeParser.parseImportDeclaration(String.format("import %s/%s;", BALLERINA_ORG_NAME, AI_MODULE_NAME));
    }

    private void analyzeGenerateMethod(Document document, SemanticModel semanticModel,
                                        ModulePartNode modulePartNode, AiAzureCodeModifier.AnalysisData analysisData) {
        new GenerateMethodJsonSchemaGenerator(semanticModel, document, analysisData)
                .generate(modulePartNode);
    }

    private static String getAiModuleImportPrefix(NodeList<ImportDeclarationNode> imports) {
        for (ImportDeclarationNode importDeclarationNode : imports) {
            Optional<ImportOrgNameNode> importOrgNameNode = importDeclarationNode.orgName();
            if (importOrgNameNode.isEmpty()) {
                continue;
            }

            String orgName = importOrgNameNode.get().orgName().text();
            if (!BALLERINA_ORG_NAME.equals(orgName)) {
                continue;
            }

            for (IdentifierToken module : importDeclarationNode.moduleName()) {
                if (!AI_MODULE_NAME.equals(module.text())) {
                    continue;
                }

                String importPrefix = AI_MODULE_NAME;
                Optional<ImportPrefixNode> prefix = importDeclarationNode.prefix();
                if (prefix.isPresent()) {
                    String prefixText = prefix.get().prefix().text();
                    if (!prefixText.equals("_")) {
                        importPrefix = prefixText;
                    } else {
                        importPrefix = null;
                    }
                }
                return importPrefix;
            }
        }
        return null;
    }

    private class GenerateMethodJsonSchemaGenerator extends NodeVisitor {
        private static final String GENERATE_METHOD_NAME = "generate";
        private static final String OPEN_AI_PROVIDER_NAME = "OpenAiProvider";
        private static final String AZURE_MODEL_PROVIDER_MODULE_NAME = "ai.model.provider.azure";
        private static final String AZURE_MODEL_PROVIDER_MODULE_VERSION = "1";
        private static final String AZURE_MODEL_PROVIDER_MODULE_ORG = "ballerinax";
        private static final String STRING = "string";
        private static final String BYTE = "byte";
        private static final String NUMBER = "number";
        private final SemanticModel semanticModel;
        private final Document document;
        private final TypeMapper typeMapper;
        private final ClassSymbol azureOpenAIProviderSymbol;

        public GenerateMethodJsonSchemaGenerator(SemanticModel semanticModel, Document document,
                                                 AiAzureCodeModifier.AnalysisData analyserData) {
            this.semanticModel = semanticModel;
            this.document = document;
            this.typeMapper = analyserData.typeMapper;
            Optional<ClassSymbol> openAIProviderSymbol = getOpenAIProviderSymbol(document.syntaxTree().rootNode());
            this.azureOpenAIProviderSymbol = openAIProviderSymbol.orElse(null);
        }

        void generate(ModulePartNode modulePartNode) {
            if (this.azureOpenAIProviderSymbol == null) {
                return;
            }
            visit(modulePartNode);
        }

        public void visit(RemoteMethodCallActionNode remoteMethodCallActionNode) {
            SimpleNameReferenceNode methodName = remoteMethodCallActionNode.methodName();
            if (!methodName.name().text().equals(GENERATE_METHOD_NAME)) {
                this.visitSyntaxNode(remoteMethodCallActionNode);
                return;
            }

            ExpressionNode expression = remoteMethodCallActionNode.expression();
            semanticModel.typeOf(expression).ifPresent(expressionTypeSymbol -> {
                if (expressionTypeSymbol.subtypeOf(this.azureOpenAIProviderSymbol)) {
                    updateTypeSchemaForTypeDef(remoteMethodCallActionNode);
                }
            });
        }

        private void updateTypeSchemaForTypeDef(RemoteMethodCallActionNode remoteMethodCallActionNode) {
            semanticModel.typeOf(remoteMethodCallActionNode).ifPresent(this::updateTypeSchema);
        }

        private void updateTypeSchema(TypeSymbol expTypeSymbol) {
            if (!(expTypeSymbol instanceof UnionTypeSymbol expTypeUnionSymbol)) {
                return;
            }

            TypeSymbol nonErrorTypeSymbol = null;
            TypeSymbol typeRefTypeSymbol = null;
            List<TypeSymbol> memberTypeSymbols = expTypeUnionSymbol.memberTypeDescriptors();
            for (TypeSymbol memberTypeSymbol: memberTypeSymbols) {
                if (memberTypeSymbol instanceof TypeReferenceTypeSymbol typeReferenceTypeSymbol) {
                    typeRefTypeSymbol = typeReferenceTypeSymbol.typeDescriptor();
                }

                if (!(typeRefTypeSymbol instanceof ErrorTypeSymbol)) {
                    nonErrorTypeSymbol = memberTypeSymbol;
                }
            }

            if (!(nonErrorTypeSymbol instanceof TypeReferenceTypeSymbol)) {
                return;
            }
            populateTypeSchema(nonErrorTypeSymbol, typeMapper, modifierData.typeSchemas);
        }

        private static void populateTypeSchema(TypeSymbol memberType, TypeMapper typeMapper,
                                               Map<String, String> typeSchemas) {
            if (memberType instanceof TypeReferenceTypeSymbol typeReference) {
                typeSchemas.put(typeReference.definition().getName().get(),
                        getJsonSchema(typeMapper.getSchema(typeReference)));
            }
        }

        private Optional<ClassSymbol> getOpenAIProviderSymbol(Node node) {
            Optional<ModuleSymbol> azureModuleSymbol = getAzureModuleSymbol(node);
            if (azureModuleSymbol.isEmpty()) {
                return Optional.empty();
            }

            for (ClassSymbol classSymbol: azureModuleSymbol.get().classes()) {
                if (classSymbol.nameEquals(OPEN_AI_PROVIDER_NAME)) {
                    return Optional.of(classSymbol);
                }
            }

            return Optional.empty();
        }

        private Optional<ModuleSymbol> getAzureModuleSymbol(Node node) {
            for (Symbol symbol : semanticModel.visibleSymbols(this.document, node.lineRange().startLine())) {
                if (!(symbol instanceof ModuleSymbol moduleSymbol)) {
                    continue;
                }

                ModuleID id = moduleSymbol.id();
                if (AZURE_MODEL_PROVIDER_MODULE_ORG.equals(id.orgName())
                        && AZURE_MODEL_PROVIDER_MODULE_NAME.equals(id.moduleName())
                        && id.version().startsWith(AZURE_MODEL_PROVIDER_MODULE_VERSION)) {
                    return Optional.of(moduleSymbol);
                }
            }
            return Optional.empty();
        }

        private static String getJsonSchema(Schema schema) {
            modifySchema(schema);
            OpenAPISchema2JsonSchema openAPISchema2JsonSchema = new OpenAPISchema2JsonSchema();
            openAPISchema2JsonSchema.process(schema);
            String newLineRegex = "\\R";
            String jsonCompressionRegex = "\\s*([{}\\[\\]:,])\\s*";
            return Json.pretty(schema.getJsonSchema())
                    .replaceAll(newLineRegex, EMPTY_STRING)
                    .replaceAll(jsonCompressionRegex, "$1");
        }

        private static void modifySchema(Schema schema) {
            if (schema == null) {
                return;
            }
            modifySchema(schema.getItems());
            modifySchema(schema.getNot());

            Map<String, Schema> properties = schema.getProperties();
            if (properties != null) {
                properties.values().forEach(GenerateMethodJsonSchemaGenerator::modifySchema);
            }

            List<Schema> allOf = schema.getAllOf();
            if (allOf != null) {
                schema.setType(null);
                allOf.forEach(GenerateMethodJsonSchemaGenerator::modifySchema);
            }

            List<Schema> anyOf = schema.getAnyOf();
            if (anyOf != null) {
                schema.setType(null);
                anyOf.forEach(GenerateMethodJsonSchemaGenerator::modifySchema);
            }

            List<Schema> oneOf = schema.getOneOf();
            if (oneOf != null) {
                schema.setType(null);
                oneOf.forEach(GenerateMethodJsonSchemaGenerator::modifySchema);
            }

            // Override default ballerina byte to json schema mapping
            if (BYTE.equals(schema.getFormat()) && STRING.equals(schema.getType())) {
                schema.setFormat(null);
                schema.setType(NUMBER);
            }
            removeUnwantedFields(schema);
        }

        private static void removeUnwantedFields(Schema schema) {
            schema.setSpecVersion(null);
            schema.setSpecVersion(null);
            schema.setContains(null);
            schema.set$id(null);
            schema.set$schema(null);
            schema.set$anchor(null);
            schema.setExclusiveMaximumValue(null);
            schema.setExclusiveMinimumValue(null);
            schema.setDiscriminator(null);
            schema.setTitle(null);
            schema.setMaximum(null);
            schema.setExclusiveMaximum(null);
            schema.setMinimum(null);
            schema.setExclusiveMinimum(null);
            schema.setMaxLength(null);
            schema.setMinLength(null);
            schema.setMaxItems(null);
            schema.setMinItems(null);
            schema.setMaxProperties(null);
            schema.setMinProperties(null);
            schema.setAdditionalProperties(null);
            schema.setAdditionalProperties(null);
            schema.set$ref(null);
            schema.set$ref(null);
            schema.setReadOnly(null);
            schema.setWriteOnly(null);
            schema.setExample(null);
            schema.setExample(null);
            schema.setExternalDocs(null);
            schema.setDeprecated(null);
            schema.setPrefixItems(null);
            schema.setContentEncoding(null);
            schema.setContentMediaType(null);
            schema.setContentSchema(null);
            schema.setPropertyNames(null);
            schema.setUnevaluatedProperties(null);
            schema.setMaxContains(null);
            schema.setMinContains(null);
            schema.setAdditionalItems(null);
            schema.setUnevaluatedItems(null);
            schema.setIf(null);
            schema.setElse(null);
            schema.setThen(null);
            schema.setDependentSchemas(null);
            schema.set$comment(null);
            schema.setExamples(null);
            schema.setExtensions(null);
            schema.setConst(null);
        }

        public void visit(Node node) {
            this.visitSyntaxNode(node);
        }
    }

    static final class ModifierData {
        Map<String, String> typeSchemas = new HashMap<>();
        HashSet<DocumentId> aiImportRequiredDocuments = new HashSet<>();
    }

    private static class TypeDefinitionModifier extends TreeModifier {
        private static final String SCHEMA_ANNOTATION_IDENTIFIER = "JsonSchema";
        private static final String COLON = ":";
        private final Map<String, String> typeSchemas;
        private final Document document;
        private final ModifierData modifierData;
        private final String aiPrefix;

        TypeDefinitionModifier(Map<String, String> typeSchemas, Document document,
                               ModifierData modifierData, String aiPrefix) {
            this.typeSchemas = typeSchemas;
            this.document = document;
            this.modifierData = modifierData;
            this.aiPrefix = aiPrefix != null ? aiPrefix : AI_MODULE_NAME;
        }

        @Override
        public TypeDefinitionNode transform(TypeDefinitionNode typeDefinitionNode) {
            String typeName = typeDefinitionNode.typeName().text();

            if (!this.typeSchemas.containsKey(typeName)) {
                return typeDefinitionNode;
            }

            MetadataNode updatedMetadataNode =
                    updateMetadata(typeDefinitionNode, typeSchemas.get(typeName));
            return typeDefinitionNode.modify().withMetadata(updatedMetadataNode).apply();
        }

        private MetadataNode updateMetadata(TypeDefinitionNode typeDefinitionNode, String schema) {
            MetadataNode metadataNode = getMetadataNode(typeDefinitionNode);
            NodeList<AnnotationNode> currentAnnotations = metadataNode.annotations();
            NodeList<AnnotationNode> updatedAnnotations = updateAnnotations(currentAnnotations, schema, this.aiPrefix);
            if (currentAnnotations.size() < updatedAnnotations.size()) {
                modifierData.aiImportRequiredDocuments.add(document.documentId());
            }
            return metadataNode.modify().withAnnotations(updatedAnnotations).apply();
        }

        public static MetadataNode getMetadataNode(TypeDefinitionNode typeDefinitionNode) {
            return typeDefinitionNode.metadata().orElseGet(() -> {
                NodeList<AnnotationNode> annotations = NodeFactory.createNodeList();
                return NodeFactory.createMetadataNode(null, annotations);
            });
        }

        private static NodeList<AnnotationNode> updateAnnotations(NodeList<AnnotationNode> currentAnnotations,
                                                                  String jsonSchema, String aiPrefix) {
            for (AnnotationNode annotationNode : currentAnnotations) {
                if (isJsonSchemaAnnotationAvailable(annotationNode, aiPrefix)) {
                    return currentAnnotations;
                }
            }

            return currentAnnotations.add(getSchemaAnnotation(jsonSchema, aiPrefix));
        }

        public static boolean isJsonSchemaAnnotationAvailable(AnnotationNode annotationNode, String aiPrefix) {
            Node node = annotationNode.annotReference();
            if (!(node instanceof QualifiedNameReferenceNode referenceNode)) {
                return false;
            }

            if (!aiPrefix.equals(referenceNode.modulePrefix().text())) {
                return false;
            }
            return SCHEMA_ANNOTATION_IDENTIFIER.equals(referenceNode.identifier().text());
        }

        public static AnnotationNode getSchemaAnnotation(String jsonSchema, String aiPrefix) {
            String configIdentifierString = aiPrefix + COLON + SCHEMA_ANNOTATION_IDENTIFIER;
            IdentifierToken identifierToken = NodeFactory.createIdentifierToken(configIdentifierString);

            return NodeFactory.createAnnotationNode(
                    NodeFactory.createToken(SyntaxKind.AT_TOKEN),
                    NodeFactory.createSimpleNameReferenceNode(identifierToken),
                    getAnnotationExpression(jsonSchema)
            );
        }

        public static MappingConstructorExpressionNode getAnnotationExpression(String jsonSchema) {
            return (MappingConstructorExpressionNode) NodeParser.parseExpression(jsonSchema);
        }
    }
}
