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

import com.azure.core.http.HttpClient;
import com.azure.core.http.HttpHeaderName;
import com.azure.core.http.HttpRequest;
import com.azure.core.http.HttpResponse;
import com.azure.core.http.ProxyOptions;
import com.azure.core.http.jdk.httpclient.JdkHttpClientBuilder;
import com.azure.core.util.Context;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BDecimal;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;
import reactor.core.publisher.Mono;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * Builds the azure-core {@link HttpClient} every credential uses for its token requests: the JDK HTTP client, with
 * the configured trust material, proxy and timeouts. No Netty is involved, so nothing clashes with the Netty version
 * {@code ballerina/http} brings.
 *
 * <p>Trust is the JVM's default trust store plus the certificates of the given PEM files (for example the
 * {@code SSL_CERT_FILE} bundle of a TLS-inspecting proxy) and PKCS#12 trust stores. Local managed identity
 * endpoints are always reached without the proxy.
 *
 * @since 1.6.0
 */
final class TokenTransport {

    /** Appended to the {@code User-Agent} of every token request, so requests made through this client are visible. */
    static final String USER_AGENT_MARK = "ballerinax-ai.azure-identity";

    private static final BString TRUSTED_CERT_FILES = StringUtils.fromString("trustedCertFiles");
    private static final BString TRUST_STORES = StringUtils.fromString("trustStores");
    private static final BString PROTOCOLS = StringUtils.fromString("protocols");
    private static final BString CIPHERS = StringUtils.fromString("ciphers");
    private static final BString TIMEOUT = StringUtils.fromString("timeout");
    private static final BString PROXY = StringUtils.fromString("proxy");
    private static final BString PATH = StringUtils.fromString("path");
    private static final BString PASSWORD = StringUtils.fromString("password");
    private static final BString HOST = StringUtils.fromString("host");
    private static final BString PORT = StringUtils.fromString("port");
    private static final BString USER_NAME = StringUtils.fromString("userName");

    private static final Pattern PEM_CERTIFICATE = Pattern.compile(
            "-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]+?)-----END CERTIFICATE-----");
    /** Local endpoints that must never go through a proxy: IMDS and the managed identity token services. */
    private static final List<String> LOCAL_HOSTS = List.of("localhost", "127.0.0.1", "169.254.169.254");
    private static final List<String> MANAGED_IDENTITY_ENDPOINT_VARIABLES =
            List.of("IDENTITY_ENDPOINT", "MSI_ENDPOINT", "IMDS_ENDPOINT");

    private TokenTransport() {
    }

    @SuppressWarnings("unchecked")
    static HttpClient httpClient(BMap<BString, Object> transport) throws GeneralSecurityException, IOException {
        Duration timeout = Duration.ofMillis(
                ((BDecimal) transport.get(TIMEOUT)).decimalValue().movePointRight(3).longValue());
        java.net.http.HttpClient.Builder jdkBuilder = java.net.http.HttpClient.newBuilder()
                .sslContext(sslContext(transport))
                .connectTimeout(timeout);
        String[] protocols = ((BArray) transport.get(PROTOCOLS)).getStringArray();
        String[] ciphers = ((BArray) transport.get(CIPHERS)).getStringArray();
        if (protocols.length > 0 || ciphers.length > 0) {
            SSLParameters parameters = new SSLParameters();
            if (protocols.length > 0) {
                parameters.setProtocols(protocols);
            }
            if (ciphers.length > 0) {
                parameters.setCipherSuites(ciphers);
            }
            jdkBuilder.sslParameters(parameters);
        }

        JdkHttpClientBuilder builder = new JdkHttpClientBuilder(jdkBuilder)
                .connectionTimeout(timeout)
                .responseTimeout(timeout)
                .readTimeout(timeout);
        BMap<BString, Object> proxy = (BMap<BString, Object>) transport.get(PROXY);
        if (proxy != null) {
            builder.proxy(proxyOptions(proxy));
        }
        return new MarkingHttpClient(builder.build());
    }

    private static ProxyOptions proxyOptions(BMap<BString, Object> proxy) {
        ProxyOptions options = new ProxyOptions(ProxyOptions.Type.HTTP, new InetSocketAddress(
                proxy.getStringValue(HOST).getValue(), Math.toIntExact((Long) proxy.get(PORT))));
        String userName = proxy.getStringValue(USER_NAME).getValue();
        if (!userName.isEmpty()) {
            options.setCredentials(userName, proxy.getStringValue(PASSWORD).getValue());
        }
        Set<String> nonProxyHosts = new LinkedHashSet<>(LOCAL_HOSTS);
        for (String variable : MANAGED_IDENTITY_ENDPOINT_VARIABLES) {
            String endpoint = System.getenv(variable);
            if (endpoint != null && !endpoint.isBlank()) {
                try {
                    String host = URI.create(endpoint.strip()).getHost();
                    if (host != null) {
                        nonProxyHosts.add(host);
                    }
                } catch (IllegalArgumentException e) {
                    // A malformed endpoint isn't added; the credential that needs it reports the problem itself.
                }
            }
        }
        options.setNonProxyHosts(String.join("|", nonProxyHosts));
        return options;
    }

