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

import ballerina/jballerina.java;

const NATIVE_CLASS = "io.ballerina.lib.ai.azure.identity.Credentials";

# How the native layer classifies a failure (the `kind` detail of a native error).
const KIND_UNAVAILABLE = "unavailable";
const KIND_AUTHENTICATION = "authentication";

# Trust and proxy settings for the native token client, resolved from `CredentialOptions` and `SSL_CERT_FILE`.
type NativeTransport record {|
    # PEM files whose certificates are trusted in addition to the JVM's defaults
    string[] trustedCertFiles = [];
    # PKCS#12 trust stores whose certificates are trusted in addition to the JVM's defaults
    record {|string path; string password;|}[] trustStores = [];
    # JSSE protocol names to enable (e.g. `TLSv1.3`); empty for the JVM's defaults
    string[] protocols = [];
    # Cipher suites to enable; empty for the JVM's defaults
    string[] ciphers = [];
    # Timeout (in seconds) for each token request
    decimal timeout;
    # Proxy for token requests; local managed identity endpoints bypass it
    record {|string host; int port; string userName = ""; string password = "";|} proxy?;
    # Microsoft Entra ID authority host
    string authorityHost;
|};

# A credential backed by Java azure-identity, with a `TokenCache` in front of it.
isolated class AzureIdentityCredential {
    *TokenCredential;

    private final string credentialType;
    private final TokenCache cache;

    isolated function init(string credentialType, map<anydata> config, NativeTransport transport) returns Error? {
        self.credentialType = credentialType;
        final NativeCredential nativeCredential = check new (credentialType, config, transport);
        self.cache = new (isolated function(readonly & string[] scopes) returns AccessToken|Error =>
            nativeCredential.fetchToken(scopes));
    }

    public isolated function getToken(string[] scopes) returns AccessToken|Error {
        if scopes.length() == 0 {
            return error Error("at least one scope is required", credential = self.credentialType);
        }
        return self.cache.getToken(scopes);
    }
}

# Holds the Java `TokenCredential` as native data. Every call goes to azure-identity; caching is the caller's job.
isolated class NativeCredential {
    private final string credentialType;

    isolated function init(string credentialType, map<anydata> config, NativeTransport transport) returns Error? {
        self.credentialType = credentialType;
        error? result = initNativeCredential(self, credentialType, config, transport);
        if result is error {
            return toIdentityError(credentialType, result);
        }
    }

    isolated function fetchToken(readonly & string[] scopes) returns AccessToken|Error {
        map<anydata>|error result = fetchNativeToken(self, scopes);
        if result is error {
            return toIdentityError(self.credentialType, result);
        }
        string|error token = result["token"].ensureType();
        int|error expiresOn = result["expiresOn"].ensureType();
        int|error? refreshOn = result["refreshOn"].ensureType();
        if token is error || expiresOn is error || refreshOn is error {
            return error Error("the credential returned an incomplete token", credential = self.credentialType);
        }
        return refreshOn is int ? {token, expiresOn, refreshOn} : {token, expiresOn};
    }
}

# Maps a native error to the module's error types. Native messages are already sanitised (no tokens or secrets).
#
# + credentialType - The credential's `type`, recorded in the error detail
# + err - The native error
# + return - A `CredentialUnavailableError`, an `AuthenticationError`, or an `Error` for any other failure
isolated function toIdentityError(string credentialType, error err) returns Error {
    map<anydata> detail = <map<anydata>>err.detail().cloneReadOnly();
    anydata code = detail["code"];
    string? errorCode = code is string ? code : ();
    anydata kind = detail["kind"];
    if kind == KIND_UNAVAILABLE {
        return errorCode is string
            ? error CredentialUnavailableError(err.message(), credential = credentialType, code = errorCode)
            : error CredentialUnavailableError(err.message(), credential = credentialType);
    }
    if kind == KIND_AUTHENTICATION {
        return errorCode is string
            ? error AuthenticationError(err.message(), credential = credentialType, code = errorCode)
            : error AuthenticationError(err.message(), credential = credentialType);
    }
    return errorCode is string
        ? error Error(err.message(), credential = credentialType, code = errorCode)
        : error Error(err.message(), credential = credentialType);
}

isolated function initNativeCredential(NativeCredential credential, string credentialType, map<anydata> config,
        NativeTransport transport) returns error? = @java:Method {
    'class: NATIVE_CLASS,
    name: "init"
} external;

isolated function fetchNativeToken(NativeCredential credential, string[] scopes) returns map<anydata>|error =
@java:Method {
    'class: NATIVE_CLASS,
    name: "getToken"
} external;
