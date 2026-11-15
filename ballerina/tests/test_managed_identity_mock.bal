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

import ballerina/ai;
import ballerina/file;
import ballerina/http;
import ballerina/io;
import ballerina/jballerina.java;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;
import ballerina/time;
import ballerinax/ai.azure.identity;

// Managed identity against a local mock of the App Service token endpoint (the contract Foundry hosted agents use).
//
// azure-identity (through MSAL) reads `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` from the real process environment,
// so these tests only run in their own `bal test --groups managed-identity-mock` process with both set; the
// `testManagedIdentityMock` Gradle task does that once over HTTP and once over HTTPS. Over HTTPS the mock's
// certificate is signed by a throwaway CA generated here at test time, standing in for a TLS-inspecting proxy.

const MI_GROUP = "managed-identity-mock";
const MI_TOKEN_PREFIX = "mi-token-for-";
const USER_AGENT_MARKER = "ballerinax-ai.azure-identity";
const ECHO_SECRET_SCOPE = "https://echo-secret.example/.default";
const KEYSTORE_PASSWORD = "test-only-password";

// A request the mock token endpoint received.
type MiRequest record {|
    string? 'resource;
    string? apiVersion;
    boolean identityHeaderValid;
    string? clientId;
    string userAgent;
|};

isolated MiRequest[] miRequests = [];

isolated function recordMiRequest(MiRequest request) {
    lock {
        miRequests.push(request.cloneReadOnly());
    }
}

isolated function lastMiRequest() returns MiRequest? {
    lock {
        int count = miRequests.length();
        return count == 0 ? () : miRequests[count - 1].clone();
    }
}

final string miEndpoint = os:getEnv("IDENTITY_ENDPOINT");
final string miHeader = os:getEnv("IDENTITY_HEADER");
final boolean miConfigured = miEndpoint != "" && miHeader != "";
final boolean miOverHttps = miEndpoint.startsWith("https://");

// Set in `startMiMock`; the CA bundle exists only over HTTPS.
string caBundle = "";
http:Listener? miListener = ();

