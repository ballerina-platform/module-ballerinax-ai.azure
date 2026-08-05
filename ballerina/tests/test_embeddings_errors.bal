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
import ballerina/test;

// An embedding provider whose endpoint is unreachable, used to drive the request-failure branches.
final EmbeddingProvider unreachableEmbeddingProvider = check new ("http://localhost:8099/nowhere", apiKey,
    API_VERSION, DEPLOYMENT_ID);

// ===== unsupported chunk types =====

@test:Config
function testEmbedUnsupportedChunkType() returns error? {
    ai:ImageDocument img = {content: "https://example.com/i.png"};
    ai:Embedding|ai:Error result = embeddingProvider->embed(img);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unsupported chunk type"));
}

@test:Config
function testBatchEmbedUnsupportedChunkType() returns error? {
    ai:ImageDocument img = {content: "https://example.com/i.png"};
    ai:Embedding[]|ai:Error result = unreachableEmbeddingProvider->batchEmbed([img]);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unsupported chunk type"));
}

// ===== empty response =====

@test:Config
function testEmbedNoEmbeddingsGenerated() returns error? {
    ai:TextChunk chunk = {content: EMPTY_EMBED_TRIGGER};
    ai:Embedding|ai:Error result = embeddingProvider->embed(chunk);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("No embeddings generated"));
}

// ===== request failures =====

@test:Config
function testEmbedRequestFailure() returns error? {
    ai:TextChunk chunk = {content: "hello"};
    ai:Embedding|ai:Error result = unreachableEmbeddingProvider->embed(chunk);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unable to obtain embedding"));
}

@test:Config
function testBatchEmbedRequestFailure() returns error? {
    ai:TextChunk[] chunks = [{content: "hello"}, {content: "world"}];
    ai:Embedding[]|ai:Error result = unreachableEmbeddingProvider->batchEmbed(chunks);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Unable to obtain embedding"));
}

// ===== init failure =====

@test:Config
function testEmbeddingProviderInitFailsForInvalidUrl() {
    EmbeddingProvider|ai:Error provider = new ("http://invalid host/v1", apiKey, API_VERSION, DEPLOYMENT_ID);
    test:assertTrue(provider is ai:Error, "init must fail for a malformed service URL");
    test:assertTrue((<ai:Error>provider).message().includes("Failed to initialize"));
}
