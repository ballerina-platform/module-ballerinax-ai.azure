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

import ballerina/jballerina.java;

type JsonSchema record {|
    string 'type?;
    (JsonSchema|JsonArraySchema)[] oneOf?;
    map<JsonSchema|JsonArraySchema|map<json>> properties?;
    string[] required?;
|};

type JsonArraySchema record {|
    string 'type = "array";
    JsonSchema items;
|};

isolated function generateJsonSchemaForTypedescAsJson(typedesc<json> expectedResponseTypedesc) returns map<json> =>
    generateJsonSchemaForTypedescNative(expectedResponseTypedesc)
                ?: generateJsonSchemaForTypedesc(expectedResponseTypedesc, containsNil(expectedResponseTypedesc));

isolated function generateJsonSchemaForTypedesc(typedesc<json> expectedResponseTypedesc, boolean nilableType) returns JsonSchema|JsonArraySchema|map<json> {
    if isSimpleType(expectedResponseTypedesc) {
        return <JsonSchema>{
            'type: getStringRepresentation(<typedesc<json>>expectedResponseTypedesc)
        };
    }

    boolean isArray = expectedResponseTypedesc is typedesc<json[]>;

    typedesc<map<json>?> recTd;

    if isArray {
        typedesc<json> arrayMemberType = getArrayMemberType(<typedesc<json[]>>expectedResponseTypedesc);
        if isSimpleType(arrayMemberType) {
            return <JsonArraySchema>{
                items: !nilableType ? {
                        'type: getStringRepresentation(<typedesc<json>>arrayMemberType)
                    } :
                    {
                        oneOf: [
                            {
                                'type: getStringRepresentation(<typedesc<json>>arrayMemberType)
                            },
                            {
                                'type: "null"
                            }
                        ]
                    }
            };
        }
        recTd = <typedesc<map<json>?>>arrayMemberType;
    } else {
        recTd = <typedesc<map<json>?>>expectedResponseTypedesc;
    }

    string[] names = [];
    boolean[] required = [];
    typedesc<json>[] types = [];
    boolean[] nilable = [];
    populateFieldInfo(recTd, names, required, types, nilable);
    return generateJsonSchema(names, required, types, nilable, isArray, containsNil(recTd));
}

isolated function populateFieldInfo(typedesc<json> expectedResponseTypedesc, string[] names, boolean[] required,
        typedesc<json>[] types, boolean[] nilable) = @java:Method {
    name: "populateFieldInfo",
    'class: "io.ballerina.lib.ai.azure.Native"
} external;

isolated function getArrayMemberType(typedesc<json> expectedResponseTypedesc) returns typedesc<json> = @java:Method {
    name: "getArrayMemberType",
    'class: "io.ballerina.lib.ai.azure.Native"
} external;

isolated function containsNil(typedesc<json> expectedResponseTypedesc) returns boolean = @java:Method {
    name: "containsNil",
    'class: "io.ballerina.lib.ai.azure.Native"
} external;

isolated function generateJsonSchema(string[] names, boolean[] required,
        typedesc<json>[] types, boolean[] nilable, boolean isArray, boolean nilableType) returns JsonSchema|JsonArraySchema {
    map<JsonSchema|JsonArraySchema|map<json>> properties = {};
    string[] requiredSchema = [];

    JsonSchema schema = !nilableType ? {
            'type: "object",
            properties,
            required: requiredSchema
        } : {
            oneOf: [
                {
                    'type: "object",
                    properties,
                    required: requiredSchema
                },
                {
                    'type: "null"
                }
            ]
        };

    foreach int i in 0 ..< names.length() {
        string fieldName = names[i];
        JsonSchema|JsonArraySchema|map<json> fieldSchema = getJsonSchemaType(types[i], nilable[i]);
        properties[fieldName] = fieldSchema;
        if required[i] {
            requiredSchema.push(fieldName);
        }
    }

    if isArray {
        return !nilableType ? {
                items: schema,
                'type: "array"
            } : {
                oneOf: [
                    {
                        items: schema,
                        'type: "array"
                    },
                    {
                        'type: "null"
                    }
                ]
            };
    }

    return schema;
}

isolated function getJsonSchemaType(typedesc<json> fieldType, boolean nilable) returns JsonSchema|JsonArraySchema|map<json> {
    if isSimpleType(fieldType) {
        return !nilable ? <JsonSchema>{
                'type: getStringRepresentation(fieldType)
            } : <JsonSchema>{
                oneOf: [
                    {
                        'type: getStringRepresentation(fieldType)
                    },
                    {
                        'type: "null"
                    }
                ]
            };
    }

    return generateJsonSchemaForTypedesc(fieldType, nilable);
}

isolated function isSimpleType(typedesc<json> expectedResponseTypedesc) returns boolean =>
    expectedResponseTypedesc is typedesc<string|int|float|decimal|boolean|()>;

isolated function getStringRepresentation(typedesc<json> fieldType) returns string {
    if fieldType is typedesc<()> {
        return "null";
    }
    if fieldType is typedesc<string> {
        return "string";
    }
    if fieldType is typedesc<int> {
        return "integer";
    }
    if fieldType is typedesc<float|decimal> {
        return "number";
    }
    if fieldType is typedesc<boolean> {
        return "boolean";
    }

    panic error("JSON schema generation is not yet supported for type: " + fieldType.toString());
}

isolated function generateJsonSchemaForTypedescNative(typedesc<anydata> td) returns map<json>? = @java:Method {
    'class: "io.ballerina.lib.ai.azure.Native"
} external;