isolated function miMockService() returns http:Service => service object {
    resource function get .(http:Request req, string? 'resource = (), string? api\-version = ())
            returns json|http:Unauthorized|http:BadRequest {
        string|http:HeaderNotFoundError identityHeader = req.getHeader("X-IDENTITY-HEADER");
        string|http:HeaderNotFoundError userAgent = req.getHeader("User-Agent");
        boolean headerValid = identityHeader is string && identityHeader == miHeader;
        recordMiRequest({
            'resource,
            apiVersion: api\-version,
            identityHeaderValid: headerValid,
            clientId: req.getQueryParamValue("client_id"),
            userAgent: userAgent is string ? userAgent : ""
        });
        if !headerValid {
            return <http:Unauthorized>{body: {statusCode: 401, message: "invalid identity header"}};
        }
        string audience = 'resource ?: "";
        if audience.includes("echo-secret") {
            // A badly behaved endpoint that echoes the secret header: the credential's error must not repeat it.
            return <http:BadRequest>{body: {statusCode: 400, message: "rejected header " + miHeader}};
        }
        return {
            access_token: MI_TOKEN_PREFIX + audience,
            expires_on: (time:utcNow()[0] + 3600).toString(),
            'resource: audience,
            token_type: "Bearer"
        };
    }
};

@test:BeforeGroups {value: [MI_GROUP]}
function startMiMock() returns error? {
    if !miConfigured {
        return;
    }
    [string, int, string] [_, port, path] = check splitMiEndpoint(miEndpoint);
    http:ListenerConfiguration config = {};
    if miOverHttps {
        string dir = check file:createTempDir();
        string serverKeystore;
        [caBundle, serverKeystore] = check generateTestCertificates(dir);
        config.secureSocket = {key: {path: serverKeystore, password: KEYSTORE_PASSWORD}};
    }
    http:Listener 'listener = check new (port, config);
    check 'listener.attach(miMockService(), path);
    check 'listener.'start();
    runtime:registerListener('listener);
    miListener = 'listener;
}

@test:AfterGroups {value: [MI_GROUP]}
function stopMiMock() returns error? {
    http:Listener? 'listener = miListener;
    if 'listener is http:Listener {
        runtime:deregisterListener('listener);
        check 'listener.gracefulStop();
    }
}

@test:Config {groups: [MI_GROUP]}
function testManagedIdentityTokenComesThroughOurHttpClient() returns error? {
    if !miConfigured {
        return;
    }
    string scope = "https://mi-direct.example/.default";
    if miOverHttps {
        check os:setEnv("SSL_CERT_FILE", caBundle);
    }
    identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
    identity:AccessToken token = check credential.getToken([scope]);
    test:assertEquals(token.token, MI_TOKEN_PREFIX + "https://mi-direct.example");
    test:assertTrue(token.expiresOn > time:utcNow()[0]);

    MiRequest request = check lastMiRequest().ensureType();
    test:assertTrue(request.identityHeaderValid, "the X-IDENTITY-HEADER must be sent");
    test:assertEquals(request.apiVersion, "2019-08-01");
    test:assertEquals(request.'resource, "https://mi-direct.example");
    test:assertEquals(request.clientId, (), "no client_id unless one is configured");
    // azure-identity routes managed identity through MSAL; the marker proves MSAL used the HTTP client we injected
    // (with our trust store and proxy settings) rather than its own.
    test:assertTrue(request.userAgent.includes(USER_AGENT_MARKER), "User-Agent: " + request.userAgent);
}

@test:Config {groups: [MI_GROUP], dependsOn: [testManagedIdentityTokenComesThroughOurHttpClient]}
function testUserAssignedManagedIdentitySendsItsClientId() returns error? {
    if !miConfigured {
        return;
    }
    if miOverHttps {
        check os:setEnv("SSL_CERT_FILE", caBundle);
    }
    string clientId = "11111111-2222-3333-4444-555555555555";
    identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity", clientId});
    // A scope no other test requests, so the request is not answered from a cached token.
    identity:AccessToken token = check credential.getToken(["https://mi-user-assigned.example/.default"]);
    test:assertEquals(token.token, MI_TOKEN_PREFIX + "https://mi-user-assigned.example");

    MiRequest request = check lastMiRequest().ensureType();
    test:assertEquals(request.'resource, "https://mi-user-assigned.example");
    test:assertEquals(request.clientId, clientId, "the configured client ID selects the user-assigned identity");
}

@test:Config {groups: [MI_GROUP], dependsOn: [testUserAssignedManagedIdentitySendsItsClientId]}
function testManagedIdentityOverTls12() returns error? {
    if !miConfigured || !miOverHttps {
        return;
    }
    check os:unsetEnv("SSL_CERT_FILE");
    // `versions` are JSSE names and must reach the token client unchanged: a mangled name fails the handshake.
    identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"},
        secureSocket = {cert: caBundle, protocol: {name: http:TLS, versions: ["TLSv1.2"]}});
    identity:AccessToken token = check credential.getToken(["https://mi-tls12.example/.default"]);
    test:assertEquals(token.token, MI_TOKEN_PREFIX + "https://mi-tls12.example");
    MiRequest request = check lastMiRequest().ensureType();
    test:assertEquals(request.'resource, "https://mi-tls12.example");
}

@test:Config {groups: [MI_GROUP], dependsOn: [testManagedIdentityOverTls12]}
function testManagedIdentityOverHttpsFailsWithoutTheCa() returns error? {
    if !miConfigured || !miOverHttps {
        return;
    }
    check os:unsetEnv("SSL_CERT_FILE");
    identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
    // A scope no other test requests, so no cached token can hide the TLS failure.
    identity:AccessToken|identity:Error token = credential.getToken(["https://mi-no-ca.example/.default"]);
    if token !is identity:Error {
        return error("the mock's certificate must not be trusted without the CA");
    }
    string described = token.toString().toLowerAscii();
    test:assertTrue(described.includes("pkix") || described.includes("certification path")
            || described.includes("ssl") || described.includes("tls") || described.includes("certificate"),
        token.toString());
    test:assertFalse(token.toString().includes(miHeader), "the identity header must not appear in errors");
}

@test:Config {groups: [MI_GROUP], dependsOn: [testManagedIdentityOverHttpsFailsWithoutTheCa]}
function testIdentityHeaderIsNotInErrors() returns error? {
    if !miConfigured {
        return;
    }
    if miOverHttps {
        check os:setEnv("SSL_CERT_FILE", caBundle);
    }
    identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
    identity:AccessToken|identity:Error token = credential.getToken([ECHO_SECRET_SCOPE]);
    if token !is identity:Error {
        return error("the mock rejects this scope");
    }
    MiRequest request = check lastMiRequest().ensureType();
    test:assertEquals(request.'resource, "https://echo-secret.example", "the request must reach the mock");
    test:assertFalse(token.toString().includes(miHeader), "the identity header must not appear in errors");
}

@test:Config {groups: [MI_GROUP], dependsOn: [testIdentityHeaderIsNotInErrors]}
function testProviderWithManagedIdentityEndToEnd() returns error? {
    if !miConfigured {
        return;
    }
    // The Foundry setup: SSL_CERT_FILE names the egress proxy's CA, and the endpoint trusts the same bundle. Token
    // requests trust SSL_CERT_FILE themselves; the endpoint's secureSocket is not applied to them.
    string scope = "https://cognitiveservices.azure.com/.default";
    OpenAiModelProvider provider;
    if miOverHttps {
        check os:setEnv("SSL_CERT_FILE", caBundle);
        provider = check new (AUTH_MOCK_URL, {'type: "managedIdentity"}, DEPLOYMENT_ID, API_VERSION,
            tokenScope = scope, secureSocket = {cert: caBundle});
        check os:unsetEnv("SSL_CERT_FILE");
    } else {
        provider = check new (AUTH_MOCK_URL, {'type: "managedIdentity"}, DEPLOYMENT_ID, API_VERSION,
            tokenScope = scope);
    }

    ai:ChatAssistantMessage reply = check provider->chat([{role: ai:USER, content: "Hi"}]);
    test:assertTrue((reply.content ?: "").includes("Hello from the auth mock"));
    RecordedAuth auth = check takeRecordedAuth(ROUTE_CHAT_LEGACY);
    test:assertEquals(auth.authorization, "Bearer " + MI_TOKEN_PREFIX + "https://cognitiveservices.azure.com");
    test:assertEquals(auth.apiKey, ());

    MiRequest request = check lastMiRequest().ensureType();
    test:assertEquals(request.'resource, "https://cognitiveservices.azure.com");
    test:assertTrue(request.userAgent.includes(USER_AGENT_MARKER), "User-Agent: " + request.userAgent);
}

@test:Config {groups: [MI_GROUP], dependsOn: [testProviderWithManagedIdentityEndToEnd]}
function testEndpointTlsDisabledKeepsTokenTlsVerified() returns error? {
    if !miConfigured || !miOverHttps {
        return;
    }
    // Turning TLS checks off for the model endpoint must not turn them off for token requests: without the CA in
    // SSL_CERT_FILE, the token request to the HTTPS mock still fails certificate validation.
    check os:unsetEnv("SSL_CERT_FILE");
    OpenAiModelProvider provider = check new (AUTH_MOCK_URL, {'type: "managedIdentity"}, DEPLOYMENT_ID, API_VERSION,
        tokenScope = "https://endpoint-tls-off.example/.default", secureSocket = {enable: false});
    ai:ChatAssistantMessage|ai:Error reply = provider->chat([{role: ai:USER, content: "Hi"}]);
    if reply !is ai:Error {
        return error("the token request must not trust the mock without its CA");
    }
    test:assertTrue(reply.toString().toLowerAscii().includes("certification path"), reply.toString());
    test:assertTrue(takeRecordedAuth(ROUTE_CHAT_LEGACY) is error, "no model request without a token");
}

@test:Config {groups: [MI_GROUP], dependsOn: [testEndpointTlsDisabledKeepsTokenTlsVerified]}
function testSlf4jHasAProviderAfterCredentialsRan() {
    if !miConfigured {
        return;
    }
    // azure-identity logs through slf4j. Without a provider slf4j 2 falls back to a NOP factory (and prints
    // "No SLF4J providers were found"); the Gradle task also fails on that line.
    string factory = java:toString(getClassName(getObjectClass(getILoggerFactory()))) ?: "";
    test:assertTrue(factory != "" && !factory.includes("NOP") && !factory.includes("Substitute"),
        "slf4j logger factory: " + factory);
}

# Splits an endpoint URL such as `https://localhost:8094/msi/token` into its scheme, port and path.
#
# + endpoint - The endpoint URL
# + return - `[scheme, port, path]`, or an error if the URL has no explicit port
function splitMiEndpoint(string endpoint) returns [string, int, string]|error {
    int schemeEnd = check endpoint.indexOf("://").ensureType();
    string scheme = endpoint.substring(0, schemeEnd);
    string rest = endpoint.substring(schemeEnd + 3);
    int pathStart = rest.indexOf("/") ?: rest.length();
    string authority = rest.substring(0, pathStart);
    string path = pathStart < rest.length() ? rest.substring(pathStart) : "/";
    int portStart = check authority.lastIndexOf(":").ensureType();
    return [scheme, check int:fromString(authority.substring(portStart + 1)), path];
}

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
    string[] store = ["-storetype", "PKCS12", "-storepass", KEYSTORE_PASSWORD];
    check keytool(["-genkeypair", "-alias", "ca", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=Test TLS-Inspecting Proxy CA", "-ext", "bc:c", "-keystore", ca, ...store]);
    check keytool(["-exportcert", "-rfc", "-alias", "ca", "-keystore", ca, "-file", caPem, ...store]);
    check keytool(["-genkeypair", "-alias", "server", "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
        "-dname", "CN=localhost", "-keystore", server, ...store]);
    check keytool(["-certreq", "-alias", "server", "-keystore", server, "-file", csr, ...store]);
    check keytool(["-gencert", "-rfc", "-alias", "ca", "-keystore", ca, "-infile", csr, "-outfile", serverPem,
        "-validity", "2", "-ext", "san=dns:localhost,ip:127.0.0.1", ...store]);
    check keytool(["-importcert", "-noprompt", "-alias", "ca", "-file", caPem, "-keystore", server, ...store]);
    check keytool(["-importcert", "-alias", "server", "-file", serverPem, "-keystore", server, ...store]);
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

function getSystemProperty(handle name) returns handle = @java:Method {
    'class: "java.lang.System",
    name: "getProperty",
    paramTypes: ["java.lang.String"]
} external;

function getILoggerFactory() returns handle = @java:Method {
    'class: "org.slf4j.LoggerFactory",
    name: "getILoggerFactory"
} external;

function getObjectClass(handle obj) returns handle = @java:Method {
    'class: "java.lang.Object",
    name: "getClass"
} external;

function getClassName(handle 'class) returns handle = @java:Method {
    'class: "java.lang.Class",
    name: "getName"
} external;
