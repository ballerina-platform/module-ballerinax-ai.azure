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
# Microsoft Entra ID authority host of Azure Government.
public const AZURE_US_GOVERNMENT = "https://login.microsoftonline.us/";
# Microsoft Entra ID authority host of Microsoft Azure operated by 21Vianet (China).
public const AZURE_CHINA = "https://login.chinacloudapi.cn/";

# An access token for one audience. Times are epoch seconds.
#
# + token - The bearer token. Never log it or put it in an error.
# + expiresOn - When the token expires
# + refreshOn - When the source suggests refreshing the token early, if it does
public type AccessToken readonly & record {|
    string token;
    int expiresOn;
    int refreshOn?;
|};

# Anything that can produce Microsoft Entra ID access tokens.
#
# The type is structural, so an application can supply its own implementation (for example, one that reads tokens
# from a vault). Implementations are expected to cache and refresh tokens, to never panic, and to never log tokens.
public type TokenCredential isolated object {
    # Returns a valid access token for the given scopes.
    #
    # + scopes - The scopes to request, e.g. `["https://cognitiveservices.azure.com/.default"]`
    # + return - The access token, or an `Error` if one could not be obtained
    public isolated function getToken(string[] scopes) returns AccessToken|Error;
};

# Details of an identity error. They never contain tokens or secrets.
#
# + credential - The credential type that failed (for example, `managedIdentity`)
# + code - The Microsoft Entra ID error code (`AADSTS...`), when the service returned one
public type ErrorDetail record {|
    string credential;
    string code?;
|};

# Represents any error from the identity module.
public type Error distinct error<ErrorDetail>;

# No usable credential source is available in this environment (for example, no managed identity endpoint, or the
# Azure CLI is not logged in).
public type CredentialUnavailableError distinct Error;

# A credential source was found, but Microsoft Entra ID or the managed identity endpoint refused the request.
public type AuthenticationError distinct Error;

# The default credential chain, which picks the first source that works in the current environment: environment
# variables, workload identity, managed identity, then developer tools such as the Azure CLI.
@display {label: "Default Azure Credential"}
public type DefaultCredentialConfig record {|
    # Discriminator for this credential type
    @display {label: "Type"}
    "default" 'type;
    # Narrows the chain: `prod` keeps environment, workload identity and managed identity; `dev` keeps the developer
    # tools; `all` keeps every source (the `AZURE_TOKEN_CREDENTIALS` environment variable can still narrow it)
    @display {label: "Credential Sources"}
    "all"|"prod"|"dev" sources = "all";
    # Client ID of a user-assigned managed identity (default: the `AZURE_CLIENT_ID` environment variable)
    @display {label: "Managed Identity Client ID"}
    string managedIdentityClientId?;
    # Microsoft Entra ID tenant to request tokens from
    @display {label: "Tenant ID"}
    string tenantId?;
|};

# A managed identity: Azure compute (VMs, App Service, Container Apps, AKS, Functions) and Azure AI Foundry hosted
# agents.
@display {label: "Managed Identity"}
public type ManagedIdentityConfig record {|
    # Discriminator for this credential type
    @display {label: "Type"}
    "managedIdentity" 'type;
    # Client ID of a user-assigned managed identity. Omit it to use the system-assigned identity.
    @display {label: "Client ID"}
    string clientId?;
|};

# Plain-data configuration of a credential. The `type` field selects the credential.
public type CredentialConfig DefaultCredentialConfig|ManagedIdentityConfig;

# A credential: either its configuration or a ready-made `TokenCredential`.
public type Credential CredentialConfig|TokenCredential;

# Transport and cloud options for the token requests a credential makes.
public type CredentialOptions record {|
    # Microsoft Entra ID authority host (`AZURE_PUBLIC_CLOUD`, `AZURE_US_GOVERNMENT`, `AZURE_CHINA`, or a URL)
    string authorityHost = AZURE_PUBLIC_CLOUD;
    # TLS settings for token requests. Certificates in the file named by the `SSL_CERT_FILE` environment variable
    # are always trusted as well, in addition to the JVM's default trust store.
    http:ClientSecureSocket secureSocket?;
    # HTTP proxy for token requests (SOCKS proxies are not supported). Local managed identity endpoints are always
    # reached directly.
    http:ProxyConfig proxy?;
    # Timeout (in seconds) for each token request
    decimal timeout = 30;
|};
