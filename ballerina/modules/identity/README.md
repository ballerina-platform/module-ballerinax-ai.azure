## Overview

The `ai.azure.identity` module provides Microsoft Entra ID (keyless) credentials for the `ai.azure` providers.

A credential is described by a plain record whose `type` field selects it, or supplied as any object that implements
`TokenCredential`. Tokens are cached per scope set and refreshed before they expire.

| `type` | Credential | Status |
|---|---|---|
| `default` | Default chain: environment, workload identity, managed identity, then developer tools (Azure CLI, ...) | Supported |
| `managedIdentity` | Managed identity (Azure compute, Azure AI Foundry hosted agents) | Supported |
| `workloadIdentity` | Kubernetes workload identity | Not implemented yet |
| `clientSecret` | Service principal with a client secret | Not implemented yet |
| `azureCli` | Azure CLI sign-in | Not implemented yet |
| `staticToken` | Fixed token | Not implemented yet |

```ballerina
import ballerinax/ai.azure.identity;

identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
identity:AccessToken token = check credential.getToken(["https://cognitiveservices.azure.com/.default"]);
```

Token requests trust the JVM's default certificates plus those in the file named by the `SSL_CERT_FILE` environment
variable and in `secureSocket.cert`, and use the configured `proxy` (HTTP proxies only). Tokens and secrets never
appear in errors.
