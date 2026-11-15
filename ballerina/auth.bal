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
import ballerina/http;
import ballerinax/ai.azure.identity;

const PROJECT_PATH_SEGMENT = "/api/projects/";
const AI_AZURE_SCOPE = "https://ai.azure.com/.default";
const SEARCH_SCOPE = "https://search.azure.com/.default";
const COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default";
const COGNITIVE_SERVICES_US_GOV_SCOPE = "https://cognitiveservices.azure.us/.default";

# Microsoft Entra ID bearer authentication for one service: a token credential and the scope its tokens are
# requested for. Tokens are fetched per request; caching and refresh are the credential's job.
isolated class BearerAuth {
    private final identity:TokenCredential credential;
    private final string[] & readonly scopes;

    isolated function init(identity:TokenCredential credential, string scope) {
        self.credential = credential;
        self.scopes = [scope];
    }

    # Returns the `Authorization` header for the next request.
    #
    # + return - The header map, or an `ai:Error` (which never carries a token) if no token could be obtained
    isolated function headers() returns map<string>|ai:Error {
        identity:AccessToken|identity:Error token = self.credential.getToken(self.scopes);
        if token is identity:Error {
            return error ai:Error(string `Failed to get an Entra ID token for ${self.scopes[0]}`, token);
        }
        return {"Authorization": "Bearer " + token.token};
    }
}

# Returns the headers that authenticate a request: `api-key` for an API key, `Authorization: Bearer` for a
# credential.
#
# + auth - The API key, or the bearer authentication built from a credential
# + return - The header map, or an `ai:Error` if a token could not be obtained
isolated function authHeaders(string|BearerAuth auth) returns map<string>|ai:Error {
    if auth is string {
        return {"api-key": auth};
    }
    return auth.headers();
}

# Resolves the `apiKey`/credential argument of a provider into what requests are authenticated with.
#
# A `string` is an API key and is returned unchanged. A credential configuration is turned into a credential whose
# token requests use the provider's TLS and proxy settings; a ready-made `identity:TokenCredential` is used as is.
# Either way the token scope is `tokenScope` when set, and is otherwise derived from the service URL.
#
# A credential needs an `https://` service URL, so bearer tokens never cross the network in clear text; `http://` is
# accepted only for a loopback host (`localhost`, `127.0.0.0/8` or `[::1]`), e.g. a local mock or gateway.
#
# + auth - The API key or credential passed to the provider
# + serviceUrl - The provider's service URL
# + config - The provider's connection configuration
# + return - The API key or the bearer authentication, or an `ai:Error` if the credential, scope or URL is invalid
isolated function resolveAuth(string|identity:Credential auth, string serviceUrl, ConnectionConfig config)
        returns string|BearerAuth|ai:Error {
    if auth is string {
        return auth;
    }
    if !isSecureOrLoopbackUrl(serviceUrl) {
        return error ai:Error("Entra ID authentication requires an 'https://' service URL; 'http://' is allowed " +
                "only for a loopback host (localhost, 127.0.0.0/8 or [::1])");
    }
    string scope = check resolveTokenScope(serviceUrl, config.tokenScope);
    if auth is identity:TokenCredential {
        return new BearerAuth(auth, scope);
    }
    identity:CredentialOptions options = {};
    http:ClientSecureSocket? secureSocket = config.secureSocket;
    if secureSocket is http:ClientSecureSocket {
        options.secureSocket = secureSocket;
    }
    http:ProxyConfig? proxy = config.proxy;
    if proxy is http:ProxyConfig {
        options.proxy = proxy;
    }
    identity:TokenCredential|identity:Error credential = identity:createCredential(auth, options);
    if credential is identity:Error {
        return error ai:Error("Failed to create the Entra ID credential", credential);
    }
    return new BearerAuth(credential, scope);
}

# Returns `true` for an `https://` URL, and for an `http://` URL whose host is loopback.
#
# + url - The service URL
# + return - `true` when a bearer token may be sent to this URL
isolated function isSecureOrLoopbackUrl(string url) returns boolean {
    string lowered = url.trim().toLowerAscii();
    if lowered.startsWith("https://") {
        return true;
    }
    if !lowered.startsWith("http://") {
        return false;
    }
    string host = splitUrl(lowered)[0];
    return host == "localhost" || host == "[::1]" || isIpv4Loopback(host);
}

