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
import ballerinax/azure.ai.search;
import ballerinax/azure.ai.search.index;

const CONTENT_FIELD_NAME = "content";
const KEY_FIELD_NAME = "id";
const AI_AZURE_KNOWLEDGE_BASE_API_VERSION = "2025-09-01";
const API_KEY_HEADER_NAME = "api-key";

// Search action constants
const SEARCH_ACTION_MERGE_OR_UPLOAD = "mergeOrUpload";
const SEARCH_ACTION_DELETE = "delete";

// Vector search constants
const VECTOR_QUERY_KIND = "vector";

// Content type constants
const CONTENT_TYPE_TEXT_CHUNK = "text-chunk";
const MIME_TYPE_MARKDOWN = "text/markdown";
const MIME_TYPE_HTML = "text/html";

// File extension constants
const FILE_EXT_MARKDOWN = ".md";
const FILE_EXT_HTML = ".html";

// Search field constants
const SEARCH_SCORE_FIELD = "@search.score";
const SEARCH_HIGHLIGHTS_FIELD = "@search.highlights";
const SEARCH_ACTION_FIELD = "@search.action";

// OData operator constants
const ODATA_OPERATOR_GT = "gt";
const ODATA_OPERATOR_LT = "lt";
const ODATA_OPERATOR_GE = "ge";
const ODATA_OPERATOR_LE = "le";
const ODATA_OPERATOR_EQ = "eq";
const ODATA_OPERATOR_NE = "ne";
const ODATA_OPERATOR_AND = " and ";
const ODATA_OPERATOR_OR = " or ";

// Preference header constants
const PREFER_HEADER_RETURN_REPRESENTATION = "return=representation";

// Default field names
const DEFAULT_TYPE_FIELD_NAME = "type";

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

