// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/log;
import ballerina/uuid;
import ballerinax/azure.ai.search as search;
import ballerinax/azure.ai.search.index;

const CONTENT_FIELD_NAME = "content";
const KEY_FIELD_NAME = "id";
const API_VERSION = "2025-09-01";
const API_KEY_HEADER_NAME = "api-key";

# Information about the analyzed index schema
type IndexSchemaInfo record {
    # Name of the key field in the index
    string keyFieldName;
    # Names of vector fields that need embeddings
    string[] vectorFieldNames;
    # Names of content fields that are searchable
    string[] contentFieldNames;
    # Map of all fields in the index
    map<search:SearchField> allFields;
};

# Configuration for the Azure AI Service Clients
public type ClientConfiguration record {|
    # Connection configuration for the Azure AI search client that use for create search index
    # This configuration is only required when the `index` parameter
    # is provided as an `search:SearchIndex` (i.e., when the system will create the index).
    search:ConnectionConfig searchClientConnectionConfig = {};
    # Connection configuration for the Azure AI index client that use for index operations
    index:ConnectionConfig indexClientConnectionConfig = {};
|};

# Represents the Azure Search Knowledge Base implementation.
# User should create the required `indexer`, `data source` and `index` beforehand using 
# the util functions provided in this module. 
# Currently search fields only supported with `id`, `content` and `type` field names.
public distinct isolated class AzureAiSearchKnowledgeBase {
    *ai:KnowledgeBase;
    
    private final search:SearchIndex index;
    private final search:Client serviceClient;
    private final index:Client indexClient;
    private final string apiVersion;
    private final string apiKey;
    private final boolean verbose;
    private final ai:Chunker|ai:AUTO|ai:DISABLE chunker;
    private final ai:EmbeddingProvider embeddingModel;
    private final string contentFieldName;
    private final string keyFieldName;
    private final string[] vectorFieldNames;
    private final map<search:SearchField> allFields;

    # Initializes a new `AzureAiSearchKnowledgeBase` instance.
    # 
    # + serviceUrl - The service URL of the Azure AI Search instance
    # + apiKey - The API key for authenticating with the Azure AI Search service
    # + index - The name of an existing search index or a `search:SearchIndex` definition to create
    # + embeddingModel - The embedding model to use for generating embeddings
    # + chunker - The chunker to use for chunking documents before ingestion. Defaults to `ai:AUTO`.
    # + verbose - Whether to enable verbose logging. Defaults to `false`.
    # + apiVersion - The API version to use for requests.
    # + clientConfigurations - Additional client configurations for Azure AI Search clients
    # + contentFieldName - The name of the field in the index that contains the main content. Defaults to "content".
    # + return - An instance of `AzureAiSearchKnowledgeBase` or an `ai:Error` if initialization fails
    public isolated function init(string serviceUrl, string apiKey, string|search:SearchIndex index, ai:EmbeddingProvider embeddingModel, 
            ai:Chunker|ai:AUTO|ai:DISABLE chunker = ai:AUTO, boolean verbose = false, 
            string apiVersion = API_VERSION, string contentFieldName = CONTENT_FIELD_NAME, 
            *ClientConfiguration clientConfigurations) returns ai:Error? {
        self.chunker = chunker;
        self.embeddingModel = embeddingModel;
        self.verbose = verbose;
        self.contentFieldName = contentFieldName;
        
        // Initialize service client for management operations
        search:ConnectionConfig searchClientConfig = clientConfigurations.searchClientConnectionConfig;
        self.apiKey = apiKey;
        self.apiVersion = apiVersion;

        search:Client|error serviceClient = new search:Client(serviceUrl, searchClientConfig);
        if serviceClient is error {
            return error ai:Error("Failed to initialize Azure AI Service Client", serviceClient);
        }

        self.serviceClient = serviceClient;

        string indexName = index is string ? index : index.name;
        if index is string {
            // Verify that the index exists
            search:SearchIndex|error searchIndex = self.serviceClient->indexesGet(indexName, {
                [API_KEY_HEADER_NAME]: self.apiKey}, {api\-version: self.apiVersion});
            if searchIndex is error {
                logIfVerboseEnable(self.verbose, string `Search index ${indexName} does not exist: ${searchIndex.message()}`);
                return error ai:Error("Failed to verify existence of index", searchIndex);
            }

            self.index = searchIndex.cloneReadOnly();
            logIfVerboseEnable(self.verbose, string `Search index ${indexName} exists. Details: ${searchIndex.toJsonString()}`);
        } else {
            logIfVerboseEnable(self.verbose, string `Attempting to create search index ${indexName}...`);
            search:SearchIndex|error createdIndex = self.serviceClient->indexesCreateOrUpdate(indexName, {
                [API_KEY_HEADER_NAME]: self.apiKey, Prefer: "return=representation"}, index, {api\-version: self.apiVersion});
            if createdIndex is error {
                logIfVerboseEnable(self.verbose, string `Failed to create search index ${indexName}: ${createdIndex.message()}`);
                return error ai:Error("Failed to create search index", createdIndex);
            }
            self.index = createdIndex.cloneReadOnly();
            logIfVerboseEnable(self.verbose, string `Search index ${indexName} created successfully.`);
        }

        string indexServiceUrl = string `${serviceUrl}/indexes('${indexName}')`;
        logIfVerboseEnable(self.verbose, string `Initializing Azure Index Client for index URL: ${indexServiceUrl}`);
        index:Client|error indexClient = new (indexServiceUrl, clientConfigurations.indexClientConnectionConfig);
        if indexClient is error {
            logIfVerboseEnable(self.verbose, string `Failed to initialize Azure Index Client: ${indexClient.message()}`);
            return error ai:Error("Failed to initialize Azure Index Client", indexClient);
        }
        self.indexClient = indexClient;

        lock {
            IndexSchemaInfo schemaInfo = check analyzeIndexSchema(self.verbose, self.index, self.contentFieldName);

            self.keyFieldName = schemaInfo.keyFieldName;
            self.vectorFieldNames = schemaInfo.vectorFieldNames.cloneReadOnly();
            self.allFields = schemaInfo.allFields.cloneReadOnly();
        }
    }

    # Ingests documents into the Azure search knowledge base.
    # + documents - The documents or chunks to ingest (single document, array of documents, or array of chunks)
    # + return - An `ai:Error` if ingestion fails, otherwise `nil`
    public isolated function ingest(ai:Chunk[]|ai:Document[]|ai:Document documents) returns ai:Error? {
        lock {
            ai:Chunk[]|ai:Error chunks = self.chunk(documents.clone());
            if chunks is ai:Error {
                logIfVerboseEnable(self.verbose, string `Failed to chunk documents: ${chunks.message()}}`, chunks);
                return error ai:Error("Failed to chunk documents before ingestion", chunks);
            }

            ai:Embedding[]|error embeddings = self.embeddingModel->batchEmbed(chunks);
            if embeddings is error {
                logIfVerboseEnable(self.verbose, string `Failed to generate embeddings for documents: ${embeddings.message()}}`, embeddings);
                return error ai:Error("Failed to generate embeddings for documents", embeddings);
            }
            logIfVerboseEnable(self.verbose, string `Generated embeddings for ${embeddings.length().toString()} chunks.`);

            index:IndexDocumentsResult|error uploadResult = self.uploadDocuments(self.indexClient, chunks, self.index, 
                    embeddings, {[API_KEY_HEADER_NAME]: self.apiKey}, {api\-version: self.apiVersion});
            if uploadResult is error {
                logIfVerboseEnable(self.verbose, string `Failed to upload documents to search index: ${uploadResult.message()}}`, uploadResult);
                return error ai:Error("Failed to upload documents to search index", uploadResult);
            }
            
            // Validate that all documents were successfully indexed
            foreach index:IndexingResult result in uploadResult.value {
                if !result.status {
                    return error ai:Error(string `Failed to index document with key ${result.'key}: ${result.errorMessage ?: "Unknown error"}`);
                }
            }
            
            return;
        }
    }

    # Retrieves relevant chunks for the given query using vector search.
    #
    # + query - The text query to search for
    # + maxLimit - The maximum number of items to return
    # + filters - Optional metadata filters to apply during retrieval
    # + return - An array of matching chunks with similarity scores, or an `ai:Error` if retrieval fails
    public isolated function retrieve(string query, int maxLimit = 10, ai:MetadataFilters? filters = ()) returns ai:QueryMatch[]|ai:Error {
        if query is "" {
            return error ai:Error("Query cannot be empty for retrieval");
        }

        if maxLimit != -1 && maxLimit <= 0 {
            return error ai:Error("maxLimit must be a positive integer");
        }

        if maxLimit > int:SIGNED32_MAX_VALUE {
            return error ai:Error(string `maxLimit exceeds maximum allowed value of ${int:SIGNED32_MAX_VALUE}`);
        }

        lock {
            ai:TextChunk queryChunk = {content: query, 'type: "text-chunk"};
            ai:Embedding queryEmbedding = check self.embeddingModel->embed(queryChunk);

            // Create vector search request using Azure AI Search's integrated vectorization
            int vectorFieldLength = self.vectorFieldNames.length();
            index:VectorQuery[]? vectorQuery = ();

            if vectorFieldLength != 0 {
                ai:Vector|ai:Error vectors = self.generateVector(queryEmbedding);
                if vectors is ai:Error {
                    return vectors;
                }

                vectorQuery = [
                    {
                        kind: "vector",
                        k: maxLimit == -1 ? () : <int:Signed32>maxLimit,
                        fields: string:'join(",", ...self.vectorFieldNames),
                        "vector": vectors
                    }
                ];
            }

            index:SearchRequest searchRequest = {
                search: query,
                'select: "*",
                vectorQueries: vectorQuery ?: [],
                top: maxLimit == -1 ? () : <int:Signed32>maxLimit
            };

            // Apply metadata filters if provided
            if filters is ai:MetadataFilters {
                string? filterExpression = self.buildODataFilter(filters.cloneReadOnly());
                if filterExpression is string {
                    searchRequest.filter = filterExpression;
                }
            }

            // Execute search
            index:SearchDocumentsResult|error searchResult = self.indexClient->documentsSearchPost(
                searchRequest,
                {[API_KEY_HEADER_NAME]: self.apiKey},
                api\-version = self.apiVersion
            );

            if searchResult is error {
                logIfVerboseEnable(self.verbose, string `Failed to retrieve documents from Azure AI Search: ${searchResult.message()}}`, searchResult);
                return error ai:Error("Failed to retrieve documents from Azure AI Search", searchResult);
            }

            // Convert search results to QueryMatch array
            ai:QueryMatch[] matches = [];
            foreach index:SearchResult result in searchResult.value {
                ai:Chunk chunk = {
                    'type: "text-chunk",
                    content: self.getFieldValue(result, self.contentFieldName),
                    metadata: self.extractMetadata(result)
                };
                
                ai:QueryMatch queryMatch = {
                    chunk: chunk,
                    similarityScore: <float>result.\@search\.score
                };
                matches.push(queryMatch);
            }

            return matches.cloneReadOnly();
        }
    }

    # Deletes chunks that match the given metadata filters.
    #
    # + filters - The metadata filters used to identify which chunks to delete
    # + return - An `ai:Error` if the deletion fails, otherwise `nil`
    public isolated function deleteByFilter(ai:MetadataFilters filters) returns ai:Error? {
        ai:MetadataFilters filtersCopy = filters.cloneReadOnly();
        // First, search for documents matching the filters
        string? filterExpression = self.buildODataFilter(filtersCopy);

        index:SearchRequest searchRequest = {
            filter: filterExpression,
            'select: self.keyFieldName
            // TODO: Implement batching if large number of documents expected
        };

        index:SearchDocumentsResult|error searchResult = self.indexClient->documentsSearchPost(
            searchRequest,
            {[API_KEY_HEADER_NAME]: self.apiKey},
            api\-version = self.apiVersion
        );

        if searchResult is error {
            logIfVerboseEnable(self.verbose, string `Failed to search for documents to delete: ${searchResult.message()}}`, searchResult);
            return error ai:Error("Failed to search for documents to delete", searchResult);
        }

        // Extract document IDs
        string[] documentIds = [];
        foreach index:SearchResult result in searchResult.value {
            string? documentId = self.getFieldValue(result, self.keyFieldName);
            if documentId is string {
                documentIds.push(documentId);
            }
        }

        if documentIds.length() == 0 {
            return; // No documents found matching the filters
        }

        // Create delete actions
        index:IndexAction[] deleteActions = [];
        foreach string docId in documentIds {
            index:IndexAction deleteAction = {
                \@search\.action: "delete"
            };
            // Set the key field for deletion
            deleteAction[self.keyFieldName] = docId;
            deleteActions.push(deleteAction);
        }

        // Execute batch delete
        index:IndexBatch deleteBatch = {
            value: deleteActions
        };

        index:IndexDocumentsResult|error deleteResult = self.indexClient->documentsIndex(
            deleteBatch,
            {[API_KEY_HEADER_NAME]: self.apiKey},
            api\-version = self.apiVersion
        );

        if deleteResult is error {
            return error ai:Error("Failed to delete documents from Azure AI Search", deleteResult);
        }

        // Check for any failures in the delete operation
        foreach index:IndexingResult result in deleteResult.value {
            if !result.status {
                return error ai:Error(string `Failed to delete document with key ${result.'key}: ${result.errorMessage ?: "Unknown error"}`);
            }
        }

        return;
    }
    
    private isolated function buildODataFilter(ai:MetadataFilters filters) returns string? {
        return self.convertFiltersToOData(filters);
    }
    
    private isolated function convertFiltersToOData(ai:MetadataFilters|ai:MetadataFilter node) returns string? {
        if node is ai:MetadataFilter {
            return self.convertSingleFilterToOData(node);
        }
        
        // Handle MetadataFilters with multiple filters
        string[] filterExpressions = [];
        foreach ai:MetadataFilters|ai:MetadataFilter child in node.filters {
            string? childExpression = self.convertFiltersToOData(child);
            if childExpression is string {
                filterExpressions.push(childExpression);
            }
        }
        
        if filterExpressions.length() == 0 {
            return ();
        }
        
        if filterExpressions.length() == 1 {
            return filterExpressions[0];
        }
        
        // Combine filters with the appropriate logical operator
        string logicalOperator = node.condition == ai:AND ? " and " : " or ";
        return string `(${string:'join(logicalOperator, ...filterExpressions)})`;
    }
    
    private isolated function convertSingleFilterToOData(ai:MetadataFilter filter) returns string? {
        string fieldName = filter.key;
        json value = filter.value;
        ai:MetadataFilterOperator operator = filter.operator;
        
        match operator {
            ai:EQUAL => {
                return self.buildEqualityFilter(fieldName, value);
            }
            ai:NOT_EQUAL => {
                return self.buildInequalityFilter(fieldName, value);
            }
            ai:IN => {
                return self.buildInFilter(fieldName, value);
            }
            ai:NOT_IN => {
                return self.buildNotInFilter(fieldName, value);
            }
            ai:GREATER_THAN => {
                return self.buildComparisonFilter(fieldName, value, "gt");
            }
            ai:LESS_THAN => {
                return self.buildComparisonFilter(fieldName, value, "lt");
            }
            ai:GREATER_THAN_OR_EQUAL => {
                return self.buildComparisonFilter(fieldName, value, "ge");
            }
            ai:LESS_THAN_OR_EQUAL => {
                return self.buildComparisonFilter(fieldName, value, "le");
            }
            _ => {
                return (); // Unsupported operator
            }
        }
    }
    
    private isolated function buildEqualityFilter(string fieldName, json value) returns string? {
        string? formattedValue = self.formatValueForOData(value);
        if formattedValue is string {
            return string `${fieldName} eq ${formattedValue}`;
        }
        return ();
    }
    
    private isolated function buildInequalityFilter(string fieldName, json value) returns string? {
        string? formattedValue = self.formatValueForOData(value);
        if formattedValue is string {
            return string `${fieldName} ne ${formattedValue}`;
        }
        return ();
    }

    private isolated function buildInFilter(string fieldName, json value) returns string? {
        if value is json[] && value.length() > 0 {
            string[] conditions = [];
            foreach json item in value {
                string? formattedValue = self.formatValueForOData(item);
                if formattedValue is string {
                    conditions.push(string `${fieldName} eq ${formattedValue}`);
                }
            }
            if conditions.length() > 0 {
                return "(" + string:'join(" or ", ...conditions) + ")";
            }
        }
        return ();
    }

    private isolated function buildNotInFilter(string fieldName, json value) returns string? {
        if value is json[] && value.length() > 0 {
            string[] conditions = [];
            foreach json item in value {
                string? formattedValue = self.formatValueForOData(item);
                if formattedValue is string {
                    conditions.push(string `${fieldName} ne ${formattedValue}`);
                }
            }
            if conditions.length() > 0 {
                return "(" + string:'join(" and ", ...conditions) + ")";
            }
        }
        return ();
    }
    
    private isolated function buildComparisonFilter(string fieldName, json value, string odataOperator) returns string? {
        string? formattedValue = self.formatValueForOData(value);
        if formattedValue is string {
            return string `${fieldName} ${odataOperator} ${formattedValue}`;
        }
        return ();
    }
    
    private isolated function formatValueForOData(json value) returns string? {
        if value is string {
            // Escape single quotes in strings and wrap in single quotes
            string escapedValue = re `'`.replaceAll(value, "''");
            return string `'${escapedValue}'`;
        } else if value is int|decimal {
            return value.toString();
        } else if value is boolean {
            return value.toString();
        }
        // For other types (like null), return null to indicate unsupported
        return ();
    }
    
    private isolated function getFieldValue(index:SearchResult result, string fieldName) returns string {
        anydata fieldValue = result[fieldName];
        if fieldValue is string {
            return fieldValue;
        }
        if fieldValue is () {
            logIfVerboseEnable(self.verbose, string `Field ${fieldName} is null in search result.`);
            return "";
        }
        // Handle other types if they are possible content
        return fieldValue.toString();
    }

    private isolated function extractMetadata(index:SearchResult result) returns ai:Metadata {
        lock {
            ai:Metadata metadata = {};

            // Extract all fields except the core content/title fields as metadata
            map<anydata> clonedResult = result.cloneReadOnly();
            foreach string k in clonedResult.keys() {
                anydata value = clonedResult[k];
                if k != self.contentFieldName && k != self.keyFieldName && self.vectorFieldNames.indexOf(k) == () &&
                k != "@search.score" && k != "@search.highlights" {
                    if value is json {
                        metadata[k] = value;
                    }
                }
            }
            
            return metadata.cloneReadOnly();
        }
    }

    private isolated function chunk(ai:Document|ai:Document[]|ai:Chunk[] input) returns ai:Chunk[]|ai:Error {
        (ai:Document|ai:Chunk)[] inputs = input is ai:Document[]|ai:Chunk[] ? input : [input];
        ai:Chunker|ai:AUTO|ai:DISABLE chunker = self.chunker;
        if chunker is ai:DISABLE {
            return inputs;
        }
        ai:Chunk[] chunks = [];
        foreach ai:Document|ai:Chunk item in inputs {
            ai:Chunker chunkerToUse = chunker is ai:Chunker ? chunker : guessChunker(item);
            chunks.push(...check chunkerToUse.chunk(item));
        }
        return chunks;
    }

    private isolated function uploadDocuments(
        index:Client 'client,
        (ai:Document|ai:Chunk)[] documents,
        search:SearchIndex index,
        ai:Embedding[]? embeddings = (),
        index:DocumentsIndexHeaders headers = {},
        index:DocumentsIndexQueries queries = {api\-version: API_VERSION}
    ) returns index:IndexDocumentsResult|error {
        if embeddings is ai:Embedding[] && embeddings.length() != documents.length() {
            return error ai:Error("Embeddings count does not match documents count, Embeddings length: " +
                string `${embeddings.length()}, Documents length: ${documents.length()}`);
        }

        lock {
            index:IndexAction[] indexActions = [];
            (ai:Document|ai:Chunk)[] & readonly docs = documents.cloneReadOnly();
            ai:Embedding[]? embeddingValues = embeddings.cloneReadOnly();
            foreach int i in 0..<docs.length() {
                (ai:Document|ai:Chunk) doc = docs[i];
                
                // Start with the basic action structure
                index:IndexAction indexAction = {
                    \@search\.action: "mergeOrUpload"
                };

                // Set the key field with a UUID
                // TODO: handle non-string key fields
                ai:Metadata? metadata = doc.metadata;
                string keyValue = metadata !is () && metadata.hasKey(self.keyFieldName)
                    ? doc.metadata[self.keyFieldName].toString() + i.toString()
                    : uuid:createType1AsString();
                    
                indexAction[self.keyFieldName] = keyValue;
                logIfVerboseEnable(
                    self.verbose, string `Set key field ${self.keyFieldName} to value ${keyValue} for document index ${i}.`);

                // Add embeddings to vector fields if available
                if embeddingValues is ai:Embedding[] {
                    ai:Embedding embedding = embeddingValues[i];
                    foreach string vectorFieldName in self.vectorFieldNames {
                        ai:Vector|ai:Error vectors = self.generateVector(embedding);
                        if vectors is ai:Error {
                            logIfVerboseEnable(
                                self.verbose, string `Failed to generate vector for document index ${i} and field ${vectorFieldName}: ${vectors.message()}`);
                            return vectors;
                        }

                        indexAction[vectorFieldName] = vectors;
                        logIfVerboseEnable(
                            self.verbose, string `Added vector for document index ${i} to field ${vectorFieldName}.`);
                    }
                }
                
                indexAction[self.contentFieldName] = doc.content;
                logIfVerboseEnable(
                    self.verbose, string `Added content for document index ${i} to field ${self.contentFieldName}.`);

                // Add document type if there's a field for it (check if "type" field exists)
                if self.allFields.hasKey("type") {
                    indexAction["type"] = doc.'type;
                }

                // Add metadata fields
                if metadata is ai:Metadata {
                    foreach [string, json] [key, value] in metadata.entries() {
                        boolean isPossibleMetadata = key != self.keyFieldName && key != self.contentFieldName 
                                && self.vectorFieldNames.indexOf(key) == ();
                        // Only add metadata if the field exists in the index schema
                        if self.allFields.hasKey(key) && isPossibleMetadata {
                            indexAction[key] = value;
                        } else {
                            if isPossibleMetadata {
                                logIfVerboseEnable(
                                    self.verbose, string `Skipping field ${key} as it does not exist in index schema.`);
                            }
                        }
                    }
                }

                indexActions.push(indexAction);
            }

            index:IndexBatch batch = {
                value: indexActions
            };

            logIfVerboseEnable(self.verbose, string `Uploading ${indexActions.length().toString()} documents to Azure AI Search index ${index.name}.`);
            return 'client->documentsIndex(batch.cloneReadOnly(), headers.cloneReadOnly(), queries.cloneReadOnly());
        }
    }

    private isolated function generateVector(ai:Embedding embedding) returns ai:Vector|ai:Error {
        if embedding is ai:Vector {
            return embedding;
        } else if embedding is ai:HybridVector {
            // Return the dense part, discard sparse
            return embedding.dense;
        } else {
            // Explicitly fail for sparse-only embeddings
            return error ai:Error("AzureAiSearchKnowledgeBase only supports dense or hybrid embeddings, but received a SparseVector.");
        }
    }
}

isolated function logIfVerboseEnable(boolean verbose, string value, 'error? err = ()) {
    if verbose {
        log:printInfo(string `[AzureAiSearchKnowledgeBase] ${value}`);
        if err is error {
            log:printError(string `[AzureAiSearchKnowledgeBase] Error Details: ${err.message()}`, err);
        }
    }
}

isolated function guessChunker(ai:Document|ai:Chunk doc) returns ai:Chunker {
    // Guess the chunker based on the document type or mimeType in metadata
    string? mimeType = doc.metadata?.mimeType;
    if mimeType == "text/markdown" {
        return new ai:MarkdownChunker();
    }
    if mimeType == "text/html" {
        return new ai:HtmlChunker();
    }
    // Fallback to file name
    string? fileName = doc.metadata?.fileName;
    if fileName is string {
        if fileName.endsWith(".md") {
            return new ai:MarkdownChunker();
        }
        if fileName.endsWith(".html") {
            return new ai:HtmlChunker();
        }
    }
    return new ai:GenericRecursiveChunker();
}

isolated function analyzeIndexSchema(boolean verbose, search:SearchIndex index, string contentFieldName) returns IndexSchemaInfo|ai:Error {
    string? keyFieldName = ();
    string[] vectorFieldNames = [];
    string[] contentFieldNames = [];
    map<search:SearchField> allFields = {};
    
    foreach search:SearchField indexField in index.fields {
        allFields[indexField.name] = indexField;
        
        // Identify key field
        if indexField.'key == true {
            keyFieldName = indexField.name;
        }
        
        // Identify vector fields (fields with dimensions and vector search profile)
        if indexField?.dimensions is int && indexField?.vectorSearchProfile is string {
            vectorFieldNames.push(indexField.name);
        }
        
        // Identify potential content fields (searchable string fields)
        if indexField.name == contentFieldName {
            contentFieldNames.push(indexField.name);
        }
    }

    if vectorFieldNames.length() == 0 {
        logIfVerboseEnable(verbose, "No vector fields found in index schema.");
    }

    if contentFieldNames.length() == 0 {
        return error(string `Index schema must contains a field named '${contentFieldName}'.`);
    }

    if keyFieldName is () {
        logIfVerboseEnable(verbose, string `No key field defined in index schema. Using default key field name as '${KEY_FIELD_NAME}'.`);
    }

    if vectorFieldNames.length() > 1 {
        logIfVerboseEnable(verbose, string `Multiple vector fields found in index schema: ${string:'join(", ", ...vectorFieldNames)}. Currently one vecotr field is prefered. So for now, there is more than one, all the vector fileds will share the same vectors.`);
    }
    
    return {
        keyFieldName: keyFieldName ?: KEY_FIELD_NAME,
        vectorFieldNames: vectorFieldNames,
        contentFieldNames: contentFieldNames,
        allFields: allFields
    };
}
