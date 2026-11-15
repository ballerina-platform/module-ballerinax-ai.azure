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
import ballerina/os;

# Environment variable naming a PEM bundle of extra trusted CA certificates, e.g. the CA of a TLS-inspecting proxy.
const SSL_CERT_FILE = "SSL_CERT_FILE";

# Creates a credential from its configuration.
#
# ```ballerina
# identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
# ```
#
# + config - The credential configuration; its `type` field selects the credential
# + options - Options for the credential's token requests
# + return - The credential, or an `Error` if the configuration is invalid
public isolated function createCredential(CredentialConfig config, *CredentialOptions options)
        returns TokenCredential|Error {
    string credentialType = config.'type;
    NativeTransport transport = check toNativeTransport(credentialType, options);
    return new AzureIdentityCredential(credentialType, config, transport);
}

isolated function toNativeTransport(string credentialType, CredentialOptions options) returns NativeTransport|Error {
    NativeTransport transport = {timeout: options.timeout, authorityHost: options.authorityHost};
    string sslCertFile = os:getEnv(SSL_CERT_FILE);
    if sslCertFile != "" {
        transport.trustedCertFiles.push(sslCertFile);
    }

    http:ClientSecureSocket? secureSocket = options.secureSocket;
    if secureSocket is http:ClientSecureSocket {
        check applySecureSocket(credentialType, secureSocket, transport);
    }

    http:ProxyConfig? proxy = options.proxy;
    if proxy is http:ProxyConfig && proxy.host != "" {
        // The JDK HTTP client ignores SOCKS proxies and would connect directly, so they are rejected instead.
        http:ProxyProtocol? protocol = proxy.protocol;
        if protocol is http:SOCKS4|http:SOCKS5 {
            return error Error(string `a '${protocol}' proxy is not supported for token requests; use an HTTP proxy`,
                credential = credentialType);
        }
        // The JDK HTTP client won't send Basic credentials to a proxy for HTTPS tunnels unless the JVM allows it,
        // so a proxy login fails up front instead of as a 407 at the first token request.
        if proxy.userName != "" && isBasicProxyTunnelingDisabled() {
            return error Error("proxy authentication for token requests needs Basic authentication for HTTPS " +
                "tunnels, which the JDK disables by default; start the JVM with " +
                "'-Djdk.http.auth.tunneling.disabledSchemes=' to allow it", credential = credentialType);
        }
        transport.proxy = {host: proxy.host, port: proxy.port, userName: proxy.userName, password: proxy.password};
    }
    return transport;
}

# Maps `http:ClientSecureSocket` to the token client. Options that can't be honoured for token requests are
# rejected rather than silently ignored.
#
# + credentialType - The credential's `type`, recorded in the error detail
# + secureSocket - The TLS settings to apply
# + transport - The token client settings, updated in place
# + return - An `Error` if an option is not supported for token requests
isolated function applySecureSocket(string credentialType, http:ClientSecureSocket secureSocket,
        NativeTransport transport) returns Error? {
    if !secureSocket.enable {
        // Token requests carry secrets and tokens, so their TLS is always verified.
        return unsupportedTlsOption(credentialType, "'enable = false'");
    }
    if secureSocket.key !is () {
        return unsupportedTlsOption(credentialType, "a client certificate ('key')");
    }
    if !secureSocket.verifyHostName {
        return unsupportedTlsOption(credentialType, "'verifyHostName = false'");
    }
    if secureSocket.certValidation !is () {
        return unsupportedTlsOption(credentialType, "'certValidation'");
    }
    if secureSocket.serverName !is () {
        return unsupportedTlsOption(credentialType, "'serverName'");
    }

    var cert = secureSocket.cert;
    if cert is string {
        transport.trustedCertFiles.push(cert);
    } else if cert !is () {
        transport.trustStores.push({path: cert.path, password: cert.password});
    }
    var protocol = secureSocket.protocol;
    if protocol !is () && protocol.name == http:DTLS {
        return unsupportedTlsOption(credentialType, "the DTLS protocol");
    }
    if protocol !is () {
        // Already JSSE protocol names, e.g. `TLSv1.3`
        transport.protocols = protocol.versions.clone();
    }
    string[]? ciphers = secureSocket.ciphers;
    if ciphers is string[] {
        transport.ciphers = ciphers;
    }
}

isolated function isBasicProxyTunnelingDisabled() returns boolean = @java:Method {
    'class: NATIVE_CLASS,
    name: "isBasicProxyTunnelingDisabled"
} external;

isolated function unsupportedTlsOption(string credentialType, string option) returns Error =>
    error Error(string `${option} in 'secureSocket' is not supported for token requests`,
        credential = credentialType);
