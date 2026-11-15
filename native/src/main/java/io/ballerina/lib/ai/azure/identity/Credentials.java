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
import com.azure.identity.ClientCertificateCredentialBuilder;
import com.azure.identity.ClientSecretCredentialBuilder;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import com.azure.identity.WorkloadIdentityCredentialBuilder;
import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.Consumer;

/**
 * Builds Java azure-identity credentials for the {@code ai.azure.identity} module and fetches tokens from them.
 * Every credential is given an HTTP client built by {@link TokenTransport}, so token requests honour the
 * configured trust material, proxy and timeout. Caching happens on the Ballerina side.
 *
 * @since 1.6.0
 */
public final class Credentials {

    private static final String NATIVE_CREDENTIAL = "credential";
    private static final String NATIVE_SECRETS = "secrets";
    private static final String TYPE_DEFAULT = "default";
    private static final String TYPE_MANAGED_IDENTITY = "managedIdentity";
    private static final String TYPE_CLIENT_SECRET = "clientSecret";
    private static final String TYPE_WORKLOAD_IDENTITY = "workloadIdentity";
    private static final String TYPE_CLIENT_CERTIFICATE = "clientCertificate";
    private static final String PEM_PREFIX = "-----BEGIN";
    private static final String SOURCES_ALL = "all";
    private static final String AZURE_TOKEN_CREDENTIALS = "AZURE_TOKEN_CREDENTIALS";
    private static final String TUNNELING_DISABLED_SCHEMES = "jdk.http.auth.tunneling.disabledSchemes";
    private static final String AZURE_PUBLIC_CLOUD = "https://login.microsoftonline.com/";
    /** Authority hosts MSAL knows; for any other host it would ask the public cloud for instance metadata. */
    private static final Set<String> KNOWN_AUTHORITY_HOSTS = Set.of(AZURE_PUBLIC_CLOUD,
            "https://login.microsoftonline.us/", "https://login.chinacloudapi.cn/");

