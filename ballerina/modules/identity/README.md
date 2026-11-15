## Overview

The `ai.azure.identity` module provides Microsoft Entra ID (keyless) credentials for the `ai.azure` providers.

A credential is described by a plain record whose `type` field selects it, or supplied as any object that implements
`TokenCredential`. Tokens are cached per scope set and refreshed before they expire.

| `type` | Credential |
|---|---|
| `default` | Default chain: environment, workload identity, managed identity, then developer tools (Azure CLI, ...) |
| `managedIdentity` | Managed identity (Azure compute, Azure AI Foundry hosted agents) |

`default` tries environment variables, workload identity, managed identity, then developer tools such as the Azure
CLI, and uses the first source that works. `sources` narrows the chain: `prod` keeps environment variables, workload
identity and managed identity, and `dev` keeps the developer tools; the `AZURE_TOKEN_CREDENTIALS` environment
variable can narrow it as well. `managedIdentityClientId` defaults to the `AZURE_CLIENT_ID` environment variable.

`managedIdentity` covers Azure compute (VMs, App Service, Container Apps, AKS, Functions) and Azure AI Foundry hosted
agents. Omit `clientId` to use the system-assigned identity.

`TokenCredential` is structural, so an application can supply its own implementation (for example, one that reads
tokens from a vault). Implementations are expected to cache and refresh tokens, to never panic, and to never log
tokens.

`createCredential` makes no network call; the first `getToken` contacts the credential source. `AccessToken` times
are epoch seconds.

```ballerina
import ballerinax/ai.azure.identity;

identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
identity:AccessToken token = check credential.getToken(["https://cognitiveservices.azure.com/.default"]);
```

Token requests trust the JVM's default certificates plus those in the file named by the `SSL_CERT_FILE` environment
variable and in `secureSocket.cert`, and use the configured `proxy` (HTTP proxies only). TLS is always verified:
`secureSocket.enable = false`, a client key, DTLS and the other options token requests can't honour are rejected.
Proxy authentication needs the JVM option `-Djdk.http.auth.tunneling.disabledSchemes=`, because the JDK disables
Basic authentication for HTTPS tunnels by default; without it, a proxy `userName` is rejected. Local managed identity
endpoints are always reached without the proxy. `authorityHost` is the Microsoft Entra ID authority:
`AZURE_PUBLIC_CLOUD` (the default) or another cloud's authority URL.

Tokens and secrets never appear in errors. An `Error` carries the credential type and, when the service returned
one, the Microsoft Entra ID error code (`AADSTS...`). `CredentialUnavailableError` means no credential source is
available (for example, no managed identity endpoint, or no Azure CLI sign-in); `AuthenticationError` means the
source refused the token request.
