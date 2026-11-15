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

import ballerina/file;
import ballerina/io;
import ballerina/os;
import ballerina/test;

function federatedTokenFile(string name, string content) returns string|error {
    string path = check file:joinPath(mockCertDir, name);
    check io:fileWriteString(path, content);
    return path;
}

function workloadIdentityConfig(string tokenFilePath) returns WorkloadIdentityConfig => {
    'type: "workloadIdentity",
    tenantId: MOCK_TENANT,
    clientId: WORKLOAD_APP,
    tokenFilePath
};

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testWorkloadIdentityToken() returns error? {
    string tokenFile = check federatedTokenFile("federated-token", FEDERATED_TOKEN_VALUE);
    TokenCredential credential = check createCredential(workloadIdentityConfig(tokenFile), mockOptions());
    AccessToken token = check credential.getToken(["api://workload/.default"]);
    test:assertEquals(token.token, "entra-token-for-" + WORKLOAD_APP);

    EntraRequest request = check lastEntraRequest();
    test:assertEquals(request.path, string `/${MOCK_TENANT}/oauth2/v2.0/token`);
    test:assertEquals(request.grantType, "client_credentials");
    test:assertEquals(request.clientId, WORKLOAD_APP);
    test:assertEquals(request.clientAssertionType, JWT_BEARER_ASSERTION);
    test:assertEquals(request.clientAssertion, FEDERATED_TOKEN_VALUE, "the federated token is the client assertion");
    test:assertEquals(request.clientSecret, ());
    test:assertTrue(request.userAgent.includes(USER_AGENT_MARKER), "User-Agent: " + request.userAgent);
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testRejectedFederatedTokenIsNotInTheError() returns error? {
    string rejected = "do-not-leak-rejected-federated-token-1b";
    string tokenFile = check federatedTokenFile("rejected-federated-token", rejected);
    TokenCredential credential = check createCredential(workloadIdentityConfig(tokenFile), mockOptions());
    AccessToken|Error token = credential.getToken(["api://workload-rejected/.default"]);
    if token !is AuthenticationError {
        return error("a rejected federated token must be an AuthenticationError, got: "
            + (token is Error ? token.message() : "a token"));
    }
    test:assertEquals(token.detail().code, "AADSTS700213");
    // The mock echoes the assertion it received; the error must not repeat it.
    test:assertFalse(token.toString().includes(rejected), token.toString());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testMissingFederatedTokenFile() returns error? {
    string missing = check file:joinPath(mockCertDir, "no-such-token-file");
    TokenCredential credential = check createCredential(workloadIdentityConfig(missing), mockOptions());
    int requests = entraRequestCount();
    AccessToken|Error token = credential.getToken(["api://workload-missing/.default"]);
    test:assertTrue(token is Error, "a missing token file must fail");
    test:assertEquals(entraRequestCount(), requests, "no token request without a federated token");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testUnconfiguredWorkloadIdentityIsRejectedAtCreation() {
    if os:getEnv("AZURE_FEDERATED_TOKEN_FILE") != "" || os:getEnv("AZURE_CLIENT_ID") != ""
            || os:getEnv("AZURE_TENANT_ID") != "" {
        // The environment configures workload identity here, so the defaults are not empty.
        return;
    }
    TokenCredential|Error credential = createCredential({'type: "workloadIdentity"}, mockOptions());
    if credential !is Error {
        test:assertFail("a workload identity without tenant, client and token file must be rejected");
    }
    test:assertTrue(credential.message().includes("Tenant ID"), credential.message());
}