    private static final BString SOURCES = StringUtils.fromString("sources");
    private static final BString TENANT_ID = StringUtils.fromString("tenantId");
    private static final BString CLIENT_ID = StringUtils.fromString("clientId");
    private static final BString CLIENT_SECRET = StringUtils.fromString("clientSecret");
    private static final BString TOKEN_FILE_PATH = StringUtils.fromString("tokenFilePath");
    private static final BString CERTIFICATE_PATH = StringUtils.fromString("certificatePath");
    private static final BString CERTIFICATE_PASSWORD = StringUtils.fromString("certificatePassword");
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
        List<String> secrets = secretsOf(config);
        try {
            HttpClient httpClient = TokenTransport.httpClient(transport);
            String authorityHost = transport.getStringValue(AUTHORITY_HOST).getValue();
            TokenCredential tokenCredential = switch (credentialType.getValue()) {
                case TYPE_DEFAULT -> defaultCredential(config, httpClient, authorityHost);
                case TYPE_MANAGED_IDENTITY -> managedIdentityCredential(config, httpClient);
                case TYPE_CLIENT_SECRET -> clientSecretCredential(config, httpClient, authorityHost);
                case TYPE_WORKLOAD_IDENTITY -> workloadIdentityCredential(config, httpClient, authorityHost);
                case TYPE_CLIENT_CERTIFICATE -> clientCertificateCredential(config, httpClient, authorityHost);
                default -> throw new IllegalArgumentException(
                        "credential type '" + credentialType.getValue() + "' is not supported");
            };
            credential.addNativeData(NATIVE_CREDENTIAL, tokenCredential);
            credential.addNativeData(NATIVE_SECRETS, secrets);
            return null;
        } catch (GeneralSecurityException | IOException | RuntimeException | LinkageError e) {
            return IdentityErrors.toError(e, secrets);
        }
    }

    /**
     * Tells whether the JDK HTTP client refuses Basic proxy authentication for HTTPS tunnels, which it does unless the
     * JVM is started with {@code -Djdk.http.auth.tunneling.disabledSchemes=} (the JDK's default value is
     * {@code Basic}).
     *
     * @return {@code true} if Basic is disabled for HTTPS tunnels
     */
    public static boolean isBasicProxyTunnelingDisabled() {
        String schemes = System.getProperty(TUNNELING_DISABLED_SCHEMES, "Basic");
        for (String scheme : schemes.split(",")) {
            if (scheme.strip().equalsIgnoreCase("Basic")) {
                return true;
            }
        }
        return false;
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
        @SuppressWarnings("unchecked")
        List<String> secrets = (List<String>) credential.getNativeData(NATIVE_SECRETS);
        TokenRequestContext context = new TokenRequestContext().addScopes(scopes.getStringArray());
        return env.yieldAndRun(() -> {
            try {
                return toTokenMap(tokenCredential.getTokenSync(context));
            } catch (Exception | LinkageError e) {
                return IdentityErrors.toError(e, secrets);
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
        String managedIdentityClientId = optString(config, CLIENT_ID);
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

    private static TokenCredential clientSecretCredential(BMap<BString, Object> config, HttpClient httpClient,
                                                          String authorityHost) {
        ClientSecretCredentialBuilder builder = new ClientSecretCredentialBuilder()
                .tenantId(requireString(config, TENANT_ID))
                .clientId(requireString(config, CLIENT_ID))
                .clientSecret(requireString(config, CLIENT_SECRET))
                .httpClient(httpClient);
        applyAuthority(authorityHost, builder::authorityHost, builder::disableInstanceDiscovery);
        return builder.build();
    }

    // Omitted settings fall back to AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE.
    private static TokenCredential workloadIdentityCredential(BMap<BString, Object> config, HttpClient httpClient,
                                                              String authorityHost) {
        WorkloadIdentityCredentialBuilder builder = new WorkloadIdentityCredentialBuilder().httpClient(httpClient);
        String tenantId = optString(config, TENANT_ID);
        if (tenantId != null) {
            builder.tenantId(tenantId);
        }
        String clientId = optString(config, CLIENT_ID);
        if (clientId != null) {
            builder.clientId(clientId);
        }
        String tokenFilePath = optString(config, TOKEN_FILE_PATH);
        if (tokenFilePath != null) {
            builder.tokenFilePath(tokenFilePath);
        }
        applyAuthority(authorityHost, builder::authorityHost, builder::disableInstanceDiscovery);
        return builder.build();
    }

    // A PKCS#12 (PFX) file when a password is given, as in azure.storage.blob; a PEM file otherwise.
    private static TokenCredential clientCertificateCredential(BMap<BString, Object> config, HttpClient httpClient,
                                                               String authorityHost) throws IOException {
        String certificatePath = requireString(config, CERTIFICATE_PATH);
        ClientCertificateCredentialBuilder builder = new ClientCertificateCredentialBuilder()
                .tenantId(requireString(config, TENANT_ID))
                .clientId(requireString(config, CLIENT_ID))
                .httpClient(httpClient);
        String password = optString(config, CERTIFICATE_PASSWORD);
        if (password != null) {
            builder.pfxCertificate(certificatePath).clientCertificatePassword(password);
        } else if (isPem(Path.of(certificatePath))) {
            builder.pemCertificate(certificatePath);
        } else {
            throw new IllegalArgumentException("'certificatePath' is not a PEM file; a PKCS#12 (PFX) file needs "
                    + "'certificatePassword'");
        }
        applyAuthority(authorityHost, builder::authorityHost, builder::disableInstanceDiscovery);
        return builder.build();
    }

    private static boolean isPem(Path path) throws IOException {
        byte[] head = new byte[64];
        int read;
        try (InputStream in = Files.newInputStream(path)) {
            read = in.readNBytes(head, 0, head.length);
        }
        return new String(head, 0, read, StandardCharsets.US_ASCII).stripLeading().startsWith(PEM_PREFIX);
    }

    // An explicit non-default authority overrides AZURE_AUTHORITY_HOST. MSAL sends instance discovery for an unknown
    // host to the public cloud, which fails for private clouds and local endpoints alike, so it is turned off for
    // any authority host other than the known clouds.
    private static void applyAuthority(String authorityHost, Consumer<String> setAuthorityHost,
                                       Runnable disableInstanceDiscovery) {
        if (!AZURE_PUBLIC_CLOUD.equals(authorityHost)) {
            setAuthorityHost.accept(authorityHost);
        }
        String normalized = authorityHost.toLowerCase(Locale.ROOT);
        if (!KNOWN_AUTHORITY_HOSTS.contains(normalized.endsWith("/") ? normalized : normalized + "/")) {
            disableInstanceDiscovery.run();
        }
    }

    // Values from the configuration that must never appear in an error message.
    private static List<String> secretsOf(BMap<BString, Object> config) {
        List<String> secrets = new ArrayList<>();
        String clientSecret = optString(config, CLIENT_SECRET);
        if (clientSecret != null) {
            secrets.add(clientSecret);
        }
        String certificatePassword = optString(config, CERTIFICATE_PASSWORD);
        if (certificatePassword != null) {
            secrets.add(certificatePassword);
        }
        // The federated token as it is now; a rotated token is a JWT, which the sanitiser redacts anyway.
        String tokenFilePath = optString(config, TOKEN_FILE_PATH);
        if (tokenFilePath != null) {
            try {
                secrets.add(Files.readString(Path.of(tokenFilePath), StandardCharsets.UTF_8).strip());
            } catch (IOException | RuntimeException e) {
                // Unreadable now: the credential reports that itself when it reads the file.
            }
        }
        return List.copyOf(secrets);
    }

    private static BMap<BString, Object> toTokenMap(AccessToken token) {
        BMap<BString, Object> map = ValueCreator.createMapValue(
                TypeCreator.createMapType(PredefinedTypes.TYPE_ANYDATA));
        long expiresOn = token.getExpiresAt().toEpochSecond();
        map.put(TOKEN, StringUtils.fromString(token.getToken()));
        map.put(EXPIRES_ON, expiresOn);
        // azure-identity reports the epoch when the source gave no refresh hint; only a real hint is passed on,
        // otherwise every token would look due for an early refresh.
        OffsetDateTime refreshAt = token.getRefreshAt();
        if (refreshAt != null && refreshAt.toEpochSecond() > 0 && refreshAt.toEpochSecond() < expiresOn) {
            map.put(REFRESH_ON, refreshAt.toEpochSecond());
        }
        return map;
    }

    // A required field: present and not blank. The message names the field, never its value.
    private static String requireString(BMap<BString, Object> record, BString field) {
        String value = optString(record, field);
        if (value == null) {
            throw new IllegalArgumentException("'" + field.getValue() + "' must not be empty");
        }
        return value;
    }

    private static String optString(BMap<BString, Object> record, BString field) {
        Object value = record.get(field);
        if (value instanceof BString string && !string.getValue().isBlank()) {
            return string.getValue().strip();
        }
        return null;
    }
}
