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
const DEPLOYMENT_ID = "gpt4onew";
const API_VERSION = "2023-08-01-preview";
const API_KEY = "not-a-real-api-key";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RUNTIME_SCHEMA_NOT_SUPPORTED_ERROR_MESSAGE = "Runtime schema generation is not yet supported";

final OpenAiModelProvider openAiProvider = check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION);

@test:Config
function testGenerateMethodWithBasicReturnType() returns ai:Error? {
    int|error rating = openAiProvider->generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);

    if rating is error {
        test:assertFail(rating.message());
    }
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateMethodWithBasicArrayReturnType() returns ai:Error? {
    int[]|error rating = openAiProvider->generate(`Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`);

    if rating is error {
        test:assertFail(rating.message());
    }
    test:assertEquals(rating, [9, 1]);
}

@test:Config
function testGenerateMethodWithRecordReturnType() returns error? {
    Review|error result = openAiProvider->generate(`Please rate this blog out of 10.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    if result is error {
        test:assertFail(result.message());
    }
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testGenerateMethodWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    int|error rating = openAiProvider->generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}.`);
    if rating is error {
        test:assertFail(rating.message());
    }
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateMethodWithTextDocument2() returns error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    Review|error result = openAiProvider->generate(`How would you rate this text blog out of ${maxScore}, ${blog}.`);
    if result is error {
        test:assertFail(result.message());
    }

    test:assertEquals(result, check review.fromJsonStringWithType(Review));
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

    ReviewArray|error result = openAiProvider->generate(`How would you rate this text blogs out of ${maxScore}. ${blogs}. Thank you!`);
    if result is error {
        test:assertFail(result.message());
    }
    test:assertEquals(result, [r, r]);
}

@test:Config
function testGenerateMethodWithRecordArrayReturnType() returns error? {
    int maxScore = 10;
    Review r = check review.fromJsonStringWithType(Review);

    ReviewArray|error result = openAiProvider->generate(`Please rate this blogs out of ${maxScore}.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`);

    if result is error {
        test:assertFail(result.message());
    }
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
    ProductName[]|error rating = trap openAiProvider->generate(
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
