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
    lock {
        acceptedCertificatePath = certPem;
    }
    clientCertificateFiles = [pkcs12, pem];
    return [pkcs12, pem];
}

// The password-less PKCS#12 file, created on first use.
string? passwordlessPkcs12File = ();

// The client key and certificate in a PKCS#12 file with an empty password, as Azure Key Vault exports them. Written
// through the JDK because keytool needs a password of at least six characters.
function passwordlessPkcs12() returns string|error {
    string? existing = passwordlessPkcs12File;
    if existing is string {
        return existing;
    }
    [string, string] [pkcs12, _] = check clientCertificates();
    handle password = toCharArray(java:fromString(CERTIFICATE_PASSWORD_VALUE));
    handle original = check keyStoreGetInstance(java:fromString("PKCS12"));
    handle input = check newFileInputStream(java:fromString(pkcs12));
    check keyStoreLoad(original, input, password);
    check closeStream(input);
    handle key = check keyStoreGetKey(original, java:fromString("client"), password);
    handle chain = check keyStoreGetCertificateChain(original, java:fromString("client"));

    handle empty = toCharArray(java:fromString(""));
    handle target = check keyStoreGetInstance(java:fromString("PKCS12"));
    check keyStoreLoad(target, java:createNull(), java:createNull());
    check keyStoreSetKeyEntry(target, java:fromString("client"), key, empty, chain);
    string path = check file:joinPath(mockCertDir, "client-no-password.p12");
    handle output = check newFileOutputStream(java:fromString(path));
    check keyStoreStore(target, output, empty);
    check closeOutputStream(output);
    passwordlessPkcs12File = path;
    return path;
}

