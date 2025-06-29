/*
 * Copyright (c) 2025, WSO2 LLC. (http://wso2.com).
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.ballerina.lib.ai.azure;

import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.flags.SymbolFlags;
import io.ballerina.runtime.api.types.ArrayType;
import io.ballerina.runtime.api.types.Field;
import io.ballerina.runtime.api.types.JsonType;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.types.RecordType;
import io.ballerina.runtime.api.types.TupleType;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.types.TypeTags;
import io.ballerina.runtime.api.types.UnionType;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.api.values.BTypedesc;

import java.util.Map;

import static io.ballerina.runtime.api.creators.ValueCreator.createMapValue;

/**
 * Native implementation of Azure OpenAI functions.
 *
 * @since 1.0.0
 */
public class Native {
    public static Object generateJsonSchemaForTypedescNative(BTypedesc td) {
        SchemaGenerationContext schemaGenerationContext = new SchemaGenerationContext();
        Object schema = generateJsonSchemaForType(td.getDescribingType(), schemaGenerationContext);
        return schemaGenerationContext.isSchemaGeneratedAtCompileTime ? schema : null;
    }

    private static Object generateJsonSchemaForType(Type t, SchemaGenerationContext schemaGenerationContext) {
        Type impliedType = TypeUtils.getImpliedType(t);
        if (isSimpleType(impliedType)) {
            return createSimpleTypeSchema(impliedType);
        }

        return switch (impliedType) {
            case RecordType recordType -> generateJsonSchemaForRecordType(recordType, schemaGenerationContext);
            case JsonType ignored -> generateJsonSchemaForJson();
            case ArrayType arrayType -> generateJsonSchemaForArrayType(arrayType, schemaGenerationContext);
            case TupleType tupleType -> generateJsonSchemaForTupleType(tupleType, schemaGenerationContext);
            case UnionType unionType -> generateJsonSchemaForUnionType(unionType, schemaGenerationContext);
            default -> null;
        };
    }

    private static BMap<BString, Object> createSimpleTypeSchema(Type type) {
        BMap<BString, Object> schemaMap = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
        schemaMap.put(StringUtils.fromString("type"), StringUtils.fromString(getStringRepresentation(type)));
        return schemaMap;
    }

    private static BMap<BString, Object> generateJsonSchemaForJson() {
        BString[] bStringValues = new BString[6];
        bStringValues[0] = StringUtils.fromString("object");
        bStringValues[1] = StringUtils.fromString("array");
        bStringValues[2] = StringUtils.fromString("string");
        bStringValues[3] = StringUtils.fromString("number");
        bStringValues[4] = StringUtils.fromString("boolean");
        bStringValues[5] = StringUtils.fromString("null");
        BMap<BString, Object> schemaMap = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
        schemaMap.put(StringUtils.fromString("type"), ValueCreator.createArrayValue(bStringValues));
        return schemaMap;
    }

    private static Object generateJsonSchemaForArrayType(ArrayType arrayType,
                                                         SchemaGenerationContext schemaGenerationContext) {
        BMap<BString, Object> schemaMap = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
        Type elementType = TypeUtils.getImpliedType(arrayType.getElementType());
        schemaMap.put(StringUtils.fromString("type"), StringUtils.fromString("array"));
        schemaMap.put(StringUtils.fromString("items"), generateJsonSchemaForType(elementType,
                schemaGenerationContext));
        return schemaMap;
    }

    private static Object generateJsonSchemaForTupleType(TupleType tupleType,
                                                         SchemaGenerationContext schemaGenerationContext) {
        BMap<BString, Object> schemaMap = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
        schemaMap.put(StringUtils.fromString("type"), StringUtils.fromString("array"));
        BArray annotationArray = ValueCreator.createArrayValue(TypeCreator.createArrayType(PredefinedTypes.TYPE_JSON));
        int index = 0;
        for (Type type : tupleType.getTupleTypes()) {
            annotationArray.add(index++, generateJsonSchemaForType(type, schemaGenerationContext));
        }
        schemaMap.put(StringUtils.fromString("items"), annotationArray);
        return schemaMap;
    }