# Represents the Azure Search Knowledge Base implementation.
public distinct isolated class AiSearchKnowledgeBase {
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

    # Initializes a new `AiSearchKnowledgeBase` instance.
    # 
    # + serviceUrl - The service URL of the Azure AI Search instance
    # + apiKey - The API key for authenticating with the Azure AI Search service
    # + index - The name of an existing search index or a `search:SearchIndex` definition to create,
    #   When creating a new index, ensure that it contains one key field of type string.
    # + embeddingModel - The embedding model to use for generating embeddings
    # + chunker - The chunker to use for chunking documents before ingestion. Defaults to `ai:AUTO`.
    # + verbose - Whether to enable verbose logging. Defaults to `false`.
    # + apiVersion - The API version to use for requests.
    # + clientConfigurations - Additional client configurations for Azure AI Search clients
    # + contentFieldName - The name of the field in the index that contains the main content. Defaults to "content".
    # + searchClientConnectionConfig - Connection configuration for the Azure AI search client.
    #                                  This configuration is only required when the `index` parameter is 
    #                                  provided as an `search:SearchIndex`
    # + indexClientConnectionConfig - Connection configuration for the Azure AI index client.
    # + return - An instance of `AiSearchKnowledgeBase` or an `ai:Error` if initialization fails
    public isolated function init(string serviceUrl, string apiKey, 
            string|search:SearchIndex index, ai:EmbeddingProvider embeddingModel, 
            ai:Chunker|ai:AUTO|ai:DISABLE chunker = ai:AUTO, boolean verbose = false, 
            string apiVersion = AI_AZURE_KNOWLEDGE_BASE_API_VERSION, string contentFieldName = CONTENT_FIELD_NAME, 
            search:ConnectionConfig searchClientConnectionConfig = {},
            index:ConnectionConfig indexClientConnectionConfig = {}) returns ai:Error? {
        self.chunker = chunker;
        self.embeddingModel = embeddingModel;
        self.verbose = verbose;
        self.contentFieldName = contentFieldName;
        
        // Initialize service client for management operations
        self.apiKey = apiKey;
        self.apiVersion = apiVersion;

        search:Client|error serviceClient = new search:Client(serviceUrl, searchClientConnectionConfig);
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
                logIfVerboseEnabled(self.verbose, 
                    string `Search index ${indexName} does not exist: ${searchIndex.message()}`);
                return error ai:Error("Failed to verify existence of index", searchIndex);
            }

            self.index = searchIndex.cloneReadOnly();
            logIfVerboseEnabled(self.verbose, 
                string `Search index ${indexName} exists. Details: ${searchIndex.toJsonString()}`);
        } else {
            logIfVerboseEnabled(self.verbose, string `Attempting to create search index ${indexName}...`);
            search:SearchIndex|error createdIndex = self.serviceClient->indexesCreateOrUpdate(indexName, {
                [API_KEY_HEADER_NAME]: self.apiKey, Prefer: PREFER_HEADER_RETURN_REPRESENTATION}, 
                    index, {api\-version: self.apiVersion});
            if createdIndex is error {
                logIfVerboseEnabled(self.verbose, 
                    string `Failed to create search index ${indexName}: ${createdIndex.message()}`);
                return error ai:Error("Failed to create search index", createdIndex);
            }
            self.index = createdIndex.cloneReadOnly();
            logIfVerboseEnabled(self.verbose, string `Search index ${indexName} created successfully.`);
        }

        string indexServiceUrl = string `${serviceUrl}/indexes('${indexName}')`;
        logIfVerboseEnabled(self.verbose, string `Initializing Azure Index Client for index URL: ${indexServiceUrl}`);
        index:Client|error indexClient = new (indexServiceUrl, indexClientConnectionConfig);
        if indexClient is error {
            logIfVerboseEnabled(self.verbose, 
                string `Failed to initialize Azure Index Client: ${indexClient.message()}`);
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
                logIfVerboseEnabled(self.verbose, 
                    string `Failed to chunk documents: ${chunks.message()}}`, chunks);
                return error ai:Error("Failed to chunk documents before ingestion", chunks);
            }

            ai:Embedding[]|error embeddings = self.embeddingModel->batchEmbed(chunks);
            if embeddings is error {
                logIfVerboseEnabled(self.verbose, 
                    string `Failed to generate embeddings for documents: ${embeddings.message()}}`, embeddings);
                return error ai:Error("Failed to generate embeddings for documents", embeddings);
            }
            logIfVerboseEnabled(self.verbose, 
                string `Generated embeddings for ${embeddings.length().toString()} chunks.`);

            index:IndexDocumentsResult|error uploadResult = self.uploadDocuments(self.indexClient, chunks, self.index, 
                    embeddings, {[API_KEY_HEADER_NAME]: self.apiKey}, {api\-version: self.apiVersion});
            if uploadResult is error {
                logIfVerboseEnabled(self.verbose, 
                    string `Failed to upload documents to search index: ${uploadResult.message()}}`, uploadResult);
                return error ai:Error("Failed to upload documents to search index", uploadResult);
            }
            
            // Validate that all documents were successfully indexed
            foreach index:IndexingResult result in uploadResult.value {
                if !result.status {
                    return error ai:Error(
                        string `Failed to index document with key ${result.'key}: ${result.errorMessage ?: "Unknown error"}`);
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
    public isolated function retrieve(string query, int maxLimit = 10, 
                                ai:MetadataFilters? filters = ()) returns ai:QueryMatch[]|ai:Error {
        if maxLimit != -1 && maxLimit <= 0 {
            return error ai:Error("maxLimit must be a positive integer");
        }

        if maxLimit > int:SIGNED32_MAX_VALUE {
            return error ai:Error(string `maxLimit exceeds maximum allowed value of ${int:SIGNED32_MAX_VALUE}`);
        }

        lock {
            ai:TextChunk queryChunk = {content: query, 'type: CONTENT_TYPE_TEXT_CHUNK};
            ai:Embedding queryEmbedding = check self.embeddingModel->embed(queryChunk);

            // Create vector search request using Azure AI Search's integrated vectorization
            int vectorFieldLength = self.vectorFieldNames.length();
            index:VectorQuery[]? vectorQuery = ();

            if vectorFieldLength != 0 {
                ai:Vector|ai:Error vectors = generateVectorFromEmbedding(queryEmbedding);
                if vectors is ai:Error {
                    return vectors;
                }

                vectorQuery = [
                    {
                        kind: VECTOR_QUERY_KIND,
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
                logIfVerboseEnabled(self.verbose, 
                    string `Failed to retrieve documents from Azure AI Search: ${searchResult.message()}}`, searchResult);
                return error ai:Error("Failed to retrieve documents from Azure AI Search", searchResult);
            }

            // Convert search results to QueryMatch array
            ai:QueryMatch[] matches = [];
            foreach index:SearchResult result in searchResult.value {
                ai:Chunk chunk = {
                    'type: CONTENT_TYPE_TEXT_CHUNK,
                    content: extractFieldValue(result, self.contentFieldName, self.verbose),
                    metadata: extractMetadataFromResult(result, self.contentFieldName, self.keyFieldName, self.vectorFieldNames)
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
            logIfVerboseEnabled(self.verbose, 
                string `Failed to search for documents to delete: ${searchResult.message()}}`, searchResult);
            return error ai:Error("Failed to search for documents to delete", searchResult);
        }

        string[] documentIds = from index:SearchResult result in searchResult.value
            let string? documentId = extractFieldValue(result, self.keyFieldName, self.verbose)
            where documentId is string
            select documentId;

        if documentIds.length() == 0 {
            return; // No documents found matching the filters
        }

        // Create delete actions
        index:IndexAction[] deleteActions = [];
        foreach string docId in documentIds {
            index:IndexAction deleteAction = {
                \@search\.action: SEARCH_ACTION_DELETE
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
                return error ai:Error(string 
                    `Failed to delete document with key ${result.'key}: ${result.errorMessage ?: "Unknown error"}`);
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
        string logicalOperator = node.condition == ai:AND ? ODATA_OPERATOR_AND : ODATA_OPERATOR_OR;
        return string `(${string:'join(logicalOperator, ...filterExpressions)})`;
    }
    
    private isolated function convertSingleFilterToOData(ai:MetadataFilter filter) returns string? {
        string fieldName = filter.key;
        json value = filter.value;
        ai:MetadataFilterOperator operator = filter.operator;
        
        match operator {
            ai:EQUAL => {
                return buildEqualityFilter(fieldName, value);
            }
            ai:NOT_EQUAL => {
                return buildInequalityFilter(fieldName, value);
            }
            ai:IN => {
                return buildInFilter(fieldName, value);
            }
            ai:NOT_IN => {
                return buildNotInFilter(fieldName, value);
            }
            ai:GREATER_THAN => {
                return buildComparisonFilter(fieldName, value, ODATA_OPERATOR_GT);
            }
            ai:LESS_THAN => {
                return buildComparisonFilter(fieldName, value, ODATA_OPERATOR_LT);
            }
            ai:GREATER_THAN_OR_EQUAL => {
                return buildComparisonFilter(fieldName, value, ODATA_OPERATOR_GE);
            }
            ai:LESS_THAN_OR_EQUAL => {
                return buildComparisonFilter(fieldName, value, ODATA_OPERATOR_LE);
            }
            _ => {
                return (); // Unsupported operator
            }
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
        index:DocumentsIndexQueries queries = {api\-version: AI_AZURE_KNOWLEDGE_BASE_API_VERSION}
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
                ai:Embedding? embedding = embeddingValues is ai:Embedding[] ? embeddingValues[i] : ();
                
                index:IndexAction|ai:Error indexAction = createIndexAction(
                    doc,
                    embedding,
                    i,
                    self.keyFieldName,
                    self.contentFieldName,
                    self.vectorFieldNames,
                    self.allFields,
                    self.verbose
                );
                
                if indexAction is ai:Error {
                    return indexAction;
                }

                indexActions.push(indexAction);
            }            
            
            index:IndexBatch batch = {
                value: indexActions
            };

            logIfVerboseEnabled(self.verbose, string 
                `Uploading ${indexActions.length().toString()} documents to Azure AI Search index ${index.name}.`);
            return 'client->documentsIndex(batch.cloneReadOnly(), headers.cloneReadOnly(), queries.cloneReadOnly());
        }
    }
}

# Logs informational or error messages if verbose mode is enabled
#
# + verbose - Whether verbose logging is enabled
# + value - The message to log
# + err - Optional error to log with additional details
isolated function logIfVerboseEnabled(boolean verbose, string value, 'error? err = ()) {
    if verbose {
        log:printInfo(string `[AiSearchKnowledgeBase] ${value}`);
        if err is error {
            log:printError(string `[AiSearchKnowledgeBase] Error Details: ${err.message()}`, err);
        }
    }
}

# Determines the appropriate chunker based on document metadata
#
# + doc - The document or chunk to determine chunker for
# + return - The appropriate chunker for the document type
isolated function guessChunker(ai:Document|ai:Chunk doc) returns ai:Chunker {
    // Guess the chunker based on the document type or mimeType in metadata
    string? mimeType = doc.metadata?.mimeType;
    if mimeType == MIME_TYPE_MARKDOWN {
        return new ai:MarkdownChunker();
    }
    if mimeType == MIME_TYPE_HTML {
        return new ai:HtmlChunker();
    }
    // Fallback to file name
    string? fileName = doc.metadata?.fileName;
    if fileName is string {
        if fileName.endsWith(FILE_EXT_MARKDOWN) {
            return new ai:MarkdownChunker();
        }
        if fileName.endsWith(FILE_EXT_HTML) {
            return new ai:HtmlChunker();
        }
    }
    return new ai:GenericRecursiveChunker();
}

# Converts embeddings to vectors for Azure AI Search
#
# + embedding - The embedding to convert
# + return - The vector representation or an error if conversion fails
isolated function generateVectorFromEmbedding(ai:Embedding embedding) returns ai:Vector|ai:Error {
    if embedding is ai:Vector {
        return embedding;
    } 
    if embedding is ai:HybridVector {
        // Return the dense part, discard sparse
        return embedding.dense;
    }
    // Explicitly fail for sparse-only embeddings
    return error("AiSearchKnowledgeBase only supports dense or hybrid embeddings, but received a SparseVector.");
}

# Formats a JSON value for use in OData expressions
#
# + value - The JSON value to format
# + return - The formatted string or null if type is unsupported
isolated function formatValueForOData(json value) returns string? {
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

# Builds an equality filter for OData
#
# + fieldName - The field name to filter on
# + value - The value to compare
# + return - The formatted equality filter or null if value is unsupported
isolated function buildEqualityFilter(string fieldName, json value) returns string? {
    string? formattedValue = formatValueForOData(value);
    if formattedValue is string {
        return string `${fieldName} ${ODATA_OPERATOR_EQ} ${formattedValue}`;
    }
    return ();
}

# Builds an inequality filter for OData
#
# + fieldName - The field name to filter on
# + value - The value to compare
# + return - The formatted inequality filter or null if value is unsupported
isolated function buildInequalityFilter(string fieldName, json value) returns string? {
    string? formattedValue = formatValueForOData(value);
    if formattedValue is string {
        return string `${fieldName} ${ODATA_OPERATOR_NE} ${formattedValue}`;
    }
    return ();
}

# Builds an IN filter for OData
#
# + fieldName - The field name to filter on
# + value - The array of values to check membership
# + return - The formatted IN filter or null if values are invalid
isolated function buildInFilter(string fieldName, json value) returns string? {
    if value is json[] && value.length() > 0 {
        string[] conditions = [];
        foreach json item in value {
            string? formattedValue = formatValueForOData(item);
            if formattedValue is string {
                conditions.push(string `${fieldName} ${ODATA_OPERATOR_EQ} ${formattedValue}`);
            }
        }
        if conditions.length() > 0 {
            return "(" + string:'join(ODATA_OPERATOR_OR, ...conditions) + ")";
        }
    }
    return ();
}

# Builds a NOT IN filter for OData
#
# + fieldName - The field name to filter on
# + value - The array of values to exclude
# + return - The formatted NOT IN filter or null if values are invalid
isolated function buildNotInFilter(string fieldName, json value) returns string? {
    if value is json[] && value.length() > 0 {
        string[] conditions = [];
        foreach json item in value {
            string? formattedValue = formatValueForOData(item);
            if formattedValue is string {
                conditions.push(string `${fieldName} ${ODATA_OPERATOR_NE} ${formattedValue}`);
            }
        }
        if conditions.length() > 0 {
            return "(" + string:'join(ODATA_OPERATOR_AND, ...conditions) + ")";
        }
    }
    return ();
}

# Builds a comparison filter for OData
#
# + fieldName - The field name to filter on
# + value - The value to compare
# + odataOperator - The OData comparison operator to use
# + return - The formatted comparison filter or null if value is unsupported
isolated function buildComparisonFilter(string fieldName, json value, string odataOperator) returns string? {
    string? formattedValue = formatValueForOData(value);
    if formattedValue is string {
        return string `${fieldName} ${odataOperator} ${formattedValue}`;
    }
    return ();
}

# Extracts a field value from a search result
#
# + result - The search result to extract from
# + fieldName - The name of the field to extract
# + verbose - Whether verbose logging is enabled
# + return - The field value as a string
isolated function extractFieldValue(index:SearchResult result, string fieldName, boolean verbose) returns string {
    anydata fieldValue = result[fieldName];
    if fieldValue is string {
        return fieldValue;
    }
    if fieldValue is () {
        logIfVerboseEnabled(verbose, string `Field ${fieldName} is null in search result.`);
        return "";
    }
    // Handle other types if they are possible content
    return fieldValue.toString();
}

# Extracts metadata from a search result, excluding core fields
#
# + result - The search result to extract metadata from
# + contentFieldName - The name of the content field to exclude
# + keyFieldName - The name of the key field to exclude
# + vectorFieldNames - Array of vector field names to exclude
# + return - The extracted metadata
isolated function extractMetadataFromResult(index:SearchResult result, string contentFieldName, 
        string keyFieldName, string[] vectorFieldNames) returns ai:Metadata {
    ai:Metadata metadata = {};

    // Extract all fields except the core content/title fields as metadata
    map<anydata> clonedResult = result.cloneReadOnly();
    foreach string k in clonedResult.keys() {
        anydata value = clonedResult[k];
        if k != contentFieldName && k != keyFieldName && vectorFieldNames.indexOf(k) == () &&
        k != SEARCH_SCORE_FIELD && k != SEARCH_HIGHLIGHTS_FIELD {
            if value is json {
                metadata[k] = value;
            }
        }
    }
    
    return metadata.cloneReadOnly();
}

# Creates an index action for a document or chunk
#
# + doc - The document or chunk to create action for
# + embedding - Optional embedding for vector fields
# + documentIndex - Index of the document in the batch
# + keyFieldName - Name of the key field
# + contentFieldName - Name of the content field  
# + vectorFieldNames - Array of vector field names
# + allFields - Map of all fields in the index schema
# + verbose - Whether verbose logging is enabled
# + return - The created index action or an error
isolated function createIndexAction(
    ai:Document|ai:Chunk doc,
    ai:Embedding? embedding,
    int documentIndex,
    string keyFieldName,
    string contentFieldName,
    string[] vectorFieldNames,
    map<search:SearchField> allFields,
    boolean verbose
) returns index:IndexAction|ai:Error {
    // Start with the basic action structure
    index:IndexAction indexAction = {
        \@search\.action: SEARCH_ACTION_MERGE_OR_UPLOAD
    };

    // Set the key field with a UUID
    // TODO: handle non-string key fields
    ai:Metadata? metadata = doc.metadata;
    string keyValue = metadata !is () && metadata.hasKey(keyFieldName)
        ? doc.metadata[keyFieldName].toString() + documentIndex.toString()
        : uuid:createType1AsString();
        
    indexAction[keyFieldName] = keyValue;
    logIfVerboseEnabled(
        verbose, string `Set key field ${keyFieldName} to value ${keyValue} for document index ${documentIndex}.`);

    // Add embeddings to vector fields if available
    if embedding is ai:Embedding {
        foreach string vectorFieldName in vectorFieldNames {
            ai:Vector|ai:Error vectors = generateVectorFromEmbedding(embedding);
            if vectors is ai:Error {
                logIfVerboseEnabled(
                    verbose, string 
                        `Failed to generate vector for document index ${documentIndex} and field ${vectorFieldName}: ${vectors.message()}`);
                return vectors;
            }

            indexAction[vectorFieldName] = vectors;
            logIfVerboseEnabled(
                verbose, string `Added vector for document index ${documentIndex} to field ${vectorFieldName}.`);
        }
    }
    
    indexAction[contentFieldName] = doc.content;
    logIfVerboseEnabled(
        verbose, string `Added content for document index ${documentIndex} to field ${contentFieldName}.`);

    // Add document type if there's a field for it (check if "type" field exists)
    if allFields.hasKey(DEFAULT_TYPE_FIELD_NAME) {
        indexAction[DEFAULT_TYPE_FIELD_NAME] = doc.'type;
    }

    // Add metadata fields
    if metadata is ai:Metadata {
        foreach [string, json] [key, value] in metadata.entries() {
            boolean isPossibleMetadata = key != keyFieldName && key != contentFieldName 
                    && vectorFieldNames.indexOf(key) == ();
            // Only add metadata if the field exists in the index schema
            if allFields.hasKey(key) && isPossibleMetadata {
                indexAction[key] = value;
            } else {
                if isPossibleMetadata {
                    logIfVerboseEnabled(
                        verbose, string `Skipping field ${key} as it does not exist in index schema.`);
                }
            }
        }
    }

    return indexAction;
}

isolated function analyzeIndexSchema(
        boolean verbose, search:SearchIndex index, string contentFieldName) returns IndexSchemaInfo|ai:Error {
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
        logIfVerboseEnabled(verbose, "No vector fields found in index schema.");
    }

    if contentFieldNames.length() == 0 {
        return error(string `Index schema must contains a field named '${contentFieldName}'.`);
    }

    if keyFieldName is () {
        logIfVerboseEnabled(verbose, string `No key field defined in index schema. Using default key field name as '${KEY_FIELD_NAME}'.`);
    }

    if vectorFieldNames.length() > 1 {
        logIfVerboseEnabled(verbose, string 
            `Multiple vector fields found in index schema: ${string:'join(", ", ...vectorFieldNames)}. Currently one vecotr field is prefered. So for now, there is more than one, all the vector fileds will share the same vectors.`);
    }
    
    return {
        keyFieldName: keyFieldName ?: KEY_FIELD_NAME,
        vectorFieldNames: vectorFieldNames,
        contentFieldNames: contentFieldNames,
        allFields: allFields
    };
}
