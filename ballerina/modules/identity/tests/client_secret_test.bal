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

import ballerina/os;
import ballerina/test;

function clientSecretConfig(string clientSecret = CLIENT_SECRET_VALUE) returns ClientSecretConfig => {
    'type: "clientSecret",
    tenantId: MOCK_TENANT,
    clientId: CLIENT_SECRET_APP,
    clientSecret
};

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testClientSecretToken() returns error? {
    TokenCredential credential = check createCredential(clientSecretConfig(), mockOptions());
    AccessToken token = check credential.getToken(["api://mock-resource/.default"]);
    test:assertEquals(token.token, "entra-token-for-" + CLIENT_SECRET_APP);
    test:assertTrue(token.expiresOn > nowSeconds() + 3000, "expiry comes from expires_in");

    EntraRequest request = check lastEntraRequest();
    test:assertEquals(request.path, string `/${MOCK_TENANT}/oauth2/v2.0/token`);
    test:assertEquals(request.grantType, "client_credentials");
    test:assertEquals(request.clientId, CLIENT_SECRET_APP);
    // MSAL adds the OpenID scopes to the requested one.
    test:assertTrue((request.scope ?: "").includes("api://mock-resource/.default"), request.scope ?: "");
    test:assertEquals(request.clientSecret, CLIENT_SECRET_VALUE);
    // The marker proves MSAL used our HTTP client (our trust store and proxy settings) for the token request.
    test:assertTrue(request.userAgent.includes(USER_AGENT_MARKER), "User-Agent: " + request.userAgent);
}

@test:Config {groups: [ENTRA_MOCK_GROUP], dependsOn: [testClientSecretToken]}
function testClientSecretTokenIsCached() returns error? {
    TokenCredential credential = check createCredential(clientSecretConfig(), mockOptions());
    _ = check credential.getToken(["api://cached/.default"]);
    int requests = entraRequestCount();
    AccessToken again = check credential.getToken(["api://cached/.default"]);
    test:assertEquals(entraRequestCount(), requests, "a valid token is served from the cache");
    test:assertEquals(again.token, "entra-token-for-" + CLIENT_SECRET_APP);
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testWrongClientSecretIsAnAuthenticationError() returns error? {
    string wrongSecret = "do-not-leak-wrong-secret-1b";
    TokenCredential credential = check createCredential(clientSecretConfig(wrongSecret), mockOptions());
    AccessToken|Error token = credential.getToken(["api://mock-resource/.default"]);
    if token !is AuthenticationError {
        return error("a rejected secret must be an AuthenticationError, got: "
            + (token is Error ? token.message() : "a token"));
    }
    test:assertEquals(token.detail().code, "AADSTS7000215");
    test:assertEquals(token.detail().credential, "clientSecret");
    // The mock echoes the secret it received; the error must not repeat it.
    test:assertFalse(token.toString().includes(wrongSecret), token.toString());
    test:assertFalse(token.toString().includes(CLIENT_SECRET_VALUE), token.toString());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testClientSecretNeedsTheCa() returns error? {
    check os:unsetEnv("SSL_CERT_FILE");
    CredentialOptions options = mockOptions();
    _ = options.removeIfHasKey("secureSocket");
    TokenCredential credential = check createCredential(clientSecretConfig(), options);
    AccessToken|Error token = credential.getToken(["api://no-ca/.default"]);
    if token !is Error {
        return error("the mock's certificate must not be trusted without its CA");
    }
    test:assertTrue(token.message().toLowerAscii().includes("certification path"), token.message());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testClientSecretTrustsSslCertFile() returns error? {
    CredentialOptions options = mockOptions();
    _ = options.removeIfHasKey("secureSocket");
    check os:setEnv("SSL_CERT_FILE", mockCaBundle);
    TokenCredential|Error credential = createCredential(clientSecretConfig(), options);
    check os:unsetEnv("SSL_CERT_FILE");
    AccessToken token = check (check credential).getToken(["api://ssl-cert-file/.default"]);
    test:assertEquals(token.token, "entra-token-for-" + CLIENT_SECRET_APP);
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testRemoteTokenRequestsGoThroughTheProxy() returns error? {
    // `.invalid` never resolves, so a request that skipped the proxy would fail on DNS instead of at the proxy.
    CredentialOptions options = mockOptions();
    options.authorityHost = "https://login.example.invalid/";
    TokenCredential credential = check createCredential(clientSecretConfig(), options);
    int requests = entraRequestCount();
    AccessToken|Error token = credential.getToken(["api://remote/.default"]);
    if token !is Error {
        return error("a token request through a dead proxy must fail");
    }
    string described = token.toString();
    test:assertTrue(described.includes("ConnectException") || described.toLowerAscii().includes("connection refused"),
        described);
    test:assertFalse(described.toLowerAscii().includes("unresolved") || described.includes("UnknownHost"),
        described);
    test:assertEquals(entraRequestCount(), requests);
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testBlankClientSecretIsRejectedAtCreation() {
    TokenCredential|Error credential = createCredential(clientSecretConfig(" "), mockOptions());
    test:assertTrue(credential is Error, "a blank client secret must be rejected");
}
