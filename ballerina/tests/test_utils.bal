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

import ballerina/http;

isolated function getExpectedParameterSchema(string message) returns map<json> {
    if message.startsWith("Evaluate this") {
        return expectedParameterSchemaStringForRateBlog6;
    }

    if message.startsWith("Rate this blog") {
        return expectedParameterSchemaStringForRateBlog;
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

    if message.startsWith("How would you rate these text chunks") {
        return expectedParameterSchemaStringForRateBlog5;
    }

    if message.startsWith("How would you rate this text chunk") {
        return expectedParameterSchemaStringForRateBlog;
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
        return {"type": "object", "properties": {"result": {"anyOf": [{"type": "string"}, {"type": "null"}]}}};
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

isolated function getTheMockLLMResult(string message) returns string {
    if message.startsWith("Evaluate this") {
        return string `{"result": [9, 1]}`;
    }

    if message.startsWith("Rate this blog") {
        return "{\"result\": 4}";
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

    if message.startsWith("How would you rate these text chunks") {
        return string `{"result": [${review}, ${review}]}`;
    }

    if message.startsWith("How would you rate this text chunk") {
        return {result: 4}.toJsonString();
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

    return "INVALID";
}

// Canned `chat.completion.chunk` SSE payload sequence for the streaming tests, modeled on a
// reasoning ("thinking") model deployment: a role delta, two reasoning-content fragments, two
// content fragments, a finish-reason chunk, and a final usage-only chunk. The `[DONE]` sentinel
// terminates the stream, matching Azure's real wire format.
const STREAMING_REASONING_TEXT = "Let me think about this.";
const STREAMING_CONTENT_TEXT = "Hello world";

isolated function getStreamingChunkEvents() returns http:SseEvent[] {
    json[] chunks = [
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {role: "assistant"}}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {reasoning_content: "Let me think"}}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {reasoning_content: " about this."}}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {content: "Hello"}}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {content: " world"}}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [{index: 0, delta: {}, finish_reason: "stop"}]},
        {id: "chunk-1", 'object: "chat.completion.chunk", created: 1700000000, model: "gpt-4o",
            choices: [], usage: {prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}}
    ];
    http:SseEvent[] events = from json chunkPayload in chunks select {data: chunkPayload.toJsonString()};
    events.push({data: "[DONE]"});
    return events;
}

// A `chat.completion.chunk` sequence whose second event is not valid JSON. A malformed chunk must fail the
// stream rather than being skipped: silently dropping it would truncate the answer with no error.
isolated function getMalformedStreamingChunkEvents() returns http:SseEvent[] => [
    {
        data: {id: "chunk-1", 'object: "chat.completion.chunk", model: "gpt-4o",
                choices: [{index: 0, delta: {content: "Hello"}}]}.toJsonString()
    },
    {data: "{\"choices\": [ this is not json"},
    {data: "[DONE]"}
];

// A `chat.completion.chunk` tool-call sequence in Azure's real streamed shape: the first fragment carries the
// call id, type and function name, and the fragments that follow carry only argument text - with `id`/`type`
// sent as explicit JSON `null` rather than omitted, which is the shape the module's nilable wire mirrors exist
// to tolerate.
const STREAMING_TOOL_CALL_ID = "call_stream_1";
const STREAMING_TOOL_ARGUMENTS = "{\"city\":\"Paris\"}";

