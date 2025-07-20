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
import ballerina/lang.array;

type Blog record {
    string title;
    string content;
};

type Review record {|
    int rating;
    string comment;
|};

const blog1 = {
    // Generated.
    title: "Tips for Growing a Beautiful Garden",
    content: string `Spring is the perfect time to start your garden. 
        Begin by preparing your soil with organic compost and ensure proper drainage. 
        Choose plants suitable for your climate zone, and remember to water them regularly. 
        Don't forget to mulch to retain moisture and prevent weeds.`
};

const blog2 = {
    // Generated.
    title: "Essential Tips for Sports Performance",
    content: string `Success in sports requires dedicated preparation and training.
        Begin by establishing a proper warm-up routine and maintaining good form.
        Choose the right equipment for your sport, and stay consistent with training.
        Don't forget to maintain proper hydration and nutrition for optimal performance.`
};

final byte[] imageBinaryData = [137, 80, 78, 71, 13, 10, 26, 10];
final string imageStr = array:toBase64(imageBinaryData);
const sampleImageUrl = "https://example.com/image.jpg";

const review = "{\"rating\": 8, \"comment\": \"Talks about essential aspects of sports performance " +
        "including warm-up, form, equipment, and nutrition.\"}";

final readonly & map<anydata>[] expectedContentPartsForRateBlog = [
    {
        "type": "text",
        "text": string `Rate this blog out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}`
    }
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog2 = [
    {
        "type": "text",
        "text": string `Please rate this blog out of 10.
        Title: ${blog2.title}
        Content: ${blog2.content}`
    }
];

const map<anydata>[] expectedContentPartsForRateBlog3 = [
    {"type": "text", "text": "What is 1 + 1?"}
];

const map<anydata>[] expectedContentPartsForRateBlog4 = [
    {"type": "text", "text": "Tell me name and the age of the top 10 world class cricketers"}
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog5 = [
    {"type": "text", "text": "How would you rate this blog content out of 10. "},
    {
        "type": "text",
        "text": "Title: Tips for Growing a Beautiful Garden Content: " +
        "Spring is the perfect time to start your garden. \n        Begin by preparing your soil " +
        "with organic compost and ensure proper drainage. \n        Choose plants suitable for your " +
        "climate zone, and remember to water them regularly. \n        Don't forget to mulch to retain " +
        "moisture and prevent weeds."
    },
    {"type": "text", "text": "."}
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog7 = [
    {
        "type": "text",
        "text": string `Please rate this blogs out of 10.
        [{Title: ${blog1.title}, Content: ${blog1.content}}, {Title: ${blog2.title}, Content: ${blog2.content}}]`
    }
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog8 = [
    {"type": "text", "text": "How would you rate this text blog out of 10, "},
    {
        "type": "text",
        "text": "Title: Tips for Growing a Beautiful Garden Content: " +
        "Spring is the perfect time to start your garden. \n        Begin by preparing your soil with " +
        "organic compost and ensure proper drainage. \n        Choose plants suitable for your climate zone, " +
        "and remember to water them regularly. \n        Don't forget to mulch to retain moisture and prevent weeds."
    },
    {"type": "text", "text": "."}
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog9 = [
    {"type": "text", "text": "How would you rate these text blogs out of 10. "},
    {
        "type": "text",
        "text": "Title: Tips for Growing a Beautiful Garden Content: " +
        "Spring is the perfect time to start your garden. \n        Begin by preparing your soil with " +
        "organic compost and ensure proper drainage. \n        Choose plants suitable for your climate zone, " +
        "and remember to water them regularly. \n        Don't forget to mulch to retain moisture and prevent weeds."
    },
    {
        "type": "text",
        "text": "Title: Tips for Growing a Beautiful Garden Content: " +
        "Spring is the perfect time to start your garden. \n        " +
        "Begin by preparing your soil with organic compost and ensure proper drainage. \n        " +
        "Choose plants suitable for your climate zone, and remember to water them regularly. \n        " +
        "Don't forget to mulch to retain moisture and prevent weeds."
    },
    {"type": "text", "text": ". Thank you!"}
];

final readonly & map<anydata>[] expectedContentPartsForRateBlog10 = [
    {
        "type": "text",
        "text": string `Evaluate this blogs out of 10.
        Title: ${blog1.title}
        Content: ${blog1.content}

        Title: ${blog1.title}
        Content: ${blog1.content}`
    }
];

final readonly & map<anydata>[] expectedContentPartsForCountry = [
    {"type": "text", "text": "Which country is known as the pearl of the Indian Ocean?"}
];

const expectedParameterSchemaStringForRateBlog =
    {"type": "object", "properties": {"result": {"type": "integer"}}};

const expectedParameterSchemaStringForRateBlog2 =
    {
    "type": "object",
    "required": ["comment", "rating"],
    "properties": {
        "rating": {"type": "integer", "format": "int64"},
        "comment": {"type": "string"}
    }
};

const expectedParameterSchemaStringForRateBlog3 =
    {"type": "object", "properties": {"result": {"type": "boolean"}}};

const expectedParameterSchemaStringForRateBlog4 =
    {
    "type": "object",
    "properties": {
        "result": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
                "required": ["name"]
            }
        }
    }
};

const expectedParameterSchemaStringForRateBlog5 =
    {
    "type": "object",
    "properties": {
        "result": {
            "type": "array",
            "items": {
                "required": ["comment", "rating"],
                "type": "object",
                "properties": {
                    "rating": {"type": "integer", "format": "int64"},
                    "comment": {"type": "string"}
                }
            }
        }
    }
};

const expectedParameterSchemaStringForRateBlog6 =
    {
    "type": "object",
    "properties": {
        "result": {
            "type": "array",
            "items": {
                "type": "integer"
            }
        }
    }
};

const expectedParameterSchemaStringForRateBlog7 =
    {
    "type": "object",
    "properties": {
        "result": {
            "type": "array",
            "items": {
                "type": "string"
            }
        }
    }
};

const expectedParameterSchemaStringForRateBlog8 =
    {"type": "object", "properties": {"result": {"type": "string"}}};

const expectedParamterSchemaStringForCountry =
    {"type": "object", "properties": {"result": {"type": "string"}}};
