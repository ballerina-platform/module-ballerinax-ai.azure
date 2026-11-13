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
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.observability.ObserveUtils;
import io.ballerina.runtime.observability.ObserverContext;
import io.ballerina.runtime.observability.tracer.BSpan;

import java.util.HashMap;
import java.util.Map;

/**
 * Adds the Foundry span attributes to the spans of a Foundry protocol request.
 *
 * <p>The attributes are written straight to the span ({@link BSpan#addTag}), never with
 * {@link ObserverContext#addTag}: the observer context's tags also become metric tags, and per-request values such
 * as the invocation ID would give the metrics an unbounded number of tag values.
 *
 * <p>Two spans get them: the dispatcher's request span, which is the span of the current frame when the dispatcher
 * resource calls {@link #setFoundrySpanTags}, and the span of the user's resource. The user's span doesn't exist yet
 * when the dispatcher calls the resource, so the attributes are kept as a property of the dispatcher's observer
 * context, and the observer context the invoker creates for the user's resource writes them to the span the
 * runtime gives it when the resource starts ({@link #newUserObserverContext}). Spans started beneath the user's
 * resource (for example a model provider's client call) get fresh observer contexts from the runtime, which can't
 * be given attributes this way.
 *
 * @since 1.6.0
 */
public final class FoundryTracing {

    // The observer-context property under which the dispatcher keeps the span attributes of the request. Properties,
    // unlike tags, are not reported as metric tags.
    static final String SPAN_TAGS_PROPERTY = "ballerinax.ai.azure.foundry.spanTags";

    private FoundryTracing() {
    }

    /**
     * Tells whether tracing is enabled, so the dispatcher builds the span attributes only when they are used.
     *
     * @return {@code true} when Ballerina tracing is enabled
     */
    public static boolean isFoundryTracingEnabled() {
        return ObserveUtils.isTracingEnabled();
    }

    /**
     * Adds attributes to the current span (the dispatcher's request span) and keeps them for the span of the user's
     * resource. Does nothing when tracing is disabled or there is no current span.
     *
     * @param env  the Ballerina environment
     * @param tags the attributes
     */
    public static void setFoundrySpanTags(Environment env, BMap<BString, Object> tags) {
        if (!ObserveUtils.isTracingEnabled()) {
            return;
        }
        ObserverContext context = ObserveUtils.getObserverContextOfCurrentFrame(env);
        if (context == null) {
            return;
        }
        Map<String, String> spanTags = new HashMap<>();
        for (Map.Entry<BString, Object> entry : tags.entrySet()) {
            spanTags.put(entry.getKey().getValue(), entry.getValue().toString());
        }
        context.addProperty(SPAN_TAGS_PROPERTY, Map.copyOf(spanTags));
        BSpan span = context.getSpan();
        if (span != null) {
            span.addTags(spanTags);
        }
    }

    /**
     * Adds one attribute to the current span only. Does nothing when tracing is disabled or there is no current span.
     *
     * @param env   the Ballerina environment
     * @param key   the attribute name
     * @param value the attribute value
     */
    public static void addFoundrySpanTag(Environment env, BString key, BString value) {
        if (!ObserveUtils.isTracingEnabled()) {
            return;
        }
        ObserverContext context = ObserveUtils.getObserverContextOfCurrentFrame(env);
        BSpan span = context == null ? null : context.getSpan();
        if (span != null) {
            span.addTag(key.getValue(), value.getValue());
        }
    }

    /**
     * Creates the observer context for the user's resource. When the dispatcher kept span attributes for the
     * request, the context writes them to every span it is given, which includes the span the runtime starts for
     * the user's resource.
     *
     * @param dispatcherContext the dispatcher's observer context
     * @return the observer context for the user's resource
     */
    static ObserverContext newUserObserverContext(ObserverContext dispatcherContext) {
        if (dispatcherContext.getProperty(SPAN_TAGS_PROPERTY) instanceof Map<?, ?> tags && !tags.isEmpty()) {
            Map<String, String> spanTags = new HashMap<>();
            tags.forEach((key, value) -> spanTags.put(String.valueOf(key), String.valueOf(value)));
            return new SpanTaggingObserverContext(spanTags);
        }
        return new ObserverContext();
    }

    /**
     * An observer context that writes fixed attributes to each span it is given. The runtime gives a resource's
     * observer context its span when the resource starts, the closest Ballerina has to an OpenTelemetry span
     * processor's {@code on_start}.
     */
    private static final class SpanTaggingObserverContext extends ObserverContext {
        private final Map<String, String> spanTags;

        SpanTaggingObserverContext(Map<String, String> spanTags) {
            this.spanTags = Map.copyOf(spanTags);
        }

        @Override
        public void setSpan(BSpan span) {
            super.setSpan(span);
            if (span != null) {
                span.addTags(spanTags);
            }
        }
    }
}
