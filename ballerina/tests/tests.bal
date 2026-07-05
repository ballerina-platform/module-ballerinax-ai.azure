// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
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

const SERVICE_URL = "http://localhost:8080/llm/azureopenai";
// A `/v1`-suffixed service URL selects the Azure OpenAI Responses v1 GA surface (`{serviceUrl}/responses`).
const SERVICE_URL_V1 = "http://localhost:8080/llm/azureopenai/openai/v1";
const DEPLOYMENT_ID = "gpt4onew";
// `API_VERSION` is exactly the 2024-08-01-preview threshold — the Chat Completions path sends
// `max_completion_tokens` for it. `NEW_API_VERSION` is comfortably past the threshold, and `OLD_API_VERSION`
// predates it (so the Chat Completions path must fall back to `max_tokens`).
const API_VERSION = "2024-08-01-preview";
const NEW_API_VERSION = "2025-04-01-preview";
const OLD_API_VERSION = "2024-02-15-preview";
const API_KEY = "not-a-real-api-key";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RUNTIME_SCHEMA_NOT_SUPPORTED_ERROR_MESSAGE = "Runtime schema generation is not yet supported";

// `OpenAiModelProvider` with the default `RESPONSES` API type — exercises the Azure OpenAI Responses API via the
// legacy preview route (the service URL does not end with `/v1`), which appends `?api-version=...`.
final OpenAiModelProvider openAiProvider = check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION);
final OpenAiModelProvider responsesProvider = check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION);

// `OpenAiModelProvider` targeting the Responses v1 GA surface (`/v1`-suffixed service URL, no `api-version`).
final OpenAiModelProvider responsesV1Provider = check new (SERVICE_URL_V1, API_KEY, DEPLOYMENT_ID, API_VERSION);

// `OpenAiModelProvider` with the `CHAT_COMPLETION` API type — exercises the Azure OpenAI Chat Completions API.
final OpenAiModelProvider chatCompletionProvider =
    check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION, apiType = CHAT_COMPLETION);

// `CHAT_COMPLETION` providers pinned to a new (post-threshold) and an old (pre-threshold) api-version, used to
// verify the token-limit field selection end-to-end through the mock's `assertChatCompletionTokenField` guard.
final OpenAiModelProvider chatCompletionNewApiVersionProvider =
    check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, NEW_API_VERSION, apiType = CHAT_COMPLETION);
final OpenAiModelProvider chatCompletionOldApiVersionProvider =
    check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, OLD_API_VERSION, apiType = CHAT_COMPLETION);

string apiKey = "mock-api-key";
string serviceUrl = "http://localhost:8080/llm";
string embeddingDeploymentId = "text-embed-3-small";
EmbeddingProvider embeddingProvider = check new (serviceUrl, apiKey, API_VERSION, DEPLOYMENT_ID);

@test:Config {}
function testEmbeddings() returns error? {
    ai:TextChunk chunk = {
        content: "Hello, world!"
    };
    ai:Embedding data = check embeddingProvider->embed(chunk);
    float[] vectors = check data.cloneWithType();
    test:assertEquals(vectors.length(), 1536);
}

@test:Config {}
function testBatchEmbeddings() returns error? {
    ai:TextChunk[] chunks = [
        {
            content: "Hello, world!"
        }, {
            content: "Hello, world!!!"
        }
    ];
    ai:Embedding[] results = check embeddingProvider->batchEmbed(chunks);
    test:assertEquals(results.length(), 2);
    foreach ai:Embedding result in results {
        float[] vectors = check result.cloneWithType();
        test:assertEquals(vectors.length(), 1536);
    }
}

