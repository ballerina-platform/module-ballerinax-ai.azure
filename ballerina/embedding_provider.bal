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
import ballerina/ai.observe;
import ballerina/http;
import ballerinax/azure.openai.embeddings;

# EmbeddingProvider provides an interface for interacting with Azure OpenAI Embedding Models.
#
# The concrete wire route depends on the shape of the `serviceUrl`: a URL ending with `/v1` targets the Azure OpenAI
# **v1 GA** surface (`POST {serviceUrl}/embeddings`, with the deployment sent as `model` in the body and no
# `api-version` required), while any other URL targets the **legacy** deployment-scoped route
# (`POST {serviceUrl}/deployments/{deploymentId}/embeddings?api-version=...`) through the generated
# `ballerinax/azure.openai.embeddings` connector.
public distinct isolated client class EmbeddingProvider {
    *ai:EmbeddingProvider;
    # Generated Embeddings connector for the legacy deployment-scoped route. Created only when the `serviceUrl`
    # targets the legacy surface; `()` otherwise.
    private final embeddings:Client? embeddingsClient;
    # Raw HTTP client for the v1 GA route (`POST {serviceUrl}/embeddings`). Created only when the `serviceUrl`
    # targets the v1 GA surface; `()` otherwise. A raw client (rather than the connector) is used because the
    # generated connector models `api-version` as a required query parameter on the deployment-scoped route only.
    private final http:Client? v1EmbeddingsClient;
    # `true` when the `serviceUrl` targets the v1 GA surface (ends with `/v1`); `false` for the legacy surface.
    private final boolean useV1;
    private final string apiKey;
    # Date-based `api-version` used on the legacy route; `()` on the v1 GA surface.
    private final string? apiVersion;
    # `preview`/`v1` api-version forwarded on the v1 GA surface, if the caller opted into one; `()` otherwise.
    private final string? v1ApiVersion;
    private final string deploymentId;

    # Initializes the OpenAI embedding model with the given connection configuration.
    #
    # + serviceUrl - The base URL of OpenAI API endpoint. A URL ending with `/v1`
    #              (e.g. `https://<resource>.openai.azure.com/openai/v1`) targets the v1 GA surface; any other URL
    #              (e.g. `https://<resource>.openai.azure.com/openai`) targets the legacy route.
    # + accessToken - The access token for authenticating API requests
    # + apiVersion - The API version of the Azure OpenAI API. **Required** for legacy (non-`/v1`) service URLs
    #              (e.g. `"2023-05-15"`). For v1 (`/v1`) service URLs the value is optional and normally passed as
    #              `()`; pass `"preview"` or `"v1"` to opt into a specific v1 surface (any other value is ignored
    #              on v1 URLs).
    # + deploymentId - The deployment ID of the embedding model
    # + config - The connection configurations for the HTTP endpoint
    #
    # + return - `nil` on successful initialization; otherwise, returns an `ai:Error`
    public isolated function init(
            @display {label: "Service URL"} string serviceUrl,
            @display {label: "Access Token"} string accessToken,
            @display {label: "API Version"} string? apiVersion,
            @display {label: "Deployment ID"} string deploymentId,
            @display {label: "HTTP Configurations"} *ConnectionConfig config) returns ai:Error? {
        // Drop a single trailing slash so the suffix check below operates on a canonical form.
        string trimmedUrl = serviceUrl.endsWith("/") ? serviceUrl.substring(0, serviceUrl.length() - 1) : serviceUrl;
        boolean isV1 = trimmedUrl.endsWith("/v1");
        self.useV1 = isV1;

        // Resolve the api-version for the selected surface (shared with the model provider).
        [string?, string?] [resolvedApiVersion, resolvedV1ApiVersion] = check resolveApiVersions(isV1, apiVersion);
        self.apiVersion = resolvedApiVersion;
        self.v1ApiVersion = resolvedV1ApiVersion;

        // Create only the client required by the selected surface; the unused field stays `()`.
        [embeddings:Client?, http:Client?] [embeddingsClient, v1EmbeddingsClient] =
                check createEmbeddingsClients(isV1, accessToken, trimmedUrl, config);
        self.embeddingsClient = embeddingsClient;
        self.v1EmbeddingsClient = v1EmbeddingsClient;
        self.apiKey = accessToken;
        self.deploymentId = deploymentId;
    }

    # Generates an embedding vector for the provided chunk.
    #
    # + chunk - The `ai:Chunk` containing the content to embed
    # + return - The resulting `ai:Embedding` on success; otherwise, returns an `ai:Error`
    isolated remote function embed(ai:Chunk chunk) returns ai:Embedding|ai:Error {
        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.deploymentId);
        span.addProvider("azure.ai.openai");

        if chunk !is ai:TextDocument|ai:TextChunk {
            ai:Error err = error ai:Error("Unsupported chunk type. only 'ai:TextDocument|ai:TextChunk' is supported");
            span.close(err);
            return err;
        }

        do {
            span.addInputContent(chunk.content);
            embeddings:Inline_response_200 response = check postEmbeddings(self.embeddingsClient,
                    self.v1EmbeddingsClient, self.useV1, self.apiKey, self.deploymentId, self.apiVersion,
                    self.v1ApiVersion, chunk.content);

            span.addResponseModel(response.model);
            span.addInputTokenCount(response.usage.prompt_tokens);
            if response.data.length() == 0 {
                ai:Error err = error("No embeddings generated for the provided chunk");
                span.close(err);
                return err;
            }

            ai:Embedding embedding = check response.data[0].embedding.cloneWithType();
            span.close();
            return embedding;
        } on fail error e {
            ai:Error err = error ai:Error("Unable to obtain embedding for the provided chunk", e);
            span.close(err);
            return err;
        }
    }

    # Converts a batch of chunks into embeddings.
    #
    # + chunks - The array of chunks to be converted into embeddings
    # + return - An array of embeddings on success, or an `ai:Error`
    isolated remote function batchEmbed(ai:Chunk[] chunks) returns ai:Embedding[]|ai:Error {
        observe:EmbeddingSpan span = observe:createEmbeddingSpan(self.deploymentId);
        span.addProvider("azure.ai.openai");

        if !chunks.every(chunk => chunk is ai:TextChunk|ai:TextDocument) {
            ai:Error err = error("Unsupported chunk type. only 'ai:TextChunk[]|ai:TextDocument[]' is supported");
            span.close(err);
            return err;
        }
        do {
            string[] input = chunks.map(chunk => chunk.content.toString());
            span.addInputContent(input);

            embeddings:InputItemsString[] inputItems = from ai:Chunk chunk in chunks
                select check chunk.content.cloneWithType();
            embeddings:Inline_response_200 response = check postEmbeddings(self.embeddingsClient,
                    self.v1EmbeddingsClient, self.useV1, self.apiKey, self.deploymentId, self.apiVersion,
                    self.v1ApiVersion, inputItems);

            span.addInputTokenCount(response.usage.prompt_tokens);
            ai:Embedding[] embeddings = from embeddings:Inline_response_200_data data in response.data
                select check data.embedding.cloneWithType();
            span.close();
            return embeddings;
        } on fail error e {
            ai:Error err = error("Unable to obtain embedding for the provided document", e);
            span.close(err);
            return err;
        }
    }
}

