/*
 * Copyright (c) 2026, WSO2 LLC. (http://wso2.com).
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

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.Runtime;
import io.ballerina.runtime.api.concurrent.StrandMetadata;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.ObjectType;
import io.ballerina.runtime.api.types.Parameter;
import io.ballerina.runtime.api.types.RecordType;
import io.ballerina.runtime.api.types.ResourceMethodType;
import io.ballerina.runtime.api.types.ServiceType;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.observability.ObservabilityConstants;
import io.ballerina.runtime.observability.ObserveUtils;
import io.ballerina.runtime.observability.ObserverContext;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;

/**
 * Finds a resource of the user's {@code azure:FoundryInvocationService} and calls it reflectively on behalf of the
 * internal Foundry dispatcher.
 *
 * <p>A resource is found by its accessor and path shape, where a path parameter segment is {@code ^}, as
 * {@link ResourceMethodType#getResourcePath()} reports it: {@code post [invocations]},
 * {@code get [invocations, ^]} and {@code post [invocations, ^, cancel]}. Path parameters come first in the
 * resource's parameter list; every other parameter must be either the {@code @http:Payload} parameter or the
 * {@code azure:FoundryContext} parameter, each at most once and in any order.
 *
 * <p>The observability handling is the one {@code ballerina/ai} uses for its chat dispatcher, so traces name the
 * user's service, not the internal dispatcher, as the entrypoint.
 *
 * @since 1.6.0
 */
public final class NativeFoundryResourceInvoker {

    static final String PATH_PARAM_SEGMENT = "^";
    static final String REST_PATH_PARAM_SEGMENT = "^^";
    // The annotations of a resource parameter are stored on the resource under this prefix plus the parameter name.
    private static final String PARAM_ANNOTATION_PREFIX = "$param$.";
    // An http annotation key is `ballerina/http:<major version>:<annotation name>`.
    private static final String HTTP_ANNOTATION_PREFIX = "ballerina/http:";
    private static final String PAYLOAD_ANNOTATION_SUFFIX = ":Payload";
    private static final String FOUNDRY_CONTEXT_TYPE = "FoundryContext";
    private static final String RESOURCE_SIGNATURE_TYPE = "FoundryResourceSignature";
    private static final String PAYLOAD_TYPE_FIELD = "payloadType";
    private static final String HTTP_HEADERS_TYPE = "Headers";
    private static final BString HTTP_HEADERS_REQUEST_FIELD = StringUtils.fromString("request");
    private static final String ENTRYPOINT_FUNCTION_MODULE_TAG = "entrypoint.function.module";
    private static final String ENTRYPOINT_SERVICE_NAME_TAG = "entrypoint.service.name";
    private static final String ENTRYPOINT_FUNCTION_NAME_TAG = "entrypoint.function.name";
    private static final String ENTRYPOINT_RESOURCE_ACCESSOR_TAG = "entrypoint.resource.accessor";

    private NativeFoundryResourceInvoker() {
    }

    /**
     * Describes the user's resource with the given accessor and path shape.
     *
     * @param env        the Ballerina environment
     * @param dispatcher the internal dispatcher service
     * @param accessor   the resource accessor, for example {@code post}
     * @param path       the path shape, with {@code ^} for a path parameter segment
     * @return a {@code FoundryResourceSignature}; {@code null} (Ballerina nil) when the service declares no such
     *         resource; or an error when the resource declares a parameter the dispatcher can't supply
     */
    public static Object getFoundryResourceSignature(Environment env, BObject dispatcher, BString accessor,
                                                     BArray path) {
        try {
            BObject userService = userService(dispatcher);
            ResourceMethodType resource = findResource(userService, accessor.getValue(), path.getStringArray());
            if (resource == null) {
                return null;
            }
            ResourceParams params = ResourceParams.of(resource, env.getCurrentModule());
            Map<String, Object> fields = new HashMap<>();
            fields.put(PAYLOAD_TYPE_FIELD, params.payloadIndex < 0 ? null
                    : ValueCreator.createTypedescValue(params.payloadType));
            return ValueCreator.createRecordValue(env.getCurrentModule(), RESOURCE_SIGNATURE_TYPE, fields);
        } catch (BError error) {
            return error;
        }
    }

