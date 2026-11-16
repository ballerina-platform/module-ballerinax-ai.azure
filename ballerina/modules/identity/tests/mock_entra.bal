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
import ballerina/http;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/lang.array;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;
import ballerina/time;

// A local HTTPS mock of the Microsoft Entra ID token endpoint (`{authority}/{tenant}/oauth2/v2.0/token`). Its
// certificate is signed by a throwaway CA generated here at test time, standing in for a TLS-inspecting proxy.
//
// Every credential in these tests also gets a proxy on a port where nothing listens. Local hosts bypass the proxy,
// so the mock is reached directly, while any request that would leave the machine fails at the proxy.

const ENTRA_MOCK_GROUP = "entra-mock";
// Tests that need AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_CLIENT_SECRET in the real process environment (as
// `testCredentialMocks` sets them), because azure-identity doesn't see variables set at run time.
const ENTRA_ENV_MOCK_GROUP = "entra-env-mock";
const ENTRA_MOCK_PORT = 8095;
const ENTRA_MOCK_AUTHORITY = "https://localhost:8095/";
const DEAD_PROXY_PORT = 8097;
const MOCK_TENANT = "mock-tenant";
const USER_AGENT_MARKER = "ballerinax-ai.azure-identity";
const MOCK_KEYSTORE_PASSWORD = "test-only-password";
const JWT_BEARER_ASSERTION = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";

// Fixed test values. The Gradle task that runs this group fails if any of them shows up in the output. The secrets
// have surrounding spaces, which must reach the token request (or the PKCS#12 file) unchanged.
const CLIENT_SECRET_VALUE = " do-not-leak-client-secret-1b ";
const CLIENT_SECRET_APP = "secret-app";
const FEDERATED_TOKEN_VALUE = "do-not-leak-federated-token-1b";
const WORKLOAD_APP = "workload-app";
const CERTIFICATE_APP = "cert-app";
const CERTIFICATE_PASSWORD_VALUE = " do-not-leak-cert-password-1b ";
// The application and secret that `testCredentialMocks` puts in the environment for ENTRA_ENV_MOCK_GROUP.
const ENV_SECRET_APP = "env-secret-app";
const ENV_CLIENT_SECRET_VALUE = "do-not-leak-env-client-secret-1b";
// An application for which the mock echoes a JWT that contains the client secret it got, and the parts of that JWT.
const JWT_ECHO_APP = "jwt-echo-app";
const JWT_ECHO_SECRET = "do-not-leak-jwt-echo-secret-1b";
const JWT_ECHO_HEADER = "eyJdo-not-leak-jwt-echo-header-1b";
const JWT_ECHO_PAYLOAD = "do-not-leak-jwt-echo-payload-1b-";
const JWT_ECHO_SIGNATURE = "do-not-leak-jwt-echo-signature-1b";
// Applications for which the mock answers with a temporary failure.
const THROTTLED_APP = "throttled-app";
const UNAVAILABLE_APP = "unavailable-app";

// A token request the mock received.
type EntraRequest record {|
    string path;
    string? grantType;
    string? clientId;
    string? scope;
    string? clientSecret;
    string? clientAssertionType;
    string? clientAssertion;
    string userAgent;
|};

isolated EntraRequest[] entraRequests = [];
// Base64url SHA-1 and SHA-256 thumbprints of the client certificate the mock accepts for CERTIFICATE_APP.
isolated [string, string] acceptedThumbprints = ["", ""];
// The PEM file of that certificate, whose public key verifies the assertion's signature.
isolated string acceptedCertificatePath = "";
isolated string[] unexpectedEntraPaths = [];

isolated function recordEntraRequest(EntraRequest request) {
    lock {
        entraRequests.push(request.cloneReadOnly());
    }
}

isolated function entraRequestCount() returns int {
    lock {
        return entraRequests.length();
    }
}

isolated function lastEntraRequest() returns EntraRequest|error {
    lock {
        int count = entraRequests.length();
        if count == 0 {
            return error("the mock Entra endpoint received no token request");
        }
        return entraRequests[count - 1].clone();
    }
}

isolated function unexpectedPaths() returns string[] {
    lock {
        return unexpectedEntraPaths.clone();
    }
}