@test:Config
function testGenerateMethodWithBasicReturnType() returns ai:Error? {
    int|error rating = openAiProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateMethodWithBasicArrayReturnType() returns ai:Error? {
    int[]|error rating = openAiProvider->generate(`Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, [9, 1]);
}

@test:Config
function testGenerateMethodWithRecordReturnType() returns error? {
    Review|error result = openAiProvider->generate(`Please rate this blog out of ${"10"}.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testGenerateMethodWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    int|error rating = openAiProvider->generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}.`);
    test:assertEquals(rating, 4);
}

type ReviewArray Review[];

@test:Config
function testGenerateMethodWithTextDocumentArray() returns error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    ai:TextDocument[] blogs = [blog, blog];
    int maxScore = 10;
    Review r = check review.fromJsonStringWithType(Review);

    ReviewArray|error result = openAiProvider->generate(`How would you rate these text blogs out of ${maxScore}. ${blogs}. Thank you!`);
    test:assertEquals(result, [r, r]);
}

@test:Config
function testGenerateMethodWithImageDocumentWithBinaryData() returns ai:Error? {
    ai:ImageDocument img = {
        content: sampleBinaryData
    };

    string|error description = openAiProvider->generate(`Describe the following image. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateMethodWithImageDocumentWithUrl() returns ai:Error? {
    ai:ImageDocument img = {
        content: "https://example.com/image.jpg",
        metadata: {
            mimeType: "image/jpg"
        }
    };

    string|error description = openAiProvider->generate(`Describe the image. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testGenerateMethodWithImageDocumentWithInvalidUrl() returns ai:Error? {
    ai:ImageDocument img = {
        content: "This-is-not-a-valid-url"
    };

    string|ai:Error description = openAiProvider->generate(`Please describe the image. ${img}.`);
    test:assertTrue(description is ai:Error);

    string actualErrorMessage = (<ai:Error>description).message();
    string expectedErrorMessage = "Must be a valid URL";
    test:assertTrue((<ai:Error>description).message().includes("Must be a valid URL"),
            string `expected '${expectedErrorMessage}', found ${actualErrorMessage}`);
}

@test:Config
function testGenerateMethodWithImageDocumentArray() returns ai:Error? {
    ai:ImageDocument img = {
        content: sampleBinaryData,
        metadata: {
            mimeType: "image/png"
        }
    };
    ai:ImageDocument img2 = {
        content: "https://example.com/image.jpg"
    };

    string[]|error descriptions = openAiProvider->generate(
        `Describe the following ${"2"} images. ${<ai:ImageDocument[]>[img, img2]}.`);
    test:assertEquals(descriptions, ["This is a sample image description.", "This is a sample image description."]);
}

@test:Config
function testGenerateMethodWithTextAndImageDocumentArray() returns ai:Error? {
    ai:ImageDocument img = {
        content: sampleBinaryData,
        metadata: {
            mimeType: "image/png"
        }
    };
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };

    string[]|error descriptions = openAiProvider->generate(
        `Please describe the following image and the doc. ${<ai:Document[]>[img, blog]}.`);
    test:assertEquals(descriptions, ["This is a sample image description.", "This is a sample doc description."]);
}

@test:Config
function testGenerateMethodWithImageDocumentsandTextDocuments() returns ai:Error? {
    ai:ImageDocument img = {
        content: sampleBinaryData,
        metadata: {
            mimeType: "image/png"
        }
    };
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };

    string[]|error descriptions = openAiProvider->generate(
        `${"Describe"} the following ${"text"} ${"document"} and image document. ${img}${blog}`);
    test:assertEquals(descriptions, ["This is a sample image description.", "This is a sample doc description."]);
}

@test:Config
function testGenerateMethodWithAudioDocument() returns ai:Error? {
    ai:AudioDocument aud = {
        content: sampleBinaryData,
        metadata: {
            "format": "mp3"
        }
    };

    // Audio input is only supported on the Chat Completions API path.
    string|error description = chatCompletionProvider->generate(`Please describe the audio content. ${aud}.`);
    test:assertEquals(description, "This is a sample audio description.");

    string[]|error descriptions = chatCompletionProvider->generate(
        `Please describe the following audio contents. ${<ai:AudioDocument[]>[aud, aud]}.`);
    test:assertEquals(descriptions, ["This is a sample audio description.", "This is a sample audio description."]);

    ai:AudioDocument aud2 = {
        content: sampleBinaryData
    };

    description = chatCompletionProvider->generate(`Please describe the audio content. ${aud2}.`);
    if description is string {
        test:assertFail();
    }

    test:assertTrue(description is ai:Error);
    test:assertTrue((<ai:Error>description).message().includes(
            "Please specify the audio format in the 'format' field of the metadata; supported values are 'mp3' and 'wav'"
            ));
}

@test:Config
function testGenerateMethodWithUnsupportedDocument() returns ai:Error? {
    ai:FileDocument doc = {
        content: "dummy-data"
    };

    string[]|error descriptions = openAiProvider->generate(`What is the content in this document. ${doc}.`);
    test:assertTrue(descriptions is error);
    test:assertTrue((<error>descriptions).message().includes("Only text, image and audio documents are supported."));
}

@test:Config
function testGenerateMethodWithRecordArrayReturnType() returns error? {
    int maxScore = 10;
    Review r = check review.fromJsonStringWithType(Review);

    ReviewArray|error result = openAiProvider->generate(`Please rate this blogs out of ${maxScore}.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`);
    test:assertEquals(result, [r, r]);
}

@test:Config
function testGenerateMethodWithInvalidBasicType() returns ai:Error? {
    boolean|error rating = openAiProvider->generate(`What is ${1} + ${1}?`);
    test:assertTrue(rating is error);
    test:assertTrue((<error>rating).message().includes(ERROR_MESSAGE));
}

type ProductName record {|
    string name;
|};

@test:Config
function testGenerateMethodWithInvalidRecordType() returns ai:Error? {
    ProductName[]|map<string>|error rating = trap openAiProvider->generate(
                `Tell me name and the age of the top 10 world class cricketers`);
    string msg = (<error>rating).message();
    test:assertTrue(rating is error);
    test:assertTrue(msg.includes(RUNTIME_SCHEMA_NOT_SUPPORTED_ERROR_MESSAGE),
            string `expected error message to contain: ${RUNTIME_SCHEMA_NOT_SUPPORTED_ERROR_MESSAGE}, but found ${msg}`);
}

type ProductNameArray ProductName[];

@test:Config
function testGenerateMethodWithInvalidRecordArrayType2() returns ai:Error? {
    ProductNameArray|error rating = openAiProvider->generate(
                `Tell me name and the age of the top 10 world class cricketers`);
    test:assertTrue(rating is error);
    test:assertTrue((<error>rating).message().includes(ERROR_MESSAGE));
}

type Cricketers record {|
    string name;
|};

type Cricketers1 record {|
    string name;
|};

type Cricketers2 record {|
    string name;
|};

type Cricketers3 record {|
    string name;
|};

type Cricketers4 record {|
    string name;
|};

type Cricketers5 record {|
    string name;
|};

type Cricketers6 record {|
    string name;
|};

type Cricketers7 record {|
    string name;
|};

type Cricketers8 record {|
    string name;
|};

@test:Config
function testGenerateMethodWithStringUnionNull() returns error? {
    string? result = check openAiProvider->generate(`Give me a random joke`);
    test:assertTrue(result is string);
}

@test:Config
function testGenerateMethodWithRecUnionBasicType() returns error? {
    Cricketers|string result = check openAiProvider->generate(`Give me a random joke about cricketers`);
    test:assertTrue(result is string);
}

@test:Config
function testGenerateMethodWithRecUnionNull() returns error? {
    Cricketers1? result = check openAiProvider->generate(`Name a random world class cricketer in India`);
    test:assertTrue(result is Cricketers1);
}

@test:Config
function testGenerateMethodWithArrayOnly() returns error? {
    Cricketers2[] result = check openAiProvider->generate(`Name 10 world class cricketers in India`);
    test:assertTrue(result is Cricketers2[]);
}

@test:Config
function testGenerateMethodWithArrayUnionBasicType() returns error? {
    Cricketers3[]|string result = check openAiProvider->generate(`Name 10 world class cricketers as string`);
    test:assertTrue(result is Cricketers3[]);
}


@test:Config
function testGenerateMethodWithArrayUnionNull() returns error? {
    Cricketers4[]? result = check openAiProvider->generate(`Name 10 world class cricketers`);
    test:assertTrue(result is Cricketers4[]);
}

@test:Config
function testGenerateMethodWithArrayUnionRecord() returns ai:Error? {
    Cricketers5[]|Cricketers6|error result = openAiProvider->generate(`Name top 10 world class cricketers`);
    test:assertTrue(result is Cricketers5[]);
}

@test:Config
function testGenerateMethodWithArrayUnionRecord2() returns ai:Error? {
   Cricketers7[]|Cricketers8|error result = openAiProvider->generate(`Name a random world class cricketer`);
    test:assertTrue(result is Cricketers8);
}

// ===== Responses API: generate() tests =====

@test:Config
function testResponsesGenerateMethodWithBasicReturnType() returns ai:Error? {
    int|error rating = responsesProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testResponsesGenerateMethodWithBasicArrayReturnType() returns ai:Error? {
    int[]|error rating = responsesProvider->generate(`Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, [9, 1]);
}

@test:Config
function testResponsesGenerateMethodWithRecordReturnType() returns error? {
    Review|error result = responsesProvider->generate(`Please rate this blog out of ${"10"}.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testResponsesGenerateMethodWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    int|error rating = responsesProvider->generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}.`);
    test:assertEquals(rating, 4);
}

@test:Config
function testResponsesGenerateMethodWithImageDocumentWithUrl() returns ai:Error? {
    ai:ImageDocument img = {
        content: "https://example.com/image.jpg",
        metadata: {
            mimeType: "image/jpg"
        }
    };

    string|error description = responsesProvider->generate(`Describe the image. ${img}.`);
    test:assertEquals(description, "This is a sample image description.");
}

@test:Config
function testResponsesGenerateMethodWithRecordArrayReturnType() returns error? {
    int maxScore = 10;
    Review r = check review.fromJsonStringWithType(Review);

    ReviewArray|error result = responsesProvider->generate(`Please rate this blogs out of ${maxScore}.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`);
    test:assertEquals(result, [r, r]);
}

@test:Config
function testResponsesGenerateMethodWithStringUnionNull() returns error? {
    string? result = check responsesProvider->generate(`Give me a random joke`);
    test:assertTrue(result is string);
}

// ===== Responses API: chat() tests =====

@test:Config
function testResponsesChatWithSimpleMessage() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check responsesProvider->chat(userMsg, []);
    test:assertTrue(result.content is string);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testResponsesChatWithMessageArray() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are a helpful assistant."},
        <ai:ChatUserMessage>{role: "user", content: "Hello, how are you?"}
    ];
    ai:ChatAssistantMessage result = check responsesProvider->chat(messages, []);
    test:assertTrue(result.content is string);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testResponsesChatWithTools() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {
                "type": "object",
                "properties": {
                    "city": {"type": "string"}
                },
                "required": ["city"]
            }
        }
    ];
    ai:ChatAssistantMessage result = check responsesProvider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls).length(), 1);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "London"});
}

