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

// Unit tests for the JSON-schema generation and response-parsing helpers. The runtime schema-generation path
// (`generateJsonSchemaForTypedesc`) is normally only reached when the native fast path declines a type, so it is
// pinned directly here.

// Type aliases so array/nil type descriptors can be passed as arguments (a bare `int[]`/`()` in an argument
// position is parsed as an expression rather than a type descriptor).
type NilType ();
type IntArray int[];
type MapStr map<string>;
// A record used to build a type the native fast path declines (forcing the runtime resolver fallback).
type SchemaProduct record {|
    string name;
|};
type NativeDeclinedType SchemaProduct[]|map<string>;

// ===== generateJsonSchemaForTypedesc / getStringRepresentation (via simple types) =====

@test:Config
function testRuntimeSchemaForSimpleTypes() returns error? {
    // Each simple type exercises a distinct branch of getStringRepresentation.
    map<json> intSchema = check generateJsonSchemaForTypedesc(int, false).ensureType();
    test:assertEquals(intSchema["type"], "integer");

    map<json> stringSchema = check generateJsonSchemaForTypedesc(string, false).ensureType();
    test:assertEquals(stringSchema["type"], "string");

    map<json> boolSchema = check generateJsonSchemaForTypedesc(boolean, false).ensureType();
    test:assertEquals(boolSchema["type"], "boolean");

    map<json> floatSchema = check generateJsonSchemaForTypedesc(float, false).ensureType();
    test:assertEquals(floatSchema["type"], "number");

    map<json> decimalSchema = check generateJsonSchemaForTypedesc(decimal, false).ensureType();
    test:assertEquals(decimalSchema["type"], "number");

    map<json> nilSchema = check generateJsonSchemaForTypedesc(NilType, false).ensureType();
    test:assertEquals(nilSchema["type"], "null");
}

@test:Config
function testRuntimeSchemaForSimpleArrayNonNilable() returns error? {
    // Array of a simple type, non-nilable member -> plain array schema with a typed `items`.
    map<json> schema = check generateJsonSchemaForTypedesc(IntArray, false).ensureType();
    test:assertEquals(schema["type"], "array");
    map<json> items = check schema["items"].ensureType();
    test:assertEquals(items["type"], "integer");
}

@test:Config
function testRuntimeSchemaForSimpleArrayNilable() returns error? {
    // Array of a simple type, nilable member -> `items` uses a oneOf(type, null).
    map<json> schema = check generateJsonSchemaForTypedesc(IntArray, true).ensureType();
    map<json> items = check schema["items"].ensureType();
    test:assertTrue(items["oneOf"] is json[]);
}

@test:Config
function testRuntimeSchemaForUnsupportedTypeFails() {
    // A record type is not supported by the runtime generator.
    var result = generateJsonSchemaForTypedesc(Review, false);
    test:assertTrue(result is ai:Error);
    test:assertTrue((<ai:Error>result).message().includes("Runtime schema generation is not yet supported"));
}

@test:Config
function testGenerateJsonSchemaForTypedescAsJsonUsesNativeFastPath() returns error? {
    // With no annotation present, the resolver falls through to the native fast path.
    map<json> schema = check generateJsonSchemaForTypedescAsJson(int);
    test:assertTrue(schema.hasKey("type"));
}

@test:Config
function testGenerateJsonSchemaForTypedescAsJsonFallsBackToRuntime() {
    // A type the native fast path declines falls through to the runtime generator (which also declines
    // `map<string>`), exercising the third operand of the resolver (including the nilability probe).
    map<json>|ai:Error schema = generateJsonSchemaForTypedescAsJson(MapStr);
    test:assertTrue(schema is ai:Error, "map<string> is not supported by the runtime generator");
}

@test:Config
function testGenerateJsonSchemaForTypedescAsJsonNativeDeclinedType() {
    // An array-record/map union is declined by the native fast path, so the resolver evaluates the runtime
    // operand (calling the nilability probe) which reports the type as unsupported.
    map<json>|ai:Error schema = generateJsonSchemaForTypedescAsJson(NativeDeclinedType);
    test:assertTrue(schema is ai:Error);
}

@test:Config
function testContainsNil() {
    // The nilability probe used by the runtime resolver.
    test:assertTrue(containsNil(NilType), "the nil type contains nil");
    test:assertFalse(containsNil(int), "int does not contain nil");
}

// ===== generateJsonObjectSchema =====

@test:Config
function testGenerateJsonObjectSchemaAlreadyObject() {
    map<json> input = {"type": "object", "properties": {"a": {"type": "string"}}};
    ResponseSchema result = generateJsonObjectSchema(input);
    test:assertTrue(result.isOriginallyJsonObject);
    test:assertEquals(result.schema, input);
}

@test:Config
function testGenerateJsonObjectSchemaWrapsNonObject() {
    map<json> input = {"type": "integer", "title": "Rating"};
    ResponseSchema result = generateJsonObjectSchema(input);
    test:assertFalse(result.isOriginallyJsonObject);
    test:assertEquals(result.schema["type"], "object");
    // Metadata fields (title) are lifted to the top level; the rest becomes the `result` property.
    map<json> properties = <map<json>>result.schema["properties"];
    test:assertTrue(properties.hasKey("result"));
    test:assertEquals(result.schema["title"], "Rating");
}

// ===== parseResponseAsType =====

@test:Config
function testParseResponseAsTypeWrappedResult() returns error? {
    // isOriginallyJsonObject == false: the value lives under "result".
    anydata result = check parseResponseAsType("{\"result\": 4}", int, false);
    test:assertEquals(result, 4);
}

@test:Config
function testParseResponseAsTypeWrappedResultTypeMismatch() {
    anydata|error result = parseResponseAsType("{\"result\": \"not-int\"}", int, false);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes(ERROR_MESSAGE));
}

@test:Config
function testParseResponseAsTypeDirectObject() returns error? {
    // isOriginallyJsonObject == true: the whole payload binds to the type.
    Review result = check parseResponseAsType(review, Review, true).ensureType();
    test:assertEquals(result, reviewRecord);
}

@test:Config
function testParseResponseAsTypeDirectObjectTypeMismatch() {
    anydata|error result = parseResponseAsType("{\"rating\": \"x\", \"comment\": \"c\"}", Review, true);
    test:assertTrue(result is error);
    test:assertTrue((<error>result).message().includes(ERROR_MESSAGE));
}

// ===== handleParseResponseError =====

@test:Config
function testHandleParseResponseErrorNonConversionPassthrough() {
    error input = error("some unrelated failure");
    error result = handleParseResponseError(input);
    // A non-conversion error is returned unchanged (not rewrapped with the generic parse message).
    test:assertEquals(result.message(), "some unrelated failure");
}

// ===== getGetResultsTool / getGetResultsToolChoice =====

@test:Config
function testGetGetResultsTool() returns error? {
    var tools = check getGetResultsTool({"type": "object", "properties": {}});
    test:assertEquals(tools.length(), 1);
    test:assertEquals(tools[0].'function.name, GET_RESULTS_TOOL);
}

@test:Config
function testGetGetResultsToolChoice() {
    var choice = getGetResultsToolChoice();
    test:assertEquals(choice.'function.name, GET_RESULTS_TOOL);
}

// ===== getExpectedResponseSchema =====

@test:Config
function testGetExpectedResponseSchemaWrapsSimpleType() returns error? {
    ResponseSchema schema = check getExpectedResponseSchema(int);
    test:assertFalse(schema.isOriginallyJsonObject);
    test:assertEquals(schema.schema["type"], "object");
}
