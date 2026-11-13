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

@test:Config {
    dataProvider: notImplementedConfigs
}
function testNotImplementedCredentialTypes(string credentialType, CredentialConfig config) {
    TokenCredential|Error credential = createCredential(config);
    if credential !is Error {
        test:assertFail(string `'${credentialType}' should not be implemented yet`);
    }
    test:assertEquals(credential.message(), string `credential type '${credentialType}' is not implemented yet`);
    test:assertEquals(credential.detail().credential, credentialType);
}

function notImplementedConfigs() returns map<[string, CredentialConfig]> => {
    "workloadIdentity": ["workloadIdentity", {'type: "workloadIdentity"}],
    "clientSecret": ["clientSecret", {'type: "clientSecret", tenantId: "t", clientId: "c", clientSecret: "s3cr3t-value"}],
    "azureCli": ["azureCli", {'type: "azureCli"}],
    "staticToken": ["staticToken", {'type: "staticToken", token: "static-token-value"}]
};

@test:Config
function testNotImplementedErrorHasNoSecrets() {
    TokenCredential|Error credential = createCredential(
        {'type: "clientSecret", tenantId: "t", clientId: "c", clientSecret: "s3cr3t-value"});
    if credential !is Error {
        test:assertFail("clientSecret is not implemented yet");
    }
    test:assertFalse(credential.toString().includes("s3cr3t-value"), "the client secret must not leak into errors");
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