// ===== Responses API: v1 GA surface tests =====
// These use a `/v1`-suffixed service URL and hit `POST {serviceUrl}/responses` with NO `api-version`.

@test:Config
function testResponsesV1GenerateMethod() returns ai:Error? {
    int|error rating = responsesV1Provider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testResponsesV1ChatWithSimpleMessage() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check responsesV1Provider->chat(userMsg, []);
    test:assertTrue(result.content is string);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testResponsesV1ChatWithMessageArray() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are a helpful assistant."},
        <ai:ChatUserMessage>{role: "user", content: "Hello, how are you?"}
    ];
    ai:ChatAssistantMessage result = check responsesV1Provider->chat(messages, []);
    test:assertTrue(result.content is string);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testResponsesV1ChatWithTools() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {
                "type": "object",
                "properties": {
                    "city": {"type": "string"}
                },
                "required": ["city"]
            }
        }
    ];
    ai:ChatAssistantMessage result = check responsesV1Provider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls).length(), 1);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "London"});
}

// ===== Chat Completions API (`apiType = CHAT_COMPLETION`) tests =====
// These hit the deployment-scoped Azure OpenAI Chat Completions endpoint:
//   /openai/deployments/{deploymentId}/chat/completions?api-version=...

@test:Config
function testChatCompletionChatWithSimpleMessage() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testChatCompletionChatWithMessageArray() returns ai:Error? {
    ai:ChatMessage[] messages = [
        <ai:ChatSystemMessage>{role: "system", content: "You are a helpful assistant."},
        <ai:ChatUserMessage>{role: "user", content: "Hello, how are you?"}
    ];
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(messages, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

@test:Config
function testChatCompletionChatWithTools() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {
                "type": "object",
                "properties": {
                    "city": {"type": "string"}
                },
                "required": ["city"]
            }
        }
    ];
    ai:ChatAssistantMessage result = check chatCompletionProvider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].arguments, {"city": "London"});
}

