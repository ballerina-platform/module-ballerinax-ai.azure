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

import ballerinax/azure.openai.chat;

const INVALID = "Invalid content";

isolated function getExpectedParameterSchema(string message) returns map<json> {
    if message.startsWith("Evaluate this") {
        return expectedParameterSchemaStringForRateBlog6;
    }

    if message.startsWith("Rate this blog") {
        return expectedParameterSchemaStringForRateBlog;
    }

    if message.startsWith("On a scale from 1 to 10") {
        return expectedParameterSchemaStringForRateBlog2;
    }

    if message.startsWith("What is the result of") {
        return {"type": "object", "properties": {"result": {"type": "integer"}}};
    }

    if message.startsWith("Please rate this blogs") {
        return expectedParameterSchemaStringForRateBlog5;
    }

    if message.startsWith("Please rate this blog") {
        return expectedParameterSchemaStringForRateBlog2;
    }

    if message.startsWith("What is") {
        return expectedParameterSchemaStringForRateBlog3;
    }

    if message.startsWith("Tell me") {
        return expectedParameterSchemaStringForRateBlog4;
    }

    if message.startsWith("How would you rate these text blogs") {
        return expectedParameterSchemaStringForRateBlog5;
    }

    if message.startsWith("How would you rate this text blog") {
        return expectedParameterSchemaStringForRateBlog2;
    }

    if message.startsWith("How would you rate this") {
        return expectedParameterSchemaStringForRateBlog;
    }

    if message.startsWith("Which country") {
        return expectedParamterSchemaStringForCountry;
    }

    if message.startsWith("Describe the following 2 images") {
        return expectedParameterSchemaStringForRateBlog7;
    }

    if message.startsWith("Please describe the following image and the doc") {
        return expectedParameterSchemaStringForRateBlog7;
    }

    if message.startsWith("Describe the following text document and image document") {
        return expectedParameterSchemaStringForRateBlog7;
    }

    if message.startsWith("What is the content in this document") {
        return expectedParameterSchemaStringForRateBlog7;
    }

    if message.startsWith("Describe the following image") {
        return expectedParameterSchemaStringForRateBlog8;
    }

    if message.startsWith("Describe the image") {
        return expectedParameterSchemaStringForRateBlog8;
    }

    if message.startsWith("Please describe the image") {
        return expectedParameterSchemaStringForRateBlog8;
    }

    if message.startsWith("Please describe the audio content. ") {
        return expectedParameterSchemaStringForRateBlog8;
    }

    if message.startsWith("Please describe the following audio contents.") {
        return expectedParameterSchemaStringForRateBlog7;
    }

    if message.startsWith("Who is a popular sportsperson") {
        return {
            "type": "object",
            "properties": {
                "result": {
                    "oneOf": [
                        {
                            "type": "object",
                            "required": ["firstName", "middleName", "lastName", "yearOfBirth", "sport"],
                            "properties": {
                                "firstName": {"type": "string"},
                                "middleName": {"oneOf": [{"type": "string"}, {"type": "null"}]},
                                "lastName": {"type": "string"},
                                "yearOfBirth": {"type": "integer"},
                                "sport": {"type": "string"}
                            }
                        },
                        {"type": "null"}
                    ]
                }
            }
        };
    }

    if message.startsWith("Give me a random joke about cricketers") {
        return expectedParameterSchemaForRecUnionBasicType;
    }

    if message.startsWith("Give me a random joke") {
        return {"type":"object","properties":{"result":{"anyOf":[{"type":"string"},{"type":"null"}]}}};
    }

    if message.startsWith("Name a random world class cricketer in India") {
        return expectedParameterSchemaForRecUnionNull;
    }

    if message.startsWith("Name 10 world class cricketers in India") {
        return expectedParameterSchemaForArrayOnly;
    }

    if message.startsWith("Name 10 world class cricketers as string") {
        return expectedParameterSchemaForArrayUnionBasicType;
    }

    if message.startsWith("Name top 10 world class cricketers") {
        return expectedParameterSchemaForArrayUnionRec;
    }

    if message.startsWith("Name a random world class cricketer") {
        return expectedParameterSchemaForArrayUnionRec;
    }

    if message.startsWith("Name 10 world class cricketers") {
        return expectedParamSchemaForArrayUnionNull;
    }

    return {};
}

