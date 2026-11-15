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

# Microsoft Entra ID authority host of the Azure public cloud.
public const AZURE_PUBLIC_CLOUD = "https://login.microsoftonline.com/";

# A Microsoft Entra ID access token.
#
# + token - The bearer token
# + expiresOn - When the token expires (epoch seconds)
# + refreshOn - When the token should be refreshed (epoch seconds), if the source suggests a time
public type AccessToken readonly & record {|
    string token;
    int expiresOn;
    int refreshOn?;
|};

# Provides Microsoft Entra ID access tokens.
public type TokenCredential isolated object {
    # Returns a valid access token for the given scopes.
    #
    # + scopes - The scopes to request, e.g. `["https://cognitiveservices.azure.com/.default"]`
    # + return - The access token, or an `Error` if one could not be obtained
    public isolated function getToken(string[] scopes) returns AccessToken|Error;
};

# Details of an identity error.
#
# + credential - The credential type that failed (for example, `managedIdentity`)
# + code - The Microsoft Entra ID error code (`AADSTS...`), when the service returned one
public type ErrorDetail record {|
    string credential;
    string code?;
|};

# Represents any error from the identity module.
public type Error distinct error<ErrorDetail>;

# No credential source is available in the current environment.
public type CredentialUnavailableError distinct Error;

# The credential source refused the token request.
public type AuthenticationError distinct Error;

# The default Azure credential, which uses the first credential source available in the current environment.
@display {label: "Default Azure Credential"}
public type DefaultCredentialConfig record {|
    # The credential type
    @display {label: "Type"}
    "default" 'type;
    # The credential sources to try: `all`, `prod` (deployed environments) or `dev` (developer tools)
    @display {label: "Credential Sources"}
    "all"|"prod"|"dev" sources = "all";
    # Client ID of a user-assigned managed identity
    @display {label: "Managed Identity Client ID"}
    string managedIdentityClientId?;
    # Microsoft Entra ID tenant to request tokens from
    @display {label: "Tenant ID"}
    string tenantId?;
|};

# The managed identity of an Azure resource or an Azure AI Foundry hosted agent.
@display {label: "Managed Identity"}
public type ManagedIdentityConfig record {|
    # The credential type
    @display {label: "Type"}
    "managedIdentity" 'type;
    # Client ID of a user-assigned managed identity; omit it to use the system-assigned identity
    @display {label: "Client ID"}
    string clientId?;
|};

# The configuration of a credential.
public type CredentialConfig DefaultCredentialConfig|ManagedIdentityConfig;

# A credential configuration or a `TokenCredential`.
public type Credential CredentialConfig|TokenCredential;

# Options for the token requests of a credential.
public type CredentialOptions record {|
    # Microsoft Entra ID authority host URL; another cloud's host here needs a matching token scope
    string authorityHost = AZURE_PUBLIC_CLOUD;
    # SSL/TLS-related options for token requests
    http:ClientSecureSocket secureSocket?;
    # HTTP proxy for token requests; proxy authentication needs the JVM option
    # `-Djdk.http.auth.tunneling.disabledSchemes=`
    http:ProxyConfig proxy?;
    # Timeout (in seconds) for each token request
    decimal timeout = 30;
|};
