/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package io.ballerina.lib.ai.azure.identity;

import com.azure.core.exception.ClientAuthenticationException;
import com.azure.identity.CredentialUnavailableException;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;

import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Turns azure-identity failures into Ballerina errors that never carry tokens or secrets. The {@code kind} detail
 * tells the Ballerina side which error type to use; the {@code code} detail carries an {@code AADSTS} code if any.
 *
 * @since 1.6.0
 */
final class IdentityErrors {

    static final String KIND_UNAVAILABLE = "unavailable";
    static final String KIND_AUTHENTICATION = "authentication";
    static final String KIND_OTHER = "other";
    static final String REDACTED = "[redacted]";

    private static final BString KIND = StringUtils.fromString("kind");
    private static final BString CODE = StringUtils.fromString("code");
    private static final int MAX_MESSAGE_LENGTH = 600;
    private static final Pattern AADSTS_CODE = Pattern.compile("AADSTS\\d+");
    /** JSON Web Tokens, e.g. an access token echoed back by a misbehaving endpoint. */
    private static final Pattern JWT = Pattern.compile("eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]*");
    /** Secret-bearing variables whose values must never appear in a message. */
    private static final List<String> SECRET_VARIABLES = List.of("IDENTITY_HEADER", "MSI_SECRET",
            "AZURE_CLIENT_SECRET", "AZURE_CLIENT_CERTIFICATE_PASSWORD", "AZURE_PASSWORD");
    /** MSAL's exception for a response from Entra ID, matched by name (msal4j is not a direct dependency). */
    private static final String MSAL_SERVICE_EXCEPTION = "com.microsoft.aad.msal4j.MsalServiceException";
    /** HTTP statuses with which Entra ID refuses a request; others, such as 429 and 5xx, are temporary. */
    private static final Set<Integer> REFUSED_STATUSES = Set.of(400, 401, 403);

    private IdentityErrors() {
    }

    /**
     * Converts a failure into an error, also redacting configuration values such as a client secret.
     *
     * @param throwable the failure
     * @param secrets   values that must not appear in the message
     * @return the error
     */
    static BError toError(Throwable throwable, Collection<String> secrets) {
        String kind = kindOf(throwable);
        // JWTs first: a secret replaced inside one would break it, so the pattern would no longer match it.
        String message = JWT.matcher(describe(throwable)).replaceAll(REDACTED);
        for (String secret : secrets) {
            if (!secret.isEmpty()) {
                message = message.replace(secret, REDACTED);
            }
        }
        message = sanitize(message);
        BMap<BString, Object> detail = ValueCreator.createMapValue(
                TypeCreator.createMapType(PredefinedTypes.TYPE_ANYDATA));
        detail.put(KIND, StringUtils.fromString(kind));
        Matcher code = AADSTS_CODE.matcher(message);
        if (code.find()) {
            detail.put(CODE, StringUtils.fromString(code.group()));
        }
        return ErrorCreator.createError(StringUtils.fromString(message), detail);
    }

    // An MSAL service error anywhere in the chain decides by its HTTP status, even when azure-identity wraps it.
    private static String kindOf(Throwable throwable) {
        Throwable msalError = null;
        Class<?> msalType = null;
        Set<Throwable> seen = new LinkedHashSet<>();
        for (Throwable t = throwable; t != null && seen.add(t); t = t.getCause()) {
            if (t instanceof CredentialUnavailableException) {
                return KIND_UNAVAILABLE;
            }
            if (msalType == null) {
                msalType = msalServiceExceptionType(t);
                msalError = t;
            }
        }
        if (msalType != null) {
            Integer status = statusCode(msalType, msalError);
            return status != null && REFUSED_STATUSES.contains(status) ? KIND_AUTHENTICATION : KIND_OTHER;
        }
        seen.clear();
        for (Throwable t = throwable; t != null && seen.add(t); t = t.getCause()) {
            if (t instanceof ClientAuthenticationException) {
                return KIND_AUTHENTICATION;
            }
        }
        return KIND_OTHER;
    }

    // MsalServiceException itself when the throwable is one (or a subclass), otherwise null.
    private static Class<?> msalServiceExceptionType(Throwable throwable) {
        for (Class<?> type = throwable.getClass(); type != null; type = type.getSuperclass()) {
            if (MSAL_SERVICE_EXCEPTION.equals(type.getName())) {
                return type;
            }
        }
        return null;
    }

    // MsalServiceException.statusCode(), read by reflection on that class (registered for native images); null when
    // it can't be read.
    private static Integer statusCode(Class<?> msalType, Throwable msalError) {
        try {
            return msalType.getMethod("statusCode").invoke(msalError) instanceof Integer status ? status : null;
        } catch (ReflectiveOperationException | RuntimeException e) {
            return null;
        }
    }

    // The top-level message plus the root cause (e.g. a TLS failure), which azure-identity often wraps.
    private static String describe(Throwable throwable) {
        Throwable root = throwable;
        Set<Throwable> seen = new LinkedHashSet<>();
        while (root.getCause() != null && seen.add(root)) {
            root = root.getCause();
        }
        String message = messageOf(throwable);
        if (root != throwable) {
            String rootMessage = messageOf(root);
            if (!message.contains(rootMessage)) {
                message = message + " (cause: " + rootMessage + ")";
            }
        }
        return message;
    }

    private static String messageOf(Throwable throwable) {
        String message = throwable.getMessage();
        String name = throwable.getClass().getSimpleName();
        return message == null || message.isBlank() ? name : name + ": " + message.strip();
    }

    // Redacts secret-bearing environment variables and limits the length; JWTs are already redacted.
    private static String sanitize(String message) {
        String sanitized = message;
        for (String variable : SECRET_VARIABLES) {
            String secret = System.getenv(variable);
            if (secret != null && secret.length() >= 4) {
                sanitized = sanitized.replace(secret, REDACTED);
            }
        }
        return sanitized.length() > MAX_MESSAGE_LENGTH
                ? sanitized.substring(0, MAX_MESSAGE_LENGTH) + "..." : sanitized;
    }
}