// Note: `generate()` via the Chat Completions API exercises the native `Generator`, so it requires the
// native JAR (`ai.azure-native`) to be rebuilt from `native/` before running.
@test:Config
function testChatCompletionGenerateMethodWithBasicReturnType() returns ai:Error? {
    int|error rating = chatCompletionProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

// ===== Chat Completions API: token-limit field selection (max_tokens vs max_completion_tokens) =====
// The wire body is asserted inside the mock via `assertChatCompletionTokenField`; these tests drive the two
// api-version branches end-to-end so that guard actually runs against a real request.

// api-version >= 2024-08-01-preview: chat() must send `max_completion_tokens` and never `max_tokens`.
@test:Config
function testChatCompletionNewApiVersionSendsMaxCompletionTokens() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check chatCompletionNewApiVersionProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// api-version < 2024-08-01-preview: chat() must fall back to `max_tokens` and never send `max_completion_tokens`.
@test:Config
function testChatCompletionOldApiVersionSendsMaxTokens() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "Hello, how are you?"};
    ai:ChatAssistantMessage result = check chatCompletionOldApiVersionProvider->chat(userMsg, []);
    test:assertEquals(result.content, "This is a mock response for: Hello, how are you?");
}

// The token-limit selection must also apply when tools are present (the request-building path differs slightly).
@test:Config
function testChatCompletionOldApiVersionWithToolsSendsMaxTokens() returns ai:Error? {
    ai:ChatUserMessage userMsg = {role: "user", content: "What is the weather in London?"};
    ai:ChatCompletionFunctions[] tools = [
        {
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: {
                "type": "object",
                "properties": {
                    "city": {"type": "string"}
                },
                "required": ["city"]
            }
        }
    ];
    ai:ChatAssistantMessage result = check chatCompletionOldApiVersionProvider->chat(userMsg, tools);
    ai:FunctionCall[]? toolCalls = result.toolCalls;
    test:assertTrue(toolCalls is ai:FunctionCall[]);
    test:assertEquals((<ai:FunctionCall[]>toolCalls)[0].name, "get_weather");
}

