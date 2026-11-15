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

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.core.http.HttpClient;
import com.azure.core.util.ConfigurationBuilder;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import java.time.OffsetDateTime;

/**
 * Builds Java azure-identity credentials for the {@code ai.azure.identity} module and fetches tokens from them.
 * Every credential is given an HTTP client built by {@link TokenTransport}, so token requests honour the
 * configured trust material, proxy and timeout. Caching happens on the Ballerina side.
 *
 * @since 1.6.0
 */
public final class Credentials {

    private static final String NATIVE_CREDENTIAL = "credential";
    private static final String TYPE_DEFAULT = "default";
    private static final String TYPE_MANAGED_IDENTITY = "managedIdentity";
    private static final String SOURCES_ALL = "all";
    private static final String AZURE_TOKEN_CREDENTIALS = "AZURE_TOKEN_CREDENTIALS";
    private static final String AZURE_PUBLIC_CLOUD = "https://login.microsoftonline.com/";

    private static final BString SOURCES = StringUtils.fromString("sources");
    private static final BString MANAGED_IDENTITY_CLIENT_ID = StringUtils.fromString("managedIdentityClientId");
    private static final BString TENANT_ID = StringUtils.fromString("tenantId");
    private static final BString CLIENT_ID = StringUtils.fromString("clientId");
    private static final BString AUTHORITY_HOST = StringUtils.fromString("authorityHost");
    private static final BString TOKEN = StringUtils.fromString("token");
    private static final BString EXPIRES_ON = StringUtils.fromString("expiresOn");
    private static final BString REFRESH_ON = StringUtils.fromString("refreshOn");

    private Credentials() {
    }

    /**
     * Builds the credential and attaches it to {@code credential} as native data. Makes no network call.
     *
     * @param credential     the Ballerina {@code NativeCredential} object
     * @param credentialType the {@code type} of the credential configuration
     * @param config         the credential configuration record
     * @param transport      the {@code NativeTransport} record
     * @return {@code null} on success, otherwise an error
     */
    public static Object init(BObject credential, BString credentialType, BMap<BString, Object> config,
                              BMap<BString, Object> transport) {
        try {
            HttpClient httpClient = TokenTransport.httpClient(transport);
            String authorityHost = transport.getStringValue(AUTHORITY_HOST).getValue();
            TokenCredential tokenCredential = switch (credentialType.getValue()) {
                case TYPE_DEFAULT -> defaultCredential(config, httpClient, authorityHost);
                case TYPE_MANAGED_IDENTITY -> managedIdentityCredential(config, httpClient);
                default -> throw new IllegalArgumentException(
                        "credential type '" + credentialType.getValue() + "' is not supported");
            };
            credential.addNativeData(NATIVE_CREDENTIAL, tokenCredential);
            return null;
        } catch (Exception | LinkageError e) {
            return IdentityErrors.toError(e);
        }
    }

    /**
     * Fetches a token from the credential source, yielding the strand while the request runs.
     *
     * @param env        the Ballerina environment
     * @param credential the Ballerina {@code NativeCredential} object
     * @param scopes     the scopes to request
     * @return a {@code map<anydata>} with {@code token}, {@code expiresOn} and optionally {@code refreshOn}, or an
     * error
     */
    public static Object getToken(Environment env, BObject credential, BArray scopes) {
        TokenCredential tokenCredential = (TokenCredential) credential.getNativeData(NATIVE_CREDENTIAL);
        TokenRequestContext context = new TokenRequestContext().addScopes(scopes.getStringArray());
        return env.yieldAndRun(() -> {
            try {
                return toTokenMap(tokenCredential.getTokenSync(context));
            } catch (Exception | LinkageError e) {
                return IdentityErrors.toError(e);
            }
        });
    }

    private static TokenCredential defaultCredential(BMap<BString, Object> config, HttpClient httpClient,
                                                     String authorityHost) {
        DefaultAzureCredentialBuilder builder = new DefaultAzureCredentialBuilder().httpClient(httpClient);
        // Only an explicit non-default authority overrides AZURE_AUTHORITY_HOST from the environment.
        if (!AZURE_PUBLIC_CLOUD.equals(authorityHost)) {
            builder.authorityHost(authorityHost);
        }
        String sources = config.getStringValue(SOURCES).getValue();
        if (!SOURCES_ALL.equals(sources)) {
            builder.configuration(new ConfigurationBuilder().putProperty(AZURE_TOKEN_CREDENTIALS, sources).build());
        }
        String managedIdentityClientId = optString(config, MANAGED_IDENTITY_CLIENT_ID);
        if (managedIdentityClientId != null) {
            builder.managedIdentityClientId(managedIdentityClientId);
        }
        String tenantId = optString(config, TENANT_ID);
        if (tenantId != null) {
            builder.tenantId(tenantId);
        }
        return builder.build();
    }

    private static TokenCredential managedIdentityCredential(BMap<BString, Object> config, HttpClient httpClient) {
        ManagedIdentityCredentialBuilder builder = new ManagedIdentityCredentialBuilder().httpClient(httpClient);
        String clientId = optString(config, CLIENT_ID);
        if (clientId != null) {
            builder.clientId(clientId);
        }
        return builder.build();
    }

    private static BMap<BString, Object> toTokenMap(AccessToken token) {
        BMap<BString, Object> map = ValueCreator.createMapValue(
                TypeCreator.createMapType(PredefinedTypes.TYPE_ANYDATA));
        map.put(TOKEN, StringUtils.fromString(token.getToken()));
        map.put(EXPIRES_ON, token.getExpiresAt().toEpochSecond());
        OffsetDateTime refreshAt = token.getRefreshAt();
        if (refreshAt != null) {
            map.put(REFRESH_ON, refreshAt.toEpochSecond());
        }
        return map;
    }

    private static String optString(BMap<BString, Object> record, BString field) {
        Object value = record.get(field);
        if (value instanceof BString string && !string.getValue().isBlank()) {
            return string.getValue().strip();
        }
        return null;
    }
}
