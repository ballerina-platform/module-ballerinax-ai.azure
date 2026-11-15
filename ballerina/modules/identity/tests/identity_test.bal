// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
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

import ballerina/http;
import ballerina/jballerina.java;
import ballerina/test;

@test:Config
function testCreateDefaultCredential() {
    TokenCredential|Error credential = createCredential({'type: "default"});
    test:assertTrue(credential is TokenCredential, "default credential should be created without any network call");
}

@test:Config
function testCreateDefaultCredentialWithOptions() {
    TokenCredential|Error credential = createCredential({
        'type: "default",
        sources: "prod",
        managedIdentityClientId: "00000000-0000-0000-0000-000000000001",
        tenantId: "00000000-0000-0000-0000-000000000002"
    }, timeout = 5);
    test:assertTrue(credential is TokenCredential);
}

@test:Config
function testCreateManagedIdentityCredential() {
    test:assertTrue(createCredential({'type: "managedIdentity"}) is TokenCredential);
    test:assertTrue(createCredential({'type: "managedIdentity", clientId: "00000000-0000-0000-0000-000000000003"})
        is TokenCredential);
}

@test:Config
function testUnsupportedTlsOptionsAreRejected() {
    TokenCredential|Error noHostCheck = createCredential({'type: "managedIdentity"},
        secureSocket = {verifyHostName: false});
    if noHostCheck !is Error {
        test:assertFail("verifyHostName = false should be rejected");
    }
    test:assertEquals(noHostCheck.message(),
        "'verifyHostName = false' in 'secureSocket' is not supported for token requests");

    TokenCredential|Error withKey = createCredential({'type: "managedIdentity"},
        secureSocket = {key: {path: "/nonexistent/client.p12", password: "pw"}});
    if withKey !is Error {
        test:assertFail("a client key should be rejected");
    }
    test:assertTrue(withKey.message().startsWith("a client certificate ('key')"));
}

@test:Config
function testTlsProtocolVersionsArePassedThroughUnchanged() returns error? {
    // `http:ClientSecureSocket` already uses JSSE names, so they must reach the token client as they are.
    CredentialOptions options = {secureSocket: {protocol: {name: http:TLS, versions: ["TLSv1.2"]}}};
    NativeTransport transport = check toNativeTransport("managedIdentity", options);
    test:assertEquals(transport.protocols, ["TLSv1.2"]);
    test:assertTrue(createCredential({'type: "managedIdentity"}, options) is TokenCredential);
}

@test:Config
function testHttpProxyIsPassedToTheTokenClient() returns error? {
    http:ProxyConfig[] proxies = [
        {host: "proxy.example", port: 3128},
        {host: "proxy.example", port: 3128, protocol: http:HTTP}
    ];
    foreach http:ProxyConfig proxy in proxies {
        NativeTransport transport = check toNativeTransport("managedIdentity", {proxy});
        test:assertEquals(transport.proxy, {host: "proxy.example", port: 3128, userName: "", password: ""});
    }
}

@test:Config
function testProxyLoginNeedsBasicTunneling() returns error? {
    http:ProxyConfig proxy = {host: "proxy.example", port: 3128, userName: "user", password: "do-not-leak-proxy-pw"};
    handle property = java:fromString(TUNNELING_PROPERTY);
    if java:isNull(getSystemProperty(property)) {
        TokenCredential|Error credential = createCredential({'type: "managedIdentity"}, proxy = proxy);
        if credential !is Error {
            test:assertFail("a proxy login must be rejected while the JDK disables Basic for HTTPS tunnels");
        }
        test:assertTrue(credential.message().includes("-Djdk.http.auth.tunneling.disabledSchemes="),
            credential.message());
        test:assertFalse(credential.toString().includes("do-not-leak-proxy-pw"), "the proxy password must not leak");
    }

    // With the JVM option given (an empty list of disabled schemes), the login reaches the token client.
    _ = setSystemProperty(property, java:fromString(""));
    NativeTransport|Error transport = toNativeTransport("managedIdentity", {proxy});
    _ = clearSystemProperty(property);
    test:assertEquals((check transport).proxy,
        {host: "proxy.example", port: 3128, userName: "user", password: "do-not-leak-proxy-pw"});
}

@test:Config
function testDisabledTlsIsRejected() {
    TokenCredential|Error credential = createCredential({'type: "default"}, secureSocket = {enable: false});
    if credential !is Error {
        test:assertFail("token requests must always verify TLS");
    }
    test:assertEquals(credential.message(), "'enable = false' in 'secureSocket' is not supported for token requests");
}

@test:Config
function testDtlsIsRejected() {
    TokenCredential|Error credential = createCredential({'type: "managedIdentity"},
        secureSocket = {protocol: {name: http:DTLS, versions: ["1.2"]}});
    if credential !is Error {
        test:assertFail("DTLS can't be used for HTTPS token requests");
    }
    test:assertEquals(credential.message(), "the DTLS protocol in 'secureSocket' is not supported for token requests");
}

const TUNNELING_PROPERTY = "jdk.http.auth.tunneling.disabledSchemes";

function getSystemProperty(handle name) returns handle = @java:Method {
    'class: "java.lang.System",
    name: "getProperty",
    paramTypes: ["java.lang.String"]
} external;

function setSystemProperty(handle name, handle value) returns handle = @java:Method {
    'class: "java.lang.System",
    name: "setProperty",
    paramTypes: ["java.lang.String", "java.lang.String"]
} external;

function clearSystemProperty(handle name) returns handle = @java:Method {
    'class: "java.lang.System",
    name: "clearProperty",
    paramTypes: ["java.lang.String"]
} external;

@test:Config
function testSocksProxyIsRejected() {
    http:ProxyProtocol[] socksProtocols = [http:SOCKS4, http:SOCKS5];
    foreach http:ProxyProtocol protocol in socksProtocols {
        TokenCredential|Error credential = createCredential({'type: "managedIdentity"},
            proxy = {host: "proxy.example", port: 1080, userName: "user", password: "proxy-s3cr3t", protocol});
        if credential !is Error {
            test:assertFail(string `a ${protocol} proxy should be rejected`);
        }
        test:assertEquals(credential.message(),
            string `a '${protocol}' proxy is not supported for token requests; use an HTTP proxy`);
        test:assertEquals(credential.detail().credential, "managedIdentity");
        test:assertFalse(credential.toString().includes("proxy-s3cr3t"), "the proxy password must not leak");
    }
}

@test:Config
function testUnreadableTrustedCertificateFile() {
    TokenCredential|Error credential = createCredential({'type: "managedIdentity"},
        secureSocket = {cert: "/nonexistent/ca-bundle.pem"});
    if credential !is Error {
        test:assertFail("an unreadable certificate file should fail at createCredential");
    }
    test:assertTrue(credential.message().includes("could not read the trusted certificate file"),
        credential.message());
    test:assertEquals(credential.detail().credential, "managedIdentity");
}

@test:Config
function testGetTokenRequiresScopes() returns error? {
    TokenCredential credential = check createCredential({'type: "managedIdentity"});
    AccessToken|Error token = credential.getToken([]);
    if token !is Error {
        test:assertFail("an empty scope list should be rejected");
    }
    test:assertEquals(token.message(), "at least one scope is required");
}
