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

final OpenAiProvider openAiProvider = check new (SERVICE_URL, API_KEY, DEPLOYMENT_ID, API_VERSION);

@test:Config
function testGenerateFunctionWithBasicReturnType() returns ai:Error? {
    int rating = check openAiProvider.generate(`Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateFunctionWithRecordReturnType() returns error? {
    Review result = check openAiProvider.generate(`Please rate this blog out of 10.
        Title: ${blog2.title}
        Content: ${blog2.content}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testGenerateFunctionWithBasicReturnTypeWithTextDocument() returns ai:Error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    int rating = check openAiProvider.generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}`);
    test:assertEquals(rating, 4);
}

@test:Config
function testGenerateFunctionWithBasicReturnTypeWithImageDocument() returns ai:Error? {
    ai:ImageDocument blog = {
        content: "https://example.com/image.png"
    };
    int maxScore = 10;

    int|error rating = openAiProvider.generate(`How would you rate this ${"blog"} content out of ${maxScore}. ${blog}`);
    test:assertTrue(rating is error);
    test:assertTrue((<error>rating).message().includes("Only Text Documents are currently supported."));
}

@test:Config
function testGenerateFunctionWithRecordReturnTypeWithTextDocument() returns error? {
    ai:TextDocument blog = {
        content: string `Title: ${blog1.title} Content: ${blog1.content}`
    };
    int maxScore = 10;

    Review result = check openAiProvider.generate(`How would you rate this blog out of ${maxScore}. ${blog}`);
    test:assertEquals(result, check review.fromJsonStringWithType(Review));
}

@test:Config
function testGenerateFunctionWithRecordArrayReturnType() returns error? {
    int maxScore = 10;
    Review r = check review.fromJsonStringWithType(Review);

    Review[] result = check openAiProvider.generate(`Please rate this blogs out of ${maxScore}.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`);
    test:assertEquals(result, [r, r]);
}

@test:Config
function testGenerateFunctionWithBasicReturnTypeWithError() returns ai:Error? {
    boolean|error rating = openAiProvider.generate(`What is ${1} + ${1}?`);
    test:assertTrue(rating is error);
    test:assertTrue((<error>rating).message().includes(ERROR_MESSAGE));
}

type RecordForInvalidBinding record {|
    string name;
|};

@test:Config
function testGenerateFunctionWithRecordReturnTypeWithError() returns ai:Error? {
    RecordForInvalidBinding[]|error rating = openAiProvider.generate(
                `Tell me name and the age of the top 10 world class cricketers`);
    test:assertTrue(rating is error);
    test:assertTrue((<error>rating).message().includes(ERROR_MESSAGE));
}

@test:Config
function testGenerateFunctionAfterTextDescription() returns ai:Error? {
    int result = check openAiProvider.generate(`What's the output of the Ballerina code below?

    ${"```"}ballerina
    import ballerina/io;

    public function main() {
        int x = 10;
        int y = 20;
        io:println(x + y);
    }
    ${"```"}`);
    test:assertEquals(result, 30);
}

@test:Config
function testGenerateFunctionWithoutJsonAfterBackticks() returns ai:Error? {
    string result = check openAiProvider.generate(`Which country is known as the pearl of the Indian Ocean?`);
    test:assertEquals(result, "Sri Lanka");
}

# Represents a person who plays a sport.
type SportsPerson record {|
    # First name of the person
    string firstName;
    # Middle name of the person
    string? middleName;
    # Last name of the person
    string lastName;
    # Year the person was born
    int yearOfBirth;
    # Sport that the person plays
    string sport;
|};

type SportsPersonOptional SportsPerson?;

@test:Config
function testGenerateFunctionWithSchemaGeneratedForComplexTypeAtRuntime() returns ai:Error? {
    typedesc<json> td = SportsPersonOptional;
    int decadeStart = 1990;
    string nameSegment = "Simone";
    json result = check openAiProvider.generate(`Who is a popular sportsperson that was 
        born in the decade starting from ${decadeStart} with ${nameSegment} in 
        their name?`, td = td);
    test:assertEquals(result, <SportsPerson>{
                firstName: "Simone",
                lastName: "Biles",
                middleName: (),
                sport: "Gymnastics",
                yearOfBirth: 1997
            });
}