isolated function getStreamingToolCallEvents() returns http:SseEvent[] {
    json[] chunks = [
        {id: "chunk-1", model: "gpt-4o", choices: [{index: 0, delta: {role: "assistant"}}]},
        {
            id: "chunk-1",
            model: "gpt-4o",
            choices: [
                {
                    index: 0,
                    delta: {
                        content: (),
                        tool_calls: [
                            {
                                index: 0,
                                id: STREAMING_TOOL_CALL_ID,
                                'type: "function",
                                'function: {name: PARALLEL_TOOL_NAME, arguments: ""}
                            }
                        ]
                    }
                }
            ]
        },
        {
            id: "chunk-1",
            model: "gpt-4o",
            choices: [
                {
                    index: 0,
                    delta: {
                        content: (),
                        tool_calls: [
                            {index: 0, id: (), 'type: (), 'function: {name: (), arguments: "{\"city\":"}}
                        ]
                    }
                }
            ]
        },
        {
            id: "chunk-1",
            model: "gpt-4o",
            choices: [
                {
                    index: 0,
                    delta: {
                        content: (),
                        tool_calls: [
                            {index: 0, id: (), 'type: (), 'function: {name: (), arguments: "\"Paris\"}"}}
                        ]
                    }
                }
            ]
        },
        {id: "chunk-1", model: "gpt-4o", choices: [{index: 0, delta: {}, finish_reason: "tool_calls"}]}
    ];
    http:SseEvent[] events = from json chunkPayload in chunks select {data: chunkPayload.toJsonString()};
    events.push({data: "[DONE]"});
    return events;
}

// ===== Responses API streaming fixtures =====
//
// The Responses API streams `type`-discriminated lifecycle events rather than repeated deltas of one envelope,
// so each scenario below is a full event sequence. Deployment ids select the scenario (see the mock routes in
// `test_services.bal`), which lets one test per scenario drive the real provider code path end to end.

const RESPONSES_STREAM_DEPLOYMENT = "responses-streaming";
const RESPONSES_STREAM_TOOLS_DEPLOYMENT = "responses-streaming-tools";
const RESPONSES_STREAM_FAILED_DEPLOYMENT = "responses-streaming-failed";
const RESPONSES_STREAM_INCOMPLETE_DEPLOYMENT = "responses-streaming-incomplete";
const RESPONSES_STREAM_ERROR_DEPLOYMENT = "responses-streaming-error";

const RESPONSES_STREAM_ID = "resp_stream_1";
const RESPONSES_STREAM_FAILURE_MESSAGE = "The request was blocked by the content filter.";
const RESPONSES_STREAM_ERROR_MESSAGE = "Rate limit exceeded while streaming.";