    private static SSLContext sslContext(BMap<BString, Object> transport)
            throws GeneralSecurityException, IOException {
        SSLContext context = SSLContext.getInstance("TLS");
        String[] pemFiles = ((BArray) transport.get(TRUSTED_CERT_FILES)).getStringArray();
        BArray trustStores = (BArray) transport.get(TRUST_STORES);
        if (pemFiles.length == 0 && trustStores.size() == 0) {
            return SSLContext.getDefault();
        }

        KeyStore trusted = KeyStore.getInstance("PKCS12");
        trusted.load(null, null);
        int index = 0;
        for (X509Certificate certificate : defaultTrustManager().getAcceptedIssuers()) {
            trusted.setCertificateEntry("default-" + index++, certificate);
        }
        for (String pemFile : pemFiles) {
            for (Certificate certificate : readPemCertificates(pemFile)) {
                trusted.setCertificateEntry("pem-" + index++, certificate);
            }
        }
        for (int i = 0; i < trustStores.size(); i++) {
            @SuppressWarnings("unchecked")
            BMap<BString, Object> store = (BMap<BString, Object>) trustStores.get(i);
            for (Certificate certificate : readTrustStore(store)) {
                trusted.setCertificateEntry("store-" + index++, certificate);
            }
        }
        TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        factory.init(trusted);
        context.init(null, factory.getTrustManagers(), null);
        return context;
    }

    private static X509TrustManager defaultTrustManager() throws GeneralSecurityException {
        TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        factory.init((KeyStore) null);
        for (TrustManager manager : factory.getTrustManagers()) {
            if (manager instanceof X509TrustManager x509) {
                return x509;
            }
        }
        throw new GeneralSecurityException("the JVM has no default X.509 trust manager");
    }

    // Reads every certificate block of a PEM bundle, skipping comments and other text between blocks.
    static List<Certificate> readPemCertificates(String file) throws GeneralSecurityException, IOException {
        String pem;
        try {
            pem = Files.readString(Path.of(file), StandardCharsets.US_ASCII);
        } catch (IOException e) {
            throw new IOException("could not read the trusted certificate file '" + file + "'", e);
        }
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        List<Certificate> certificates = new ArrayList<>();
        Matcher matcher = PEM_CERTIFICATE.matcher(pem);
        while (matcher.find()) {
            byte[] der = Base64.getMimeDecoder().decode(matcher.group(1));
            certificates.add(factory.generateCertificate(new java.io.ByteArrayInputStream(der)));
        }
        if (certificates.isEmpty()) {
            throw new GeneralSecurityException("the trusted certificate file '" + file
                    + "' contains no PEM certificates");
        }
        return certificates;
    }

    private static List<Certificate> readTrustStore(BMap<BString, Object> store)
            throws GeneralSecurityException, IOException {
        String path = store.getStringValue(PATH).getValue();
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (InputStream in = Files.newInputStream(Path.of(path))) {
            keyStore.load(in, store.getStringValue(PASSWORD).getValue().toCharArray());
        } catch (IOException e) {
            throw new IOException("could not read the trust store '" + path + "'", e);
        }
        List<Certificate> certificates = new ArrayList<>();
        for (String alias : Collections.list(keyStore.aliases())) {
            Certificate certificate = keyStore.getCertificate(alias);
            if (certificate != null) {
                certificates.add(certificate);
            }
        }
        return certificates;
    }

    /**
     * Delegates to the JDK client and marks each request's {@code User-Agent}.
     *
     * @param delegate the JDK-based azure-core client
     */
    private record MarkingHttpClient(HttpClient delegate) implements HttpClient {

        @Override
        public Mono<HttpResponse> send(HttpRequest request) {
            return delegate.send(mark(request));
        }

        @Override
        public Mono<HttpResponse> send(HttpRequest request, Context context) {
            return delegate.send(mark(request), context);
        }

        @Override
        public HttpResponse sendSync(HttpRequest request, Context context) {
            return delegate.sendSync(mark(request), context);
        }

        private static HttpRequest mark(HttpRequest request) {
            String userAgent = request.getHeaders().getValue(HttpHeaderName.USER_AGENT);
            request.setHeader(HttpHeaderName.USER_AGENT,
                    userAgent == null || userAgent.isBlank() ? USER_AGENT_MARK : userAgent + " " + USER_AGENT_MARK);
            return request;
        }
    }
}