isolated function tokenResponse(string clientId) returns http:Ok => {
    body: {
        token_type: "Bearer",
        expires_in: 3599,
        ext_expires_in: 3599,
        access_token: "entra-token-for-" + clientId
    }
};

isolated function entraError(string code, string description) returns http:BadRequest|http:Unauthorized {
    json body = {'error: code, error_description: description};
    return code == "invalid_client" ? <http:Unauthorized>{body} : <http:BadRequest>{body};
}

type TokenAnswer http:Ok|http:BadRequest|http:Unauthorized|http:TooManyRequests|http:ServiceUnavailable;

// Decides how the mock answers each test application.
isolated function answerTokenRequest(EntraRequest request) returns TokenAnswer {
    string clientId = request.clientId ?: "";
    if request.grantType != "client_credentials" {
        return entraError("unsupported_grant_type", "AADSTS70003: unexpected grant type");
    }
    if clientId == THROTTLED_APP {
        return <http:TooManyRequests>{body: {'error: "temporarily_unavailable", error_description: "throttled"}};
    }
    if clientId == UNAVAILABLE_APP {
        return <http:ServiceUnavailable>{body: {'error: "temporarily_unavailable", error_description: "unavailable"}};
    }
    if clientId == ENV_SECRET_APP {
        return request.clientSecret == ENV_CLIENT_SECRET_VALUE ? tokenResponse(clientId)
            : entraError("invalid_client", "AADSTS7000215: Invalid client secret provided.");
    }
    if clientId == JWT_ECHO_APP {
        string jwt = string `${JWT_ECHO_HEADER}.${JWT_ECHO_PAYLOAD}${request.clientSecret ?: ""}.${JWT_ECHO_SIGNATURE}`;
        return entraError("invalid_client", string `AADSTS7000215: Invalid client secret provided. Received '${jwt}'.`);
    }
    if clientId == CLIENT_SECRET_APP {
        string? secret = request.clientSecret;
        if secret == CLIENT_SECRET_VALUE {
            return tokenResponse(clientId);
        }
        // A badly behaved endpoint that echoes the secret it got: the credential's error must not repeat it.
        return entraError("invalid_client",
            string `AADSTS7000215: Invalid client secret provided. Received '${secret ?: ""}'.`);
    }
    return assertionAnswer(request);
}

// Applications that authenticate with a client assertion (a certificate-signed JWT or a federated token).
isolated function assertionAnswer(EntraRequest request) returns http:Ok|http:BadRequest|http:Unauthorized {
    string clientId = request.clientId ?: "";
    if request.clientAssertionType != JWT_BEARER_ASSERTION {
        return entraError("invalid_client", "AADSTS7000216: client_assertion or client_secret is required");
    }
    string assertion = request.clientAssertion ?: "";
    if clientId == CERTIFICATE_APP {
        string? problem = certificateAssertionProblem(assertion);
        return problem is () ? tokenResponse(clientId) : entraError("invalid_client", "AADSTS700027: " + problem);
    }
    if clientId == WORKLOAD_APP {
        return assertion == FEDERATED_TOKEN_VALUE ? tokenResponse(clientId)
            : entraError("invalid_client",
                string `AADSTS700213: No matching federated identity record for '${assertion}'.`);
    }
    return entraError("unauthorized_client", "AADSTS700016: application not found in the directory");
}

// Checks a certificate-signed client assertion: that its header names the accepted certificate, that the certificate's
// key verifies its signature, and its claims.
isolated function certificateAssertionProblem(string assertion) returns string? {
    string[] parts = re `\.`.split(assertion);
    if parts.length() != 3 {
        return "the client assertion is not a JWT";
    }
    map<json>|error header = decodeJwtPart(parts[0]);
    map<json>|error claims = decodeJwtPart(parts[1]);
    if header is error || claims is error {
        return "the client assertion cannot be decoded";
    }
    // MSAL encodes the thumbprint as standard Base64; compare it in base64url form, without padding.
    string x5t = toBase64Url(header["x5t"] is string ? <string>header["x5t"] : "");
    string x5tS256 = toBase64Url(header["x5t#S256"] is string ? <string>header["x5t#S256"] : "");
    [string, string] accepted;
    lock {
        accepted = acceptedThumbprints.clone();
    }
    if !((x5t != "" && x5t == accepted[0]) || (x5tS256 != "" && x5tS256 == accepted[1])) {
        return "the client assertion was signed with an unknown certificate";
    }
    // MSAL signs client assertions with RS256.
    if header["alg"] != "RS256" {
        return "the client assertion is not signed with RS256";
    }
    string certificatePath;
    lock {
        certificatePath = acceptedCertificatePath;
    }
    byte[]|error signature = decodeBase64Url(parts[2]);
    crypto:PublicKey|crypto:Error key = crypto:decodeRsaPublicKeyFromCertFile(certificatePath);
    if signature is error || key is crypto:Error {
        return "the client assertion signature cannot be checked";
    }
    boolean|crypto:Error valid = crypto:verifyRsaSha256Signature((parts[0] + "." + parts[1]).toBytes(), signature,
        key);
    if valid != true {
        return "the client assertion signature is not valid";
    }
    if claims["iss"] != CERTIFICATE_APP || claims["sub"] != CERTIFICATE_APP {
        return "the client assertion has the wrong issuer or subject";
    }
    json audience = claims["aud"];
    if audience !is string || !audience.endsWith(string `/${MOCK_TENANT}/oauth2/v2.0/token`) {
        return "the client assertion has the wrong audience";
    }
    return ();
}

isolated function toBase64Url(string value) returns string =>
    re `/`.replaceAll(re `\+`.replaceAll(re `=+$`.replaceAll(value, ""), "-"), "_");

isolated function decodeJwtPart(string part) returns map<json>|error =>
    (check string:fromBytes(check decodeBase64Url(part))).fromJsonStringWithType();

isolated function decodeBase64Url(string part) returns byte[]|error {
    string encoded = re `-`.replaceAll(re `_`.replaceAll(part, "/"), "+");
    int padding = (4 - encoded.length() % 4) % 4;
    return array:fromBase64(encoded + "===".substring(0, padding));
}

// The form fields of a token request as sent. `http:Request.getFormParams` trims values, which would hide whether a
// secret's surrounding spaces arrived.
isolated function formFields(http:Request req) returns map<string>|error {
    map<string> fields = {};
    foreach string entry in re `&`.split(check req.getTextPayload()) {
        int? separator = entry.indexOf("=");
        if separator is int {
            fields[check urlDecode(entry.substring(0, separator))] = check urlDecode(entry.substring(separator + 1));
        }
    }
    return fields;
}

isolated function urlDecode(string value) returns string|error =>
    java:toString(check decodeUrl(java:fromString(value), java:fromString("UTF-8"))) ?: "";

isolated function decodeUrl(handle value, handle charset) returns handle|error = @java:Method {
    'class: "java.net.URLDecoder",
    name: "decode",
    paramTypes: ["java.lang.String", "java.lang.String"]
} external;

isolated service class MockEntraService {
    *http:Service;

    resource function post [string tenant]/oauth2/v2\.0/token(http:Request req)
            returns TokenAnswer|error {
        map<string> form = check formFields(req);
        string|http:HeaderNotFoundError userAgent = req.getHeader("User-Agent");
        EntraRequest request = {
            path: string `/${tenant}/oauth2/v2.0/token`,
            grantType: form["grant_type"],
            clientId: form["client_id"],
            scope: form["scope"],
            clientSecret: form["client_secret"],
            clientAssertionType: form["client_assertion_type"],
            clientAssertion: form["client_assertion"],
            userAgent: userAgent is string ? userAgent : ""
        };
        recordEntraRequest(request);
        if tenant != MOCK_TENANT {
            return entraError("invalid_request", "AADSTS90002: tenant not found");
        }
        return answerTokenRequest(request);
    }

    resource function default [string... path](http:Request req) returns http:NotFound {
        string unexpected = req.method + " /" + string:'join("/", ...path);
        lock {
            unexpectedEntraPaths.push(unexpected);
        }
        return {};
    }
}

// Set by `startEntraMock`.
string mockCaBundle = "";
string mockCertDir = "";
http:Listener? entraListener = ();

@test:BeforeGroups {value: [ENTRA_MOCK_GROUP, ENTRA_ENV_MOCK_GROUP]}
function startEntraMock() returns error? {
    if entraListener is http:Listener {
        return;
    }
    mockCertDir = check file:createTempDir();
    string serverKeystore;
    [mockCaBundle, serverKeystore] = check generateTestCertificates(mockCertDir);
    http:Listener 'listener = check new (ENTRA_MOCK_PORT, {
        secureSocket: {key: {path: serverKeystore, password: MOCK_KEYSTORE_PASSWORD}}
    });
    check 'listener.attach(new MockEntraService(), "/");
    check 'listener.'start();
    runtime:registerListener('listener);
    entraListener = 'listener;
}

@test:AfterGroups {value: [ENTRA_MOCK_GROUP, ENTRA_ENV_MOCK_GROUP]}
function stopEntraMock() returns error? {
    test:assertEquals(unexpectedPaths(), [], "only the token endpoint may be called");
    http:Listener? 'listener = entraListener;
    if 'listener is http:Listener {
        runtime:deregisterListener('listener);
        check 'listener.gracefulStop();
    }
    // The directory holds test keys and token files.
    check file:remove(mockCertDir, file:RECURSIVE);
}

# Options that point a credential at the mock: its authority, its CA, and the dead proxy.
#
# + return - The credential options
function mockOptions() returns CredentialOptions => {
    authorityHost: ENTRA_MOCK_AUTHORITY,
    secureSocket: {cert: mockCaBundle},
    proxy: {host: "127.0.0.1", port: DEAD_PROXY_PORT},
    timeout: 10
};

# Generates a throwaway CA and a `localhost` server certificate signed by it, with the JDK's `keytool`.
#
# + dir - The directory to write into
# + return - `[caBundle, serverKeystore]`: the CA as PEM and the server's PKCS#12 key store
function generateTestCertificates(string dir) returns [string, string]|error {
    string ca = check file:joinPath(dir, "ca.p12");
    string caPem = check file:joinPath(dir, "ca.pem");
    string server = check file:joinPath(dir, "server.p12");
    string csr = check file:joinPath(dir, "server.csr");
    string serverPem = check file:joinPath(dir, "server.pem");
    string[] store = ["-storetype", "PKCS12", "-storepass", MOCK_KEYSTORE_PASSWORD];
    check keytool(["-genkeypair", "-alias", "ca", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=Test TLS-Inspecting Proxy CA", "-ext", "bc:c", "-keystore", ca, ...store]);
    check keytool(["-exportcert", "-rfc", "-alias", "ca", "-keystore", ca, "-file", caPem, ...store]);
    check keytool(["-genkeypair", "-alias", "server", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=localhost", "-keystore", server, ...store]);
    check keytool(["-certreq", "-alias", "server", "-keystore", server, "-file", csr, ...store]);
    check keytool(["-gencert", "-rfc", "-alias", "ca", "-keystore", ca, "-infile", csr, "-outfile", serverPem,
        "-validity", "2", "-ext", "san=dns:localhost,ip:127.0.0.1", ...store]);
    check keytool(["-importcert", "-noprompt", "-alias", "ca", "-file", caPem, "-keystore", server, ...store]);
    check keytool(["-importcert", "-noprompt", "-alias", "server", "-file", serverPem, "-keystore", server,
        ...store]);
    return [caPem, server];
}

function keytool(string[] arguments) returns error? {
    string javaHome = java:toString(getSystemProperty(java:fromString("java.home"))) ?: "";
    os:Process process = check os:exec({value: check file:joinPath(javaHome, "bin", "keytool"), arguments});
    int exitCode = check process.waitForExit();
    if exitCode != 0 {
        byte[] stderr = check process.output(io:stderr);
        return error(string `keytool ${arguments[0]} failed (${exitCode}): ${check string:fromBytes(stderr)}`);
    }
}

# Seconds since the epoch, for assertions on token expiry.
#
# + return - The current time in epoch seconds
isolated function nowSeconds() returns int => time:utcNow()[0];