// Text + reasoning: a `response.created` carrying the id, reasoning-summary fragments, answer-text fragments,
// and a `response.completed` envelope with usage. `input_tokens_details`/`output_tokens_details` are deliberately
// omitted - Azure does not always send them, and a well-formed stream must not fail on their absence.
isolated function getResponsesStreamEvents() returns http:SseEvent[] => toSseEvents([
    {'type: "response.created", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {'type: "response.in_progress", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {'type: "response.reasoning_summary_text.delta", item_id: "rs_1", delta: "Let me think"},
    {'type: "response.reasoning_summary_text.delta", item_id: "rs_1", delta: " about this."},
    {'type: "response.output_item.added", output_index: 0, item: {'type: "message", id: "msg_1"}},
    {'type: "response.output_text.delta", item_id: "msg_1", delta: "Hello"},
    {'type: "response.output_text.delta", item_id: "msg_1", delta: " world"},
    {'type: "response.output_text.done", item_id: "msg_1", text: STREAMING_CONTENT_TEXT},
    {
        'type: "response.completed",
        response: {
            id: RESPONSES_STREAM_ID,
            status: "completed",
            'error: (),
            incomplete_details: (),
            output: [{'type: "message", id: "msg_1"}],
            usage: {input_tokens: 5, output_tokens: 3, total_tokens: 8}
        }
    }
]);

// A streamed function call: the `output_item.added` opens the slot (call id + name) and the argument fragments
// follow, keyed back to it by `item_id`.
isolated function getResponsesStreamToolCallEvents() returns http:SseEvent[] => toSseEvents([
    {'type: "response.created", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {
        'type: "response.output_item.added",
        output_index: 0,
        item: {
            'type: "function_call",
            id: "fc_1",
            call_id: STREAMING_TOOL_CALL_ID,
            name: PARALLEL_TOOL_NAME,
            arguments: ""
        }
    },
    {'type: "response.function_call_arguments.delta", item_id: "fc_1", delta: "{\"city\":"},
    {'type: "response.function_call_arguments.delta", item_id: "fc_1", delta: "\"Paris\"}"},
    {'type: "response.function_call_arguments.done", item_id: "fc_1", arguments: STREAMING_TOOL_ARGUMENTS},
    {
        'type: "response.completed",
        response: {
            id: RESPONSES_STREAM_ID,
            status: "completed",
            'error: (),
            incomplete_details: (),
            output: [{'type: "function_call", id: "fc_1", call_id: STREAMING_TOOL_CALL_ID}],
            usage: {input_tokens: 7, output_tokens: 5, total_tokens: 12}
        }
    }
]);

// A `response.failed` whose error code is outside the connector's closed `OpenAIResponseErrorCode` union. Azure's
// own message must still reach the caller.
isolated function getResponsesStreamFailedEvents() returns http:SseEvent[] => toSseEvents([
    {'type: "response.created", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {'type: "response.output_text.delta", item_id: "msg_1", delta: "Hel"},
    {
        'type: "response.failed",
        response: {
            id: RESPONSES_STREAM_ID,
            status: "failed",
            incomplete_details: (),
            'error: {code: "content_filter", message: RESPONSES_STREAM_FAILURE_MESSAGE}
        }
    }
]);

// A `response.incomplete` caused by the output-token cap. This is an ordinary early stop, not a failure: the
// partial text already streamed must survive and the terminal chunk must report `LENGTH`.
isolated function getResponsesStreamIncompleteEvents() returns http:SseEvent[] => toSseEvents([
    {'type: "response.created", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {'type: "response.output_text.delta", item_id: "msg_1", delta: "Hello"},
    {'type: "response.output_text.delta", item_id: "msg_1", delta: " world"},
    {
        'type: "response.incomplete",
        response: {
            id: RESPONSES_STREAM_ID,
            status: "incomplete",
            'error: (),
            incomplete_details: {reason: "max_output_tokens"},
            output: [{'type: "message", id: "msg_1"}],
            usage: {input_tokens: 5, output_tokens: 3, total_tokens: 8}
        }
    }
]);

// A top-level stream `error` event, distinct from a `response.failed` terminal envelope.
isolated function getResponsesStreamErrorEvents() returns http:SseEvent[] => toSseEvents([
    {'type: "response.created", response: {id: RESPONSES_STREAM_ID, status: "in_progress"}},
    {'type: "error", code: "rate_limit_exceeded", message: RESPONSES_STREAM_ERROR_MESSAGE}
]);

isolated function toSseEvents(json[] payloads) returns http:SseEvent[] =>
    from json payload in payloads
    select {data: payload.toJsonString()};

isolated function getTestServiceResponse(string content) returns json =>
    {
    id: "test-id",
    'object: "chat.completion",
    created: 1234567890,
    model: "gpt-4o",
    choices: [
        {
            finish_reason: "tool_calls",
            index: 0,
            // Azure returns `logprobs: null` (present, null) when logprobs are not requested.
            logprobs: (),
            message: {
                role: "assistant",
                content: (),
                tool_calls: [
                    {
                        id: "tool-call-id",
                        'type: "function",
                        'function: {
                            name: GET_RESULTS_TOOL,
                            arguments: getTheMockLLMResult(content)
                        }
                    }
                ]
            }
        }
    ],
    usage: {
        prompt_tokens: 25,
        completion_tokens: 12,
        total_tokens: 37
    }
};

isolated function getExpectedContentParts(string message) returns (map<anydata>)[] {
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

    if message.startsWith("How would you rate these text chunks") {
        return expectedContentPartsForTextChunkArray;
    }

    if message.startsWith("How would you rate this text chunk") {
        return expectedContentPartsForTextChunk;
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

    return [
        {
            "type": "text",
            "text": "INVALID"
        }
    ];
}