isolated function getInitialMockLlmResult(string message) returns string|error {
    if message.startsWith("Evaluate this") {
        return string `{"result": [9, 1]}`;
    }

    if message.startsWith("Rate this blog") {
        return "{\"result\": 4}";
    }

    if message.startsWith("On a scale from 1 to 10") {
        return review;
    }

    if message.startsWith("What is the result of 1 + 4?") {
        return "{\"result\": 5}";
    }

    if message.startsWith("What is the result of 1 + 5?") {
        return "{\"result\": 6}";
    }

    if message.startsWith("What is the result of") {
        return "{\"result\": true}";
    }

    if message.startsWith("Please rate this blogs") {
        return string `{"result": [${review}, ${review}]}`;
    }

    if message.startsWith("Please rate this blog") {
        return review;
    }

    if message.startsWith("What is") {
        return "{\"result\": 2}";
    }

    if message.startsWith("Tell me") {
        return "{\"result\": [{\"name\": \"Virat Kohli\", \"age\": 33}, {\"name\": \"Kane Williamson\", \"age\": 30}]}";
    }

    if message.startsWith("Which country") {
        return "{\"result\": \"Sri Lanka\"}";
    }

    if message.startsWith("Who is a popular sportsperson") {
        return "{\"result\": {\"firstName\": \"Simone\", \"middleName\": null, " +
            "\"lastName\": \"Biles\", \"yearOfBirth\": 1997, \"sport\": \"Gymnastics\"}}";
    }

    if message.startsWith("How would you rate these text blogs") {
        return string `{"result": [${review}, ${review}]}`;
    }

    if message.startsWith("How would you rate this text blog") {
        return review;
    }

    if message.startsWith("How would you rate this") {
        return "{\"result\": 4}";
    }

    if message.startsWith("Describe the following 2 images") {
        return "{\"result\": [\"This is a sample image description.\", \"This is a sample image description.\"]}";
    }

    if message.startsWith("Please describe the following image and the doc") {
        return "{\"result\": [\"This is a sample image description.\", \"This is a sample doc description.\"]}";
    }

    if message.startsWith("Describe the following text document and image document") {
        return "{\"result\": [\"This is a sample image description.\", \"This is a sample doc description.\"]}";
    }

    if message.startsWith("What is the content in this document") {
        return "{\"result\": [\"This is a sample image description.\"]}";
    }

    if message.startsWith("Describe the following image") {
        return "{\"result\": \"This is a sample image description.\"}";
    }

    if message.startsWith("Describe the image") {
        return "{\"result\": \"This is a sample image description.\"}";
    }

    if message.startsWith("Please describe the image") {
        return "{\"result\": \"This is a sample image description.\"}";
    }

    if message.startsWith("Please describe the audio content. ") {
        return "{\"result\": \"This is a sample audio description.\"}";
    }

    if message.startsWith("Please describe the following audio contents.") {
        return "{\"result\": [\"This is a sample audio description.\", \"This is a sample audio description.\"]}";
    }

    if message.startsWith("Name a random world class cricketer in India") {
        return "{\"result\": {\"name\": \"Sanga\"}}";
    }

    if message.startsWith("Name a random world class cricketer") {
        return "{\"result\": {\"name\": \"Sanga\"}}";
    }

    if message.startsWith("Name 10 world class cricketers") {
        return "{\"result\": [{\"name\": \"Virat Kohli\"}, {\"name\": \"Joe Root\"}, {\"name\": \"Steve Smith\"}, {\"name\": \"Kane Williamson\"}, {\"name\": \"Babar Azam\"}, {\"name\": \"Ben Stokes\"}, {\"name\": \"Jasprit Bumrah\"}, {\"name\": \"Pat Cummins\"}, {\"name\": \"Shaheen Afridi\"}, {\"name\": \"Rashid Khan\"}]}";
    }

    if message.startsWith("Name top 10 world class cricketers") {
        return "{\"result\": [{\"name\": \"Virat Kohli\"}, {\"name\": \"Joe Root\"}, {\"name\": \"Steve Smith\"}, {\"name\": \"Kane Williamson\"}, {\"name\": \"Babar Azam\"}, {\"name\": \"Ben Stokes\"}, {\"name\": \"Jasprit Bumrah\"}, {\"name\": \"Pat Cummins\"}, {\"name\": \"Shaheen Afridi\"}, {\"name\": \"Rashid Khan\"}]}";
    }

    if message.startsWith("Give me a random joke") {
        return "{\"result\": \"This is a random joke\"}";
    }

    return error("Unexpected message for initial call");
}