    /**
     * Calls the user's resource with the given accessor and path shape.
     *
     * <p>A panic in the resource is returned as an error, so the request still gets a response. A resource that is
     * not isolated, or belongs to a service that is not isolated, runs under the runtime's global lock, as it would
     * on an {@code http:Listener}.
     *
     * @param env        the Ballerina environment
     * @param dispatcher the internal dispatcher service
     * @param accessor   the resource accessor, for example {@code post}
     * @param path       the path shape, with {@code ^} for a path parameter segment
     * @param pathArgs   the values of the path parameters, in order
     * @param payload    the payload, already converted to the declared payload type; ignored when the resource
     *                   declares no payload parameter
     * @param context    the {@code azure:FoundryContext} of the request
     * @return the resource's return value, or an error when the resource can't be called or panics
     */
    public static Object invokeFoundryResource(Environment env, BObject dispatcher, BString accessor, BArray path,
                                               BArray pathArgs, Object payload, BMap<BString, Object> context) {
        Object[] args;
        BObject userService;
        ResourceMethodType resource;
        try {
            userService = userService(dispatcher);
            resource = findResource(userService, accessor.getValue(), path.getStringArray());
            if (resource == null) {
                return ErrorCreator.createError(StringUtils.fromString("the FoundryInvocationService declares no '"
                        + describe(accessor.getValue(), path.getStringArray()) + "' resource"));
            }
            args = ResourceParams.of(resource, env.getCurrentModule()).arguments(pathArgs, payload, context);
        } catch (BError error) {
            return error;
        }
        String methodName = resource.getName();
        ObserverContext dispatcherContext = ObserveUtils.isObservabilityEnabled()
                ? ObserveUtils.getObserverContextOfCurrentFrame(env) : null;
        ObserverContext userContext = dispatcherContext == null ? null : newUserContext(env, dispatcherContext);
        ObjectType serviceType = (ObjectType) TypeUtils.getImpliedType(userService.getOriginalType());
        boolean concurrentSafe = serviceType.isIsolated() && resource.isIsolated();
        try {
            return env.yieldAndRun(() -> concurrentSafe
                    ? callOnCurrentStrand(env.getRuntime(), userService, methodName, args)
                    : callOnNonIsolatedStrand(env.getRuntime(), userService, methodName, args, userContext));
        } finally {
            if (userContext != null) {
                restoreDispatcherContext(env, dispatcherContext, userContext);
            }
        }
    }

    // An isolated resource of an isolated service needs no lock, so it runs on the dispatcher's own strand, which
    // http created as concurrent-safe because the dispatcher is isolated. The user context, if any, is already on
    // that strand.
    private static Object callOnCurrentStrand(Runtime runtime, BObject userService, String methodName,
                                              Object[] args) {
        try {
            // A returned error comes back here as the result, with its type and detail intact.
            return runtime.callMethod(userService, methodName, null, args);
        } catch (BError error) {
            // A panic in the user's resource. Returning it as an error lets the dispatcher answer the request; a
            // panic that escaped the dispatcher would leave the request without a response.
            return error;
        }
    }

    // Any other resource must hold the runtime's global lock while it runs, as it does on an http:Listener: http
    // calls such a resource from a new virtual thread with a strand that is not concurrent-safe. The dispatcher's
    // strand can't be reused for that, because it is concurrent-safe and so never takes the lock, and the runtime
    // reuses the current thread's strand whatever metadata it is given. So the resource is called from a new
    // virtual thread, which has no strand yet: the runtime creates a non-concurrent-safe strand there, which holds
    // the global lock while it runs and releases it while it waits. The user context travels in the strand's
    // properties, as http passes its observer context. The dispatcher's thread waits for the result; it is inside
    // yieldAndRun, so its own strand is not running meanwhile.
    private static Object callOnNonIsolatedStrand(Runtime runtime, BObject userService, String methodName,
                                                  Object[] args, ObserverContext userContext) {
        Map<String, Object> properties = new HashMap<>();
        if (userContext != null) {
            properties.put(ObservabilityConstants.KEY_OBSERVER_CONTEXT, userContext);
        }
        StrandMetadata metadata = new StrandMetadata(false, properties);
        CompletableFuture<Object> result = new CompletableFuture<>();
        Thread.startVirtualThread(() -> {
            try {
                result.complete(runtime.callMethod(userService, methodName, metadata, args));
            } catch (BError error) {
                // A panic in the user's resource; see callOnCurrentStrand.
                result.complete(error);
            } catch (Throwable throwable) {
                // Nothing would report a failure on this thread, so it is returned as an error too.
                result.complete(ErrorCreator.createError(throwable));
            }
        });
        try {
            return result.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return ErrorCreator.createError(StringUtils.fromString(
                    "interrupted while waiting for the FoundryInvocationService resource"));
        } catch (ExecutionException e) {
            // Not reached: the future is only ever completed normally.
            return ErrorCreator.createError(e.getCause());
        }
    }

