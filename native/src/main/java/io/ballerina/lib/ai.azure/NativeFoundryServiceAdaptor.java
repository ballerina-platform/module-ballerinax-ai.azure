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

import io.ballerina.runtime.api.values.BObject;

import java.util.IdentityHashMap;
import java.util.Map;

/**
 * Links an attached {@code azure:FoundryInvocationService} with the internal Foundry dispatcher services that
 * {@code azure:FoundryListener} attaches to the underlying {@code http:Listener} in its place.
 *
 * <p>Each dispatcher is linked with the user's service as native data, so the dispatcher holds no Ballerina state
 * (and stays {@code isolated}) while it can still reach the user's service. The user's service keeps one dispatcher
 * per {@code FoundryListener} it is attached to, so {@code detach} on one listener finds that listener's dispatcher
 * and never touches the dispatcher of another listener the same service is attached to.
 *
 * @since 1.6.0
 */
public final class NativeFoundryServiceAdaptor {

    // The user's FoundryInvocationService, stored on the dispatcher as native data.
    private static final String USER_FOUNDRY_SERVICE = "AI_AZURE_USER_FOUNDRY_SERVICE";
    // The dispatchers of the user's FoundryInvocationService, keyed by FoundryListener, stored on the service.
    private static final String FOUNDRY_DISPATCHERS = "AI_AZURE_FOUNDRY_DISPATCHERS";
    // Guards every dispatcher map. Attach and detach are rare lifecycle calls, so one lock is enough.
    private static final Object DISPATCHERS_LOCK = new Object();

    private NativeFoundryServiceAdaptor() {
    }

    /**
     * Links a dispatcher with the user's service it forwards requests to.
     *
     * @param dispatcher     the internal dispatcher service attached to the {@code http:Listener}
     * @param foundryService the user's {@code azure:FoundryInvocationService}
     */
    public static void setFoundryService(BObject dispatcher, BObject foundryService) {
        dispatcher.addNativeData(USER_FOUNDRY_SERVICE, foundryService);
    }

    /**
     * Returns the user's service linked with a dispatcher.
     *
     * @param dispatcher the internal dispatcher service
     * @return the linked {@code azure:FoundryInvocationService}, or {@code null} (Ballerina nil) when none is linked
     */
    public static Object getFoundryService(BObject dispatcher) {
        return dispatcher.getNativeData(USER_FOUNDRY_SERVICE);
    }

    /**
     * Removes the link from a dispatcher to the user's service, after the dispatcher is detached.
     *
     * @param dispatcher the internal dispatcher service
     */
    public static void unlinkFoundryService(BObject dispatcher) {
        dispatcher.addNativeData(USER_FOUNDRY_SERVICE, null);
    }

    /**
     * Records the dispatcher a {@code FoundryListener} attached for the user's service, unless that listener already
     * has one for the service.
     *
     * @param foundryService  the user's {@code azure:FoundryInvocationService}
     * @param foundryListener the {@code azure:FoundryListener}
     * @param dispatcher      the internal dispatcher service
     * @return {@code true} when the dispatcher is recorded, {@code false} when the listener already has one
     */
    public static boolean registerDispatcher(BObject foundryService, BObject foundryListener, BObject dispatcher) {
        synchronized (DISPATCHERS_LOCK) {
            return dispatchersOf(foundryService, true).byListener.putIfAbsent(foundryListener, dispatcher) == null;
        }
    }

    /**
     * Returns the dispatcher a {@code FoundryListener} attached for the user's service.
     *
     * @param foundryService  the user's {@code azure:FoundryInvocationService}
     * @param foundryListener the {@code azure:FoundryListener}
     * @return the dispatcher, or {@code null} (Ballerina nil) when the service is not attached to that listener
     */
    public static Object getDispatcher(BObject foundryService, BObject foundryListener) {
        synchronized (DISPATCHERS_LOCK) {
            Dispatchers dispatchers = dispatchersOf(foundryService, false);
            return dispatchers == null ? null : dispatchers.byListener.get(foundryListener);
        }
    }

    /**
     * Removes and returns the dispatcher a {@code FoundryListener} attached for the user's service.
     *
     * @param foundryService  the user's {@code azure:FoundryInvocationService}
     * @param foundryListener the {@code azure:FoundryListener}
     * @return the removed dispatcher, or {@code null} (Ballerina nil) when the service is not attached to that
     *         listener
     */
    public static Object removeDispatcher(BObject foundryService, BObject foundryListener) {
        synchronized (DISPATCHERS_LOCK) {
            Dispatchers dispatchers = dispatchersOf(foundryService, false);
            return dispatchers == null ? null : dispatchers.byListener.remove(foundryListener);
        }
    }

    // Must be called while holding DISPATCHERS_LOCK.
    private static Dispatchers dispatchersOf(BObject foundryService, boolean create) {
        Object existing = foundryService.getNativeData(FOUNDRY_DISPATCHERS);
        if (existing instanceof Dispatchers dispatchers) {
            return dispatchers;
        }
        if (!create) {
            return null;
        }
        Dispatchers dispatchers = new Dispatchers();
        foundryService.addNativeData(FOUNDRY_DISPATCHERS, dispatchers);
        return dispatchers;
    }

    // The dispatchers of one user service, keyed by the identity of the FoundryListener that attached them.
    private static final class Dispatchers {
        private final Map<BObject, BObject> byListener = new IdentityHashMap<>();
    }
}