# Creates only the embeddings client required by the selected surface; the unused client is returned as `()`.
#
# + isV1 - `true` when the `serviceUrl` targets the v1 GA surface (ends with `/v1`); `false` for the legacy surface
# + accessToken - The Azure OpenAI API key
# + trimmedUrl - The trailing-slash-trimmed service URL
# + config - Additional HTTP connection configuration
# + return - An `[embeddingsClient, v1EmbeddingsClient]` tuple, or an `ai:Error` when client initialization fails
isolated function createEmbeddingsClients(boolean isV1, string accessToken, string trimmedUrl,
        ConnectionConfig config) returns [embeddings:Client?, http:Client?]|ai:Error {
    if isV1 {
        http:Client|error v1EmbeddingsClient = new (trimmedUrl, toRawHttpConfig(config));
        if v1EmbeddingsClient is error {
            return error ai:Error("Failed to initialize Azure OpenAI Embeddings (v1) client", v1EmbeddingsClient);
        }
        return [(), v1EmbeddingsClient];
    }
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
    embeddings:Client|error embeddingsClient = new (openAiConfig, trimmedUrl);
    if embeddingsClient is error {
        return error ai:Error("Failed to initialize OpenAI embedding provider", embeddingsClient);
    }
    return [embeddingsClient, ()];
}

# Posts an embeddings request to the configured surface.
#
# - **v1 GA** (`useV1` is `true`): the raw HTTP client posts `{serviceUrl}/embeddings` with the deployment sent as
#   `model` in the body and the `api-key` header. `api-version` is only sent when the caller opted into
#   `preview`/`v1` (`v1ApiVersion`).
# - **Legacy** (otherwise): the generated connector posts
#   `POST {serviceUrl}/deployments/{deploymentId}/embeddings?api-version={apiVersion}`.
#
# + embeddingsClient - The generated Embeddings connector for the legacy route (`()` on the v1 path)
# + v1EmbeddingsClient - The raw HTTP client for the v1 GA route (`()` on the legacy path)
# + useV1 - `true` to target the v1 GA surface; `false` for the legacy route
# + apiKey - The Azure OpenAI API key (sent as `api-key` on the v1 route)
# + deploymentId - The Azure deployment ID
# + apiVersion - The date-based `api-version` query value used on the legacy route
# + v1ApiVersion - The `preview`/`v1` api-version to forward on the v1 route, if any
# + input - The text (or batch of texts) to embed
# + return - The parsed embeddings response, or an `error` on failure
isolated function postEmbeddings(embeddings:Client? embeddingsClient, http:Client? v1EmbeddingsClient, boolean useV1,
        string apiKey, string deploymentId, string? apiVersion, string? v1ApiVersion,
        string|embeddings:InputItemsString[] input) returns embeddings:Inline_response_200|error {
    if useV1 {
        http:Client? embeddingClient = v1EmbeddingsClient;
        if embeddingClient is () {
            return error("Embeddings (v1) client is not initialized");
        }
        // The v1 GA route carries the deployment as `model` in the body rather than in the URL path.
        map<json> body = {model: deploymentId, input: input};
        string path = v1ApiVersion is string ? string `/embeddings?api-version=${v1ApiVersion}` : "/embeddings";
        embeddings:Inline_response_200 response = check embeddingClient->post(path, body, {"api-key": apiKey});
        return response;
    }

    embeddings:Client? legacyEmbeddingsClient = embeddingsClient;
    if legacyEmbeddingsClient is () {
        return error("Embeddings (legacy) client is not initialized");
    }
    return legacyEmbeddingsClient->/deployments/[deploymentId]/embeddings.post(
        apiVersion = apiVersion ?: "",
        payload = {
            input: input
        }
    );
}