    /**
     * Creates the {@code http:Headers} object of a request, as the http module does for an {@code http:Headers}
     * resource parameter.
     *
     * @param request the {@code http:Request}
     * @return the {@code http:Headers} object backed by the request
     */
    public static BObject createFoundryHeaders(BObject request) {
        Module httpModule = TypeUtils.getType(request).getPackage();
        BObject headers = ValueCreator.createObjectValue(httpModule, HTTP_HEADERS_TYPE);
        headers.set(HTTP_HEADERS_REQUEST_FIELD, request);
        return headers;
    }

    /**
     * Names the type of an error without reading its message or detail, which may quote a request body.
     *
     * @param error the error
     * @return the name of the error's type, for example {@code ConversionError}
     */
    public static BString errorTypeName(BError error) {
        return StringUtils.fromString(TypeUtils.getType(error).getName());
    }

    private static BObject userService(BObject dispatcher) {
        Object userService = NativeFoundryServiceAdaptor.getFoundryService(dispatcher);
        if (userService instanceof BObject service) {
            return service;
        }
        throw ErrorCreator.createError(StringUtils.fromString(
                "no FoundryInvocationService is attached to the Foundry dispatcher"));
    }

    static ResourceMethodType findResource(BObject userService, String accessor, String[] path) {
        ServiceType serviceType = (ServiceType) TypeUtils.getReferredType(TypeUtils.getType(userService));
        for (ResourceMethodType method : serviceType.getResourceMethods()) {
            if (accessor.equalsIgnoreCase(method.getAccessor()) && Arrays.equals(path, method.getResourcePath())) {
                return method;
            }
        }
        return null;
    }

    static String describe(String accessor, String[] path) {
        StringBuilder description = new StringBuilder(accessor.toLowerCase(Locale.ROOT));
        String separator = " ";
        for (String segment : path) {
            description.append(separator).append(PATH_PARAM_SEGMENT.equals(segment) ? "[string]" : segment);
            separator = "/";
        }
        return description.toString();
    }

    // The roles of a resource's parameters, worked out from the declared parameters in order.
    private static final class ResourceParams {
        private final int parameterCount;
        private final int pathParamCount;
        private int payloadIndex = -1;
        private Type payloadType;
        private int contextIndex = -1;

        private ResourceParams(int parameterCount, int pathParamCount) {
            this.parameterCount = parameterCount;
            this.pathParamCount = pathParamCount;
        }

        static ResourceParams of(ResourceMethodType resource, Module foundryModule) {
            String resourceName = describe(resource.getAccessor(), resource.getResourcePath());
            int pathParamCount = 0;
            for (String segment : resource.getResourcePath()) {
                if (PATH_PARAM_SEGMENT.equals(segment) || REST_PATH_PARAM_SEGMENT.equals(segment)) {
                    pathParamCount++;
                }
            }
            Parameter[] parameters = resource.getParameters();
            ResourceParams params = new ResourceParams(parameters.length, pathParamCount);
            for (int i = pathParamCount; i < parameters.length; i++) {
                Parameter parameter = parameters[i];
                if (hasPayloadAnnotation(resource, parameter.name)) {
                    if (params.payloadIndex >= 0) {
                        throw unsupported(resourceName, "it declares more than one '@http:Payload' parameter");
                    }
                    if (!parameter.type.isAnydata()) {
                        throw unsupported(resourceName, "the type of its '@http:Payload' parameter '" + parameter.name
                                + "' is not a subtype of 'anydata'");
                    }
                    params.payloadIndex = i;
                    params.payloadType = parameter.type;
                } else if (isFoundryContext(parameter.type, foundryModule)) {
                    if (params.contextIndex >= 0) {
                        throw unsupported(resourceName, "it declares more than one 'azure:FoundryContext' parameter");
                    }
                    params.contextIndex = i;
                } else {
                    throw unsupported(resourceName, "its parameter '" + parameter.name + "' is neither the "
                            + "'@http:Payload' parameter nor an 'azure:FoundryContext' parameter");
                }
            }
            return params;
        }

        Object[] arguments(BArray pathArgs, Object payload, BMap<BString, Object> context) {
            if (pathArgs.size() != pathParamCount) {
                throw ErrorCreator.createError(StringUtils.fromString("expected " + pathParamCount
                        + " path argument(s), got " + pathArgs.size()));
            }
            Object[] args = new Object[parameterCount];
            for (int i = 0; i < pathParamCount; i++) {
                args[i] = pathArgs.get(i);
            }
            if (payloadIndex >= 0) {
                args[payloadIndex] = payload;
            }
            if (contextIndex >= 0) {
                args[contextIndex] = context;
            }
            return args;
        }