isolated function getTestServiceResponse(string content, int retryCount = 0) returns chat:CreateChatCompletionResponse|error =>
    {
    id: "test-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            message: {
                tool_calls: [
                    {
                        id: "tool-call-id",
                        'type: "function",
                        'function: {
                            name: GET_RESULTS_TOOL,
                            arguments: retryCount == 0 ?
                                check getInitialMockLlmResult(content) : retryCount == 1 ? 
                                check getFirstRetryLlmResult(content) :
                                    check getSecondRetryLlmResult(content)
                        }
                    }
                ]
            }
        }
    ]
};

isolated function getFirstRetryLlmResult(string message) returns string|error {
    if message.startsWith("What is the result of 1 + 1?") {
        return "{\"result\": \"hi\"}";
    }

    if message.startsWith("What is the result of 1 + 2?") {
        return "{\"result\": null}";
    }

    if message.startsWith("What is the result of 1 + 3?") {
        return "{\"result\": 4}";
    }

    if message.startsWith("What is the result of 1 + 6?") {
        return "{\"result\": 7}";
    }

    return error("Unexpected message for first retry call");
}

isolated function getSecondRetryLlmResult(string message) returns string|error {
    if message.startsWith("What is the result of 1 + 1?") {
        return "{\"result\": 2}";
    }

    if message.startsWith("What is the result of 1 + 2?") {
        return "{\"result\": 3}";
    }

    return error("Unexpected message for second retry call");
}

isolated function generateConversionErrorMessage(string errorMessage) returns string =>
    string `The tool call with ID 'tool-call-id' for the function 'getResults' failed.
        Error: error("{ballerina/lang.value}ConversionError",message="${errorMessage}")
        You must correct the function arguments based on this error and respond with a valid tool call.`;

isolated function getExpectedContentPartsForFirstRetryCall(string message) returns string|error {
    if message.startsWith("What is the result of 1 + 1?")
        || message.startsWith("What is the result of 1 + 2?")
        || message.startsWith("What is the result of 1 + 3?")
        || message.startsWith("What is the result of 1 + 6?") {
        return generateConversionErrorMessage("'boolean' value cannot be converted to 'int'");
    }

    return error("Unexpected content parts for first retry call");
}

isolated function getExpectedContentPartsForSecondRetryCall(string message) returns string|error {
    if message.startsWith("What is the result of 1 + 1?") {
        return generateConversionErrorMessage("'string' value cannot be converted to 'int'");
    }

    if message.startsWith("What is the result of 1 + 2?") {
        return generateConversionErrorMessage("cannot convert '()' to type 'int'");
    }

    return error("Unexpected content parts for second retry call");
}

