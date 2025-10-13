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
import ballerinax/azure.openai.embeddings;

# EmbeddingProvider provides an interface for interacting with Azure OpenAI Embedding Models.
public distinct isolated client class EmbeddingProvider {
    *ai:EmbeddingProvider;
    private final embeddings:Client embeddingsClient;
    private final string apiVersion;
    private final string deploymentId;

    # Initializes the OpenAI embedding model with the given connection configuration.
    #
    # + serviceUrl - The base URL of OpenAI API endpoint
    # + accessToken - The access token for authenticating API requests
    # + apiVersion - The API version of the Azure OpenAI API
    # + deploymentId - The deployment ID of the embedding model
    #
    # + return - `nil` on successful initialization; otherwise, returns an `ai:Error`
    public isolated function init(
            @display {label: "Service URL"} string serviceUrl,
            @display {label: "Access Token"} string accessToken,
            @display {label: "API Version"} string apiVersion,
            @display {label: "Deployment ID"} string deploymentId,
            @display {label: "HTTP Configuration"} *ConnectionConfig config) returns ai:Error? {
        embeddings:ClientHttp1Settings?|error http1Settings = config?.http1Settings.cloneWithType();
        if http1Settings is error {
            return error ai:Error("Failed to clone http1Settings", http1Settings);
        }
        embeddings:ConnectionConfig openAiConfig = {
            auth: {
                apiKey: accessToken
            },
            httpVersion: config.httpVersion,
            http1Settings: http1Settings,
            http2Settings: config.http2Settings,
            timeout: config.timeout,
            forwarded: config.forwarded,
            poolConfig: config.poolConfig,
            cache: config.cache,
            compression: config.compression,
            circuitBreaker: config.circuitBreaker,
            retryConfig: config.retryConfig,
            responseLimits: config.responseLimits,
            secureSocket: config.secureSocket,
            proxy: config.proxy,
            validation: config.validation
        };
        embeddings:Client|error embeddingsClient = new (openAiConfig, serviceUrl);
        if embeddingsClient is error {
            return error ai:Error("Failed to initialize OpenAI embedding provider", embeddingsClient);
        }
        self.embeddingsClient = embeddingsClient;
        self.apiVersion = apiVersion;
        self.deploymentId = deploymentId;
    }

    # Generates an embedding vector for the provided chunk.
    #
    # + chunk - The `ai:Chunk` containing the content to embed
    # + return - The resulting `ai:Embedding` on success; otherwise, returns an `ai:Error`
    isolated remote function embed(ai:Chunk chunk) returns ai:Embedding|ai:Error {
        if chunk !is ai:TextDocument|ai:TextChunk {
            return error ai:Error("Unsupported document type. only 'ai:TextDocument' or 'ai:TextChunk' is supported");
        }
        do {
            embeddings:Inline_response_200 response = check self.embeddingsClient->/deployments/[self.deploymentId]/embeddings.post(
                apiVersion = self.apiVersion,
                payload = {
                    input: chunk.content
                }
            );
            return check response.data[0].embedding.cloneWithType();
        } on fail error e {
            return error ai:Error("Unable to obtain embedding for the provided chunk", e);
        }
    }

    # Converts a batch of chunks into embeddings.
    #
    # + chunks - The array of chunks to be converted into embeddings
    # + return - An array of embeddings on success, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error {
        if !chunks.every(chunk => chunk is ai:TextChunk|ai:TextDocument) {
            return error("Unsupported chunk type. only 'ai:TextChunk[]|ai:TextDocument[]' is supported");
        }
        do {
            embeddings:InputItemsString[] inputItems = from ai:Chunk chunk in chunks
                select check chunk.content.cloneWithType();
            embeddings:Inline_response_200 response = check self.embeddingsClient->/deployments/[self.deploymentId]/embeddings.post(
                apiVersion = self.apiVersion,
                payload = {
                    input: inputItems
                }
            );
            return
                from embeddings:Inline_response_200_data data in response.data
                    select check data.embedding.cloneWithType();
        } on fail error e {
            return error ai:Error("Unable to obtain embedding for the provided document", e);
        }
    }
}
