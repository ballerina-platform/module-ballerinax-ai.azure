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

import ballerina/crypto;
import ballerina/file;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/lang.array;
import ballerina/test;

// The client certificate is generated at test time: a PKCS#12 file from keytool, and a PEM file with the same
// private key (PKCS#8, read through the JDK because keytool can't export private keys) and certificate.

// [pkcs12Path, pemPath], created on first use.
[string, string]? clientCertificateFiles = ();

function clientCertificates() returns [string, string]|error {
    [string, string]? files = clientCertificateFiles;
    if files is [string, string] {
        return files;
    }
    string pkcs12 = check file:joinPath(mockCertDir, "client.p12");
    string certPem = check file:joinPath(mockCertDir, "client-cert.pem");
    string pem = check file:joinPath(mockCertDir, "client.pem");
    string[] store = ["-storetype", "PKCS12", "-storepass", CERTIFICATE_PASSWORD_VALUE];
    check keytool(["-genkeypair", "-alias", "client", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=" + CERTIFICATE_APP, "-keystore", pkcs12, ...store]);
    check keytool(["-exportcert", "-rfc", "-alias", "client", "-keystore", pkcs12, "-file", certPem, ...store]);
    string certificate = check io:fileReadString(certPem);
    check io:fileWriteString(pem, check privateKeyPem(pkcs12, "client", CERTIFICATE_PASSWORD_VALUE) + certificate);

    byte[] der = check certificateDer(certificate);
    final readonly & [string, string] thumbprints = [base64Url(crypto:hashSha1(der)),
        base64Url(crypto:hashSha256(der))];
    lock {
        acceptedThumbprints = thumbprints;
    }
    clientCertificateFiles = [pkcs12, pem];
    return [pkcs12, pem];
}

function certificateConfig(string certificatePath, string? certificatePassword) returns ClientCertificateConfig =>
    certificatePassword is string
        ? {'type: "clientCertificate", tenantId: MOCK_TENANT, clientId: CERTIFICATE_APP, certificatePath,
            certificatePassword}
        : {'type: "clientCertificate", tenantId: MOCK_TENANT, clientId: CERTIFICATE_APP, certificatePath};

function assertCertificateToken(TokenCredential credential, string scope) returns error? {
    AccessToken token = check credential.getToken([scope]);
    test:assertEquals(token.token, "entra-token-for-" + CERTIFICATE_APP);
    EntraRequest request = check lastEntraRequest();
    test:assertEquals(request.clientId, CERTIFICATE_APP);
    test:assertEquals(request.clientAssertionType, JWT_BEARER_ASSERTION);
    test:assertEquals(request.clientSecret, ());
    test:assertTrue(request.userAgent.includes(USER_AGENT_MARKER), "User-Agent: " + request.userAgent);
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testClientCertificatePemToken() returns error? {
    [string, string] [_, pem] = check clientCertificates();
    TokenCredential credential = check createCredential(certificateConfig(pem, ()), mockOptions());
    check assertCertificateToken(credential, "api://certificate-pem/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testClientCertificatePkcs12Token() returns error? {
    [string, string] [pkcs12, _] = check clientCertificates();
    TokenCredential credential = check createCredential(certificateConfig(pkcs12, CERTIFICATE_PASSWORD_VALUE),
        mockOptions());
    check assertCertificateToken(credential, "api://certificate-pkcs12/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testWrongCertificatePasswordIsNotInTheError() returns error? {
    [string, string] [pkcs12, _] = check clientCertificates();
    string wrongPassword = "do-not-leak-wrong-cert-password-1b";
    int requests = entraRequestCount();
    TokenCredential|Error credential = createCredential(certificateConfig(pkcs12, wrongPassword), mockOptions());
    Error err;
    if credential is Error {
        err = credential;
    } else {
        AccessToken|Error token = credential.getToken(["api://certificate-wrong-password/.default"]);
        if token !is Error {
            return error("a wrong certificate password must fail");
        }
        err = token;
    }
    test:assertFalse(err.toString().includes(wrongPassword), err.toString());
    test:assertEquals(entraRequestCount(), requests, "no token request without a usable certificate");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPkcs12WithoutPasswordIsRejectedAtCreation() returns error? {
    [string, string] [pkcs12, _] = check clientCertificates();
    TokenCredential|Error credential = createCredential(certificateConfig(pkcs12, ()), mockOptions());
    if credential !is Error {
        return error("a PKCS#12 file without a password must be rejected");
    }
    test:assertTrue(credential.message().includes("certificatePassword"), credential.message());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testMissingCertificateFileIsRejectedAtCreation() returns error? {
    string missing = check file:joinPath(mockCertDir, "no-such-certificate.pem");
    TokenCredential|Error credential = createCredential(certificateConfig(missing, ()), mockOptions());
    test:assertTrue(credential is Error, "a missing certificate file must be rejected");
}

// ----- Helpers -----

function certificateDer(string pem) returns byte[]|error {
    string body = re `-----(BEGIN|END) CERTIFICATE-----|\s`.replaceAll(pem, "");
    return array:fromBase64(body);
}

function base64Url(byte[] bytes) returns string {
    string encoded = re `=+$`.replaceAll(bytes.toBase64(), "");
    return re `/`.replaceAll(re `\+`.replaceAll(encoded, "-"), "_");
}

// The private key of a PKCS#12 entry as a PKCS#8 PEM block.
function privateKeyPem(string pkcs12Path, string alias, string password) returns string|error {
    handle keyStore = check keyStoreGetInstance(java:fromString("PKCS12"));
    handle input = check newFileInputStream(java:fromString(pkcs12Path));
    check keyStoreLoad(keyStore, input, toCharArray(java:fromString(password)));
    check closeStream(input);
    handle key = check keyStoreGetKey(keyStore, java:fromString(alias), toCharArray(java:fromString(password)));
    string encoded = java:toString(encodeToString(base64Encoder(), keyGetEncoded(key))) ?: "";
    string body = "";
    int index = 0;
    while index < encoded.length() {
        int end = int:min(index + 64, encoded.length());
        body += encoded.substring(index, end) + "\n";
        index = end;
    }
    return "-----BEGIN PRIVATE KEY-----\n" + body + "-----END PRIVATE KEY-----\n";
}

function keyStoreGetInstance(handle keyStoreType) returns handle|error = @java:Method {
    'class: "java.security.KeyStore",
    name: "getInstance",
    paramTypes: ["java.lang.String"]
} external;

function newFileInputStream(handle path) returns handle|error = @java:Constructor {
    'class: "java.io.FileInputStream",
    paramTypes: ["java.lang.String"]
} external;

function keyStoreLoad(handle keyStore, handle input, handle password) returns error? = @java:Method {
    'class: "java.security.KeyStore",
    name: "load",
    paramTypes: ["java.io.InputStream", {'class: "char", dimensions: 1}]
} external;

function closeStream(handle input) returns error? = @java:Method {
    'class: "java.io.FileInputStream",
    name: "close"
} external;

function keyStoreGetKey(handle keyStore, handle alias, handle password) returns handle|error = @java:Method {
    'class: "java.security.KeyStore",
    name: "getKey",
    paramTypes: ["java.lang.String", {'class: "char", dimensions: 1}]
} external;

function toCharArray(handle value) returns handle = @java:Method {
    'class: "java.lang.String",
    name: "toCharArray"
} external;

function keyGetEncoded(handle key) returns handle = @java:Method {
    'class: "java.security.Key",
    name: "getEncoded"
} external;

function base64Encoder() returns handle = @java:Method {
    'class: "java.util.Base64",
    name: "getEncoder"
} external;

function encodeToString(handle encoder, handle bytes) returns handle = @java:Method {
    'class: "java.util.Base64$Encoder",
    name: "encodeToString",
    paramTypes: [{'class: "byte", dimensions: 1}]
} external;