    private static boolean isSimpleType(Type type) {
        return type.getBasicType().all() <= 0b100000;
    }

    private static String getStringRepresentation(Type type) {
        return switch (type.getBasicType().all()) {
            case 0b000000 -> "null";
            case 0b000010 -> "boolean";
            case 0b000100 -> "integer";
            case 0b001000, 0b010000 -> "number";
            case 0b100000 -> "string";
            default -> null;
        };
    }

    private static Object generateJsonSchemaForRecordType(RecordType recordType,
                                                          SchemaGenerationContext schemaGenerationContext) {
        for (Map.Entry<BString, Object> entry : recordType.getAnnotations().entrySet()) {
            if ("ballerinax/ai.model.provider.azure:0:JsonSchema".equals(entry.getKey().getValue())) {
                return entry.getValue();
            }
        }
        schemaGenerationContext.isSchemaGeneratedAtCompileTime = false;
        return null;
    }

    private static Object generateJsonSchemaForUnionType(UnionType unionType,
                                                         SchemaGenerationContext schemaGenerationContext) {
        BMap<BString, Object> schemaMap = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
        BArray annotationArray = ValueCreator.createArrayValue(TypeCreator.createArrayType(PredefinedTypes.TYPE_JSON));

        int index = 0;
        boolean hasNil = false;
        for (Type type : unionType.getMemberTypes()) {
            if (type.getTag() == TypeTags.NULL_TAG) {
                hasNil = true;
                continue;
            }
            annotationArray.add(index++, generateJsonSchemaForType(type, schemaGenerationContext));
        }

        schemaMap.put(StringUtils.fromString("anyOf"), annotationArray);
        if (hasNil) {
            BMap<BString, Object> nilSchema = createMapValue(TypeCreator.createMapType(PredefinedTypes.TYPE_JSON));
            nilSchema.put(StringUtils.fromString("type"), StringUtils.fromString("null"));
            annotationArray.add(index, nilSchema);
        }
        return schemaMap;
    }

    // Simple, simple, SIMPLE implementation for now.
    public static void populateFieldInfo(BTypedesc typedesc, BArray names, BArray required,
                                         BArray types, BArray nilable) {
        Type impliedType = TypeUtils.getImpliedType(typedesc.getDescribingType());

        RecordType recordType;
        if (impliedType instanceof UnionType unionType) {
            for (Type memberType : unionType.getMemberTypes()) {
                memberType = TypeUtils.getImpliedType(memberType);
                if (memberType.getTag() != TypeTags.NULL_TAG) {
                    impliedType = memberType;
                    break;
                }
            }
        }
        recordType = (RecordType) impliedType;

        for (Field field : recordType.getFields().values()) {
            names.append(StringUtils.fromString(field.getFieldName()));
            long flags = field.getFlags();
            required.append(SymbolFlags.isFlagOn(flags, SymbolFlags.REQUIRED) ||
                    !SymbolFlags.isFlagOn(flags, SymbolFlags.OPTIONAL));
            Type fieldType = TypeUtils.getImpliedType(field.getFieldType());
            nilable.append(fieldType.isNilable());
            // Naive implementation - temporary
            if (fieldType instanceof UnionType unionType) {
                for (Type memberType : unionType.getMemberTypes()) {
                    memberType = TypeUtils.getImpliedType(memberType);
                    if (memberType.getTag() != TypeTags.NULL_TAG) {
                        fieldType = memberType;
                        break;
                    }
                }
            }
            types.append(ValueCreator.createTypedescValue(fieldType));
        }
    }

    public static BTypedesc getArrayMemberType(BTypedesc expectedResponseTypedesc) {
        return ValueCreator.createTypedescValue(
                ((ArrayType) TypeUtils.getImpliedType(expectedResponseTypedesc.getDescribingType())).getElementType());
    }

    public static boolean containsNil(BTypedesc expectedResponseTypedesc) {
        return expectedResponseTypedesc.getDescribingType().isNilable();
    }

    private static class SchemaGenerationContext {
        boolean isSchemaGeneratedAtCompileTime = true;
    }
}