# Returns `true` for a dotted IPv4 address in `127.0.0.0/8`.
#
# + host - The host, without a port
# + return - `true` for a loopback IPv4 address
isolated function isIpv4Loopback(string host) returns boolean {
    if !re `127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}`.isFullMatch(host) {
        return false;
    }
    foreach string octet in re `\.`.split(host) {
        int|error value = int:fromString(octet);
        if value !is int || value > 255 {
            return false;
        }
    }
    return true;
}

# Returns the explicit token scope if one is set, and otherwise the scope derived from the service URL.
#
# + serviceUrl - The provider's service URL
# + tokenScope - The `tokenScope` from the connection configuration, if any
# + return - The token scope, or an `ai:Error` if it is blank or cannot be derived
isolated function resolveTokenScope(string serviceUrl, string? tokenScope) returns string|ai:Error {
    if tokenScope is () {
        return deriveTokenScope(serviceUrl);
    }
    string scope = tokenScope.trim();
    if scope.length() == 0 {
        return error ai:Error("The 'tokenScope' connection setting must not be empty");
    }
    return scope;
}

# Derives the Microsoft Entra ID token scope of an Azure AI endpoint from its URL.
#
# | URL | Scope |
# | --- | --- |
# | path contains `/api/projects/` (a Foundry project endpoint) | `https://ai.azure.com/.default` |
# | host `*.search.windows.net` | `https://search.azure.com/.default` |
# | host `*.openai.azure.com`, `*.cognitiveservices.azure.com` or `*.services.ai.azure.com` | `https://cognitiveservices.azure.com/.default` |
# | host `*.openai.azure.us` | `https://cognitiveservices.azure.us/.default` |
#
# Any other host (an API Management gateway, a custom domain, a local endpoint) has no default, because a wrong
# audience only shows up later as a confusing 401; the caller must set `tokenScope` instead.
#
# + serviceUrl - The service URL
# + return - The token scope, or an `ai:Error` if the URL matches none of the known endpoints
isolated function deriveTokenScope(string serviceUrl) returns string|ai:Error {
    [string, string] [host, path] = splitUrl(serviceUrl);
    if path.includes(PROJECT_PATH_SEGMENT) {
        return AI_AZURE_SCOPE;
    }
    if host.endsWith(".search.windows.net") {
        return SEARCH_SCOPE;
    }
    if host.endsWith(".openai.azure.com") || host.endsWith(".cognitiveservices.azure.com")
            || host.endsWith(".services.ai.azure.com") {
        return COGNITIVE_SERVICES_SCOPE;
    }
    if host.endsWith(".openai.azure.us") {
        return COGNITIVE_SERVICES_US_GOV_SCOPE;
    }
    return error ai:Error(string `Cannot derive the Entra ID token scope for host '${host}'; set 'tokenScope' ` +
            string `in the connection configuration (for example, "${COGNITIVE_SERVICES_SCOPE}")`);
}

# Splits a URL into its lower-cased host (without user info or port) and its lower-cased path (without query or
# fragment).
#
# + url - The URL
# + return - A `[host, path]` tuple; the path is empty for a bare origin
isolated function splitUrl(string url) returns [string, string] {
    string rest = url.toLowerAscii();
    int? schemeSeparator = rest.indexOf("://");
    if schemeSeparator is int {
        rest = rest.substring(schemeSeparator + 3);
    }
    int end = rest.length();
    foreach string delimiter in ["?", "#"] {
        int? index = rest.indexOf(delimiter);
        if index is int && index < end {
            end = index;
        }
    }
    rest = rest.substring(0, end);
    int? pathStart = rest.indexOf("/");
    string authority = pathStart is int ? rest.substring(0, pathStart) : rest;
    string path = pathStart is int ? rest.substring(pathStart) : "";
    int? userInfoEnd = authority.lastIndexOf("@");
    if userInfoEnd is int {
        authority = authority.substring(userInfoEnd + 1);
    }
    int? portStart = authority.lastIndexOf(":");
    if portStart is int && !authority.substring(portStart).includes("]") {
        authority = authority.substring(0, portStart);
    }
    return [authority, path];
}