isolated function getExpectedContentParts(string message) returns (map<anydata>)[]|error {
    if message.startsWith("Rate this blog") {
        return expectedContentPartsForRateBlog;
    }

    if message.startsWith("Evaluate this") {
        return expectedContentPartsForRateBlog10;
    }

    if message.startsWith("Please rate this blogs") {
        return expectedContentPartsForRateBlog7;
    }

    if message.startsWith("Please rate this blog") {
        return expectedContentPartsForRateBlog2;
    }

    if message.startsWith("On a scale from 1 to 10") {
        return expectedContentPartsForRateBlog11;
    }

    if message.startsWith("What is the result of 1 + 1?") {
        return [{"type": "text", "text": "What is the result of 1 + 1?"}];
    }

    if message.startsWith("What is the result of 1 + 2?") {
        return [{"type": "text", "text": "What is the result of 1 + 2?"}];
    }

    if message.startsWith("What is the result of 1 + 3?") {
        return [{"type": "text", "text": "What is the result of 1 + 3?"}];
    }

    if message.startsWith("What is the result of 1 + 4?") {
        return [{"type": "text", "text": "What is the result of 1 + 4?"}];
    }

    if message.startsWith("What is the result of 1 + 5?") {
        return [{"type": "text", "text": "What is the result of 1 + 5?"}];
    }

    if message.startsWith("What is the result of 1 + 6?") {
        return [{"type": "text", "text": "What is the result of 1 + 6?"}];
    }

    if message.startsWith("What is") {
        return expectedContentPartsForRateBlog3;
    }

    if message.startsWith("Tell me") {
        return expectedContentPartsForRateBlog4;
    }

    if message.startsWith("How would you rate these text blogs") {
        return expectedContentPartsForRateBlog9;
    }

    if message.startsWith("How would you rate this text blog") {
        return expectedContentPartsForRateBlog8;
    }

    if message.startsWith("How would you rate this") {
        return expectedContentPartsForRateBlog5;
    }

    if message.startsWith("Which country") {
        return expectedContentPartsForCountry;
    }

    if message.startsWith("Who is a popular sportsperson") {
        return [
            {
                "type": "text",
                "text": string `Who is a popular sportsperson that was 
                    born in the decade starting from 1990 with Simone in 
                    their name?`
            }
        ];
    }

    if message.startsWith("Describe the following 2 images") {
        return [
            {"type": "text", "text": "Describe the following 2 images. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": string `data:image/png;base64,${sampleBinaryStr}`
                }
            },
            {
                "type": "image_url",
                "image_url": {
                    "url": sampleImageUrl
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Please describe the following image and the doc") {
        return [
            {"type": "text", "text": "Please describe the following image and the doc. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": string `data:image/png;base64,${sampleBinaryStr}`
                }
            },
            {
                "type": "text",
                "text": string `Title: ${blog1.title} Content: ${blog1.content}`
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Describe the following text document and image document") {
        return [
            {"type": "text", "text": "Describe the following text document and image document. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": string `data:image/png;base64,${sampleBinaryStr}`
                }
            },
            {
                "type": "text",
                "text": string `Title: ${blog1.title} Content: ${blog1.content}`
            }
        ];
    }

    if message.startsWith("Describe the following image") {
        return [
            {"type": "text", "text": "Describe the following image. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": string `data:image/*;base64,${sampleBinaryStr}`
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Describe the image") {
        return [
            {"type": "text", "text": "Describe the image. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": sampleImageUrl
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Please describe the image") {
        return [
            {"type": "text", "text": "Please describe the image. "},
            {
                "type": "image_url",
                "image_url": {
                    "url": "This-is-not-a-valid-url"
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Please describe the audio content. ") {
        return [
            {"type": "text", "text": "Please describe the audio content. "},
            {
                "type": "input_audio",
                "input_audio": {
                    "data": sampleBinaryStr,
                    "format": "mp3"
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Please describe the following audio contents.") {
        return [
            {"type": "text", "text": "Please describe the following audio contents. "},
            {
                "type": "input_audio",
                "input_audio": {
                    "data": sampleBinaryStr,
                    "format": "mp3"
                }
            },
            {
                "type": "input_audio",
                "input_audio": {
                    "data": sampleBinaryStr,
                    "format": "mp3"
                }
            },
            {"type": "text", "text": "."}
        ];
    }

    if message.startsWith("Name 10 world class cricketers in India") {
        return [{"type": "text", "text": "Name 10 world class cricketers in India"}];
    }

    if message.startsWith("Name 10 world class cricketers as string") {
        return [{"type": "text", "text": "Name 10 world class cricketers as string"}];
    }

    if message.startsWith("Name 10 world class cricketers") {
        return [{"type": "text", "text": "Name 10 world class cricketers"}];
    }

    if message.startsWith("Name top 10 world class cricketers") {
        return [{"type": "text", "text": "Name top 10 world class cricketers"}];
    }

    if message.startsWith("Name a random world class cricketer in India") {
        return [{"type": "text", "text": "Name a random world class cricketer in India"}];
    }

    if message.startsWith("Name a random world class cricketer") {
        return [{"type": "text", "text": "Name a random world class cricketer"}];
    }

    if message.startsWith("Give me a random joke about cricketers") {
        return [{"type": "text", "text": "Give me a random joke about cricketers"}];
    }

    if message.startsWith("Give me a random joke") {
        return [{"type": "text", "text": "Give me a random joke"}];
    }

    return error("Unexpected content parts for initial call");
}

isolated function updateRetryCountMap(string initialText, map<int> retryCountMap) returns int {
    if retryCountMap.hasKey(initialText) {
        int index = retryCountMap.get(initialText) + 1;
        retryCountMap[initialText] = index;
        return index;
    }

    retryCountMap[initialText] = 0;
    return 0;
}