// The JOSE header of the client assertion in the last token request.
function lastAssertionHeader() returns map<json>|error {
    string assertion = (check lastEntraRequest()).clientAssertion ?: "";
    return decodeJwtPart(re `\.`.split(assertion)[0]);
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
    test:assertFalse((check lastAssertionHeader()).hasKey("x5c"), "no certificate chain unless asked for");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testSendCertificateChain() returns error? {
    [string, string] [_, pem] = check clientCertificates();
    ClientCertificateConfig config = certificateConfig(pem, ());
    config.sendCertificateChain = true;
    TokenCredential credential = check createCredential(config, mockOptions());
    check assertCertificateToken(credential, "api://certificate-chain/.default");
    test:assertTrue((check lastAssertionHeader())["x5c"] is json[], "the assertion carries the certificate chain");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPemWithBagAttributesToken() returns error? {
    // `openssl pkcs12 -nodes` writes "Bag Attributes" lines before each block.
    [string, string] [_, pem] = check clientCertificates();
    string exported = check file:joinPath(mockCertDir, "client-bag-attributes.pem");
    check io:fileWriteString(exported, "Bag Attributes\n    friendlyName: client\n    localKeyID: 01 02 03\n"
        + check io:fileReadString(pem));
    TokenCredential credential = check createCredential(certificateConfig(exported, ()), mockOptions());
    check assertCertificateToken(credential, "api://certificate-bag-attributes/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPemWithBomToken() returns error? {
    [string, string] [_, pem] = check clientCertificates();
    string withBom = check file:joinPath(mockCertDir, "client-bom.pem");
    check io:fileWriteString(withBom, "\u{FEFF}" + check io:fileReadString(pem));
    TokenCredential credential = check createCredential(certificateConfig(withBom, ()), mockOptions());
    check assertCertificateToken(credential, "api://certificate-bom/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testTamperedAssertionSignatureIsRejected() returns error? {
    [string, string] [_, pem] = check clientCertificates();
    TokenCredential credential = check createCredential(certificateConfig(pem, ()), mockOptions());
    check assertCertificateToken(credential, "api://certificate-signature/.default");
    string assertion = (check lastEntraRequest()).clientAssertion ?: "";
    test:assertEquals(certificateAssertionProblem(assertion), ());
    // Change one character in the middle of the signature.
    int index = (assertion.lastIndexOf(".") ?: 0) + 10;
    string changed = assertion.substring(index, index + 1) == "A" ? "B" : "A";
    string tampered = assertion.substring(0, index) + changed + assertion.substring(index + 1);
    test:assertEquals(certificateAssertionProblem(tampered), "the client assertion signature is not valid");
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
function testPasswordlessPkcs12Token() returns error? {
    string pkcs12 = check passwordlessPkcs12();
    TokenCredential credential = check createCredential(certificateConfig(pkcs12, ()), mockOptions());
    check assertCertificateToken(credential, "api://certificate-no-password/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPasswordlessPkcs12WithEmptyPasswordToken() returns error? {
    string pkcs12 = check passwordlessPkcs12();
    TokenCredential credential = check createCredential(certificateConfig(pkcs12, ""), mockOptions());
    check assertCertificateToken(credential, "api://certificate-empty-password/.default");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPkcs12WithoutItsPasswordFails() returns error? {
    [string, string] [pkcs12, _] = check clientCertificates();
    int requests = entraRequestCount();
    TokenCredential credential = check createCredential(certificateConfig(pkcs12, ()), mockOptions());
    AccessToken|Error token = credential.getToken(["api://certificate-missing-password/.default"]);
    test:assertTrue(token is Error, "a password-protected PKCS#12 file needs its password");
    test:assertEquals(entraRequestCount(), requests, "no token request without a usable certificate");
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testPemWithPasswordIsRejectedAtCreation() returns error? {
    [string, string] [_, pem] = check clientCertificates();
    TokenCredential|Error credential = createCredential(certificateConfig(pem, CERTIFICATE_PASSWORD_VALUE),
        mockOptions());
    if credential !is Error {
        return error("a PEM file with a password must be rejected");
    }
    test:assertTrue(credential.message().includes("takes no 'certificatePassword'"), credential.message());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testUnknownCertificateFormatIsRejectedAtCreation() returns error? {
    string text = check file:joinPath(mockCertDir, "not-a-certificate.txt");
    check io:fileWriteString(text, "not a certificate");
    TokenCredential|Error credential = createCredential(certificateConfig(text, ()), mockOptions());
    if credential !is Error {
        return error("a file that is neither PEM nor PKCS#12 must be rejected");
    }
    test:assertTrue(credential.message().includes("neither a PEM nor a PKCS#12"), credential.message());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testMissingCertificateFileIsRejectedAtCreation() returns error? {
    string missing = check file:joinPath(mockCertDir, "no-such-certificate.pem");
    TokenCredential|Error credential = createCredential(certificateConfig(missing, ()), mockOptions());
    if credential !is Error {
        return error("a missing certificate file must be rejected");
    }
    test:assertTrue(credential.message().includes("'certificatePath' is not a file"), credential.message());
}

@test:Config {groups: [ENTRA_MOCK_GROUP]}
function testMissingPkcs12FileIsRejectedAtCreation() returns error? {
    string missing = check file:joinPath(mockCertDir, "no-such-certificate.p12");
    TokenCredential|Error credential = createCredential(certificateConfig(missing, CERTIFICATE_PASSWORD_VALUE),
        mockOptions());
    if credential !is Error {
        return error("a missing PKCS#12 file must be rejected when the credential is created");
    }
    test:assertTrue(credential.message().includes("'certificatePath' is not a file"), credential.message());
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

function keyStoreGetCertificateChain(handle keyStore, handle alias) returns handle|error = @java:Method {
    'class: "java.security.KeyStore",
    name: "getCertificateChain",
    paramTypes: ["java.lang.String"]
} external;

function keyStoreSetKeyEntry(handle keyStore, handle alias, handle key, handle password, handle chain)
        returns error? = @java:Method {
    'class: "java.security.KeyStore",
    name: "setKeyEntry",
    paramTypes: ["java.lang.String", "java.security.Key", {'class: "char", dimensions: 1},
        {'class: "java.security.cert.Certificate", dimensions: 1}]
} external;

function keyStoreStore(handle keyStore, handle output, handle password) returns error? = @java:Method {
    'class: "java.security.KeyStore",
    name: "store",
    paramTypes: ["java.io.OutputStream", {'class: "char", dimensions: 1}]
} external;

function newFileOutputStream(handle path) returns handle|error = @java:Constructor {
    'class: "java.io.FileOutputStream",
    paramTypes: ["java.lang.String"]
} external;

function closeOutputStream(handle output) returns error? = @java:Method {
    'class: "java.io.FileOutputStream",
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