        private static boolean hasPayloadAnnotation(ResourceMethodType resource, String paramName) {
            Object annotations = resource.getAnnotation(StringUtils.fromString(PARAM_ANNOTATION_PREFIX + paramName));
            if (!(annotations instanceof BMap<?, ?> annotationMap)) {
                return false;
            }
            for (Object key : annotationMap.getKeys()) {
                String name = key.toString();
                if (name.startsWith(HTTP_ANNOTATION_PREFIX) && name.endsWith(PAYLOAD_ANNOTATION_SUFFIX)) {
                    return true;
                }
            }
            return false;
        }

        private static boolean isFoundryContext(Type type, Module foundryModule) {
            Type referred = TypeUtils.getReferredType(type);
            if (!(referred instanceof RecordType recordType) || !FOUNDRY_CONTEXT_TYPE.equals(recordType.getName())) {
                return false;
            }
            Module module = recordType.getPackage();
            return module != null && foundryModule.getOrg().equals(module.getOrg())
                    && foundryModule.getName().equals(module.getName());
        }

        private static BError unsupported(String resourceName, String reason) {
            return ErrorCreator.createError(StringUtils.fromString("the '" + resourceName
                    + "' resource of the FoundryInvocationService is not supported: " + reason));
        }
    }

    // A trace's entrypoint (service, module, function and accessor) is taken from its first resource, and every
    // span beneath it inherits that. Here that is the dispatcher, an internal service of this module, so the trace
    // would name it instead of the user's service. To keep the user's service the entrypoint, its resource is given
    // a fresh context that is not yet started: the runtime then fills the entrypoint from that resource, while the
    // parent link keeps its span under the dispatcher's span. The context is seeded from the dispatcher's, so spans
    // started under it still find a parent span if the resource is ever not observed.
    // Copied from ballerina/ai's NativeHttpToChatServiceAdaptor.
    private static ObserverContext newUserContext(Environment env, ObserverContext dispatcherContext) {
        ObserverContext userContext = new ObserverContext();
        userContext.setParent(dispatcherContext);
        userContext.setSpan(dispatcherContext.getSpan());
        userContext.setServiceName(dispatcherContext.getServiceName());
        userContext.setEntrypointFunctionModule(dispatcherContext.getEntrypointFunctionModule());
        userContext.setEntrypointServiceName(dispatcherContext.getEntrypointServiceName());
        userContext.setEntrypointFunctionName(dispatcherContext.getEntrypointFunctionName());
        userContext.setEntrypointResourceAccessor(dispatcherContext.getEntrypointResourceAccessor());
        ObserveUtils.setObserverContextToCurrentFrame(env, userContext);
        return userContext;
    }

    // Puts the dispatcher's context back in place and gives it the entrypoint recorded by the user's resource. Tags
    // are copied onto a span only when it finishes, so the dispatcher's span reports the user's service as well.
    private static void restoreDispatcherContext(Environment env, ObserverContext dispatcherContext,
                                                 ObserverContext userContext) {
        ObserveUtils.setObserverContextToCurrentFrame(env, dispatcherContext);
        if (!userContext.isStarted()) {
            return;
        }
        dispatcherContext.setEntrypointFunctionModule(userContext.getEntrypointFunctionModule());
        dispatcherContext.setEntrypointServiceName(userContext.getEntrypointServiceName());
        dispatcherContext.setEntrypointFunctionName(userContext.getEntrypointFunctionName());
        dispatcherContext.setEntrypointResourceAccessor(userContext.getEntrypointResourceAccessor());
        addTagIfPresent(dispatcherContext, ENTRYPOINT_FUNCTION_MODULE_TAG, userContext.getEntrypointFunctionModule());
        addTagIfPresent(dispatcherContext, ENTRYPOINT_SERVICE_NAME_TAG, userContext.getEntrypointServiceName());
        addTagIfPresent(dispatcherContext, ENTRYPOINT_FUNCTION_NAME_TAG, userContext.getEntrypointFunctionName());
        addTagIfPresent(dispatcherContext, ENTRYPOINT_RESOURCE_ACCESSOR_TAG,
                userContext.getEntrypointResourceAccessor());
    }

    private static void addTagIfPresent(ObserverContext context, String key, String value) {
        if (value != null) {
            context.addTag(key, value);
        }
    }
}
