## Overview

Azure OpenAI Service provides access to OpenAI's powerful language models within the Microsoft Azure platform.

The Azure OpenAI connector offers APIs for connecting with Azure OpenAI Large Language Models (LLMs), enabling the integration of advanced conversational AI, text generation, and language processing capabilities into applications.

### Key Features

- Connect and interact with Azure OpenAI Large Language Models (LLMs), such as the GPT-5 and GPT-4 series
- Support for both the Chat Completions API and the Responses API, selected through the `apiType` parameter
- Parallel (multiple) tool calls in a single assistant turn, on both API surfaces
- Reasoning-effort control for reasoning models (`gpt-5`/`o`-series)
- Text embeddings through `EmbeddingProvider`
- A knowledge base on an Azure AI Search index through `AiSearchKnowledgeBase`
- A listener for running an agent as a Foundry hosted agent
- API key and Microsoft Entra ID (keyless) authentication

### Choosing an API

`OpenAiModelProvider` implements `ai:ModelProvider`. It uses the Azure OpenAI **Chat Completions API** by default,
or the **Responses API** when `apiType` is `RESPONSES`.

The service URL selects the Azure OpenAI surface:

- A URL ending with `/v1`, such as `https://<resource>.openai.azure.com/openai/v1`, targets the **v1 GA** surface.
  `apiVersion` is optional and normally omitted; pass `"preview"` or `"v1"` to opt into a specific v1 surface (other
  values are ignored on v1 URLs).
- Any other URL, such as `https://<resource>.openai.azure.com/openai`, targets the **legacy** surface, which needs a
  date-based `apiVersion` such as `"2024-10-21"`.

Leave `temperature` unset for models that do not support it, such as the GPT-5 and o-series reasoning models. Not
every model supports every `reasoningEffort` value: `MINIMAL` is supported only by the original GPT-5 reasoning
models, `NONE` by GPT-5.1 and later, and `XHIGH` by `gpt-5.1-codex-max` and later; the service rejects a value the
deployment doesn't support.

The exact request paths for each combination are listed in
[Request routing](https://github.com/ballerina-platform/module-ballerinax-ai.azure/blob/main/docs/routing.md).

### Tool calling

Both API surfaces support **parallel tool calls**: a single assistant turn may return several `ai:FunctionCall`
entries in `ai:ChatAssistantMessage.toolCalls`. When such a turn is sent back as history, each call is correlated
with its result through the tool call `id`, so an `ai:ChatFunctionMessage` per call must carry the matching `id`.

### Embeddings

`EmbeddingProvider` implements `ai:EmbeddingProvider` for Azure OpenAI embedding models. It reads the service URL and
`apiVersion` the same way as `OpenAiModelProvider`, so one service URL means the same thing to both providers:

```ballerina
// Legacy service URL: a date-based `apiVersion` is required.
final ai:EmbeddingProvider legacyEmbeddingProvider = check new azure:EmbeddingProvider(
    "https://<resource>.openai.azure.com/openai", "api-key", "2023-05-15", "deployment-id");

// v1 GA service URL: the `apiVersion` is not needed, so pass `()`.
final ai:EmbeddingProvider embeddingProvider = check new azure:EmbeddingProvider(
    "https://<resource>.openai.azure.com/openai/v1", "api-key", (), "deployment-id");
```

### Knowledge base

`AiSearchKnowledgeBase` implements `ai:KnowledgeBase` on an Azure AI Search index. Pass the name of an existing
index, or a `search:SearchIndex` definition to create; a new index must contain one key field of type `string`. By
default documents are chunked with `ai:AUTO`, the main content is read from the `content` field, and requests use the
Azure AI Search API version `2025-09-01`. `searchClientConnectionConfig` applies to the service client, which checks
or creates the index, and `indexClientConnectionConfig` to the index client, which ingests, retrieves and deletes
documents.

```ballerina
final ai:KnowledgeBase knowledgeBase = check new azure:AiSearchKnowledgeBase(
    "https://<service>.search.windows.net", "api-key", "index-name", embeddingProvider);
```

### Authentication

`OpenAiModelProvider`, `EmbeddingProvider` and `AiSearchKnowledgeBase` take the same `auth` parameter, their second
argument. It is either an API key, sent as the `api-key` header, or a Microsoft Entra ID credential from the
`ai.azure.identity` module, sent as an `Authorization: Bearer` token:

```ballerina
import ballerinax/ai.azure.identity;

// API key
final ai:ModelProvider apiKeyModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com/openai/v1", "api-key", "deployment-id");

// Keyless: the default Azure credential (Azure CLI sign-in locally, managed identity in Azure)
final ai:ModelProvider keylessModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com/openai/v1", {'type: "default"}, "deployment-id");

// A user-assigned managed identity for embeddings
final ai:EmbeddingProvider keylessEmbeddings = check new azure:EmbeddingProvider(
    "https://<resource>.openai.azure.com/openai/v1", {'type: "managedIdentity", clientId: "<client-id>"}, (),
    "embedding-deployment-id");

// One credential, and its token cache, shared by several providers
final identity:TokenCredential credential = check identity:createCredential({'type: "managedIdentity"});
final ai:KnowledgeBase keylessKnowledgeBase = check new azure:AiSearchKnowledgeBase(
    "https://<service>.search.windows.net", credential, "index-name", keylessEmbeddings);
```

A credential is a record whose `type` field selects it, or an `identity:TokenCredential` such as one from
`identity:createCredential`. The `ai.azure.identity` module describes each type's settings:

| `type` | Credential | Settings |
| --- | --- | --- |
| `default` | Environment, workload identity, managed identity, then developer tools such as the Azure CLI | `sources`, `clientId` |
| `managedIdentity` | Managed identity on Azure compute and Microsoft Foundry hosted agents | `clientId` (user-assigned) |
| `clientSecret` | Service principal with a client secret | `tenantId`, `clientId`, `clientSecret` |
| `workloadIdentity` | Kubernetes workload identity (federated token file) | `tenantId`, `clientId`, `tokenFilePath` |
| `clientCertificate` | Service principal with a certificate | `tenantId`, `clientId`, `certificatePath`, `certificatePassword`, `sendCertificateChain` |

With a credential:

- The token scope is derived from the service URL. For any other host, such as an API Management gateway or a
  custom domain, set `tokenScope`: in the connection configuration of `OpenAiModelProvider`
  (`OpenAiModelConnectionConfig`) and `EmbeddingProvider` (`EmbeddingConnectionConfig`), and as the `tokenScope`
  parameter of `AiSearchKnowledgeBase`.

  | Service URL | Token scope |
  | --- | --- |
  | path contains `/api/projects/` (a Foundry project endpoint) | `https://ai.azure.com/.default` |
  | `*.openai.azure.com`, `*.cognitiveservices.azure.com`, `*.services.ai.azure.com` | `https://cognitiveservices.azure.com/.default` |
  | `*.search.windows.net` | `https://search.azure.com/.default` |

- The service URL must use `https://`. `http://` is accepted only for a loopback host (`localhost`, `127.0.0.0/8`
  or `[::1]`), so a bearer token is never sent in clear text over the network.
- Token requests use the provider's `proxy` (HTTP proxies only); `AiSearchKnowledgeBase` uses the proxy of
  `searchClientConnectionConfig`, or of `indexClientConnectionConfig` if only that one has one. They don't use the
  provider's `secureSocket`, which describes the service endpoint: they trust the JVM's default certificates plus
  those in the file named by the `SSL_CERT_FILE` environment variable. For other TLS settings on token requests,
  create the credential with `identity:createCredential(config, secureSocket = ...)` and pass the resulting
  `identity:TokenCredential`.
- Proxy authentication (`userName`/`password`) for token requests needs Basic authentication for HTTPS tunnels,
  which the JDK disables by default: start the JVM with `-Djdk.http.auth.tunneling.disabledSchemes=`.
- Other clouds (for example Azure Government): create the credential with `identity:createCredential` and that
  cloud's `authorityHost`, pass the `identity:TokenCredential`, and set `tokenScope`.

The identity needs these Azure roles:

| Provider and operation | Role |
| --- | --- |
| `OpenAiModelProvider`, `EmbeddingProvider` | Cognitive Services OpenAI User, on the Azure OpenAI resource |
| `AiSearchKnowledgeBase`: initialization, which reads the index definition, or creates or updates the index | Search Service Contributor |
| `AiSearchKnowledgeBase`: `retrieve` | Search Index Data Reader |
| `AiSearchKnowledgeBase`: `ingest` and `deleteByFilter` | Search Index Data Contributor |

So a knowledge base that only queries an existing index needs Search Service Contributor and Search Index Data
Reader, and one that also ingests documents needs Search Service Contributor and Search Index Data Contributor. An
Azure AI Search service accepts only API keys by default: set its API access control to **Role-based access control**
or **Both** before using a credential.

## Prerequisites

Before using this module, obtain the following:

- Ballerina Swan Lake Update 14 or later.
- An [Azure account](https://azure.microsoft.com/).
- An [Azure OpenAI resource](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/how-to/create-resource)
  with a model deployment.
- Either an API key of that resource, or, for keyless authentication, an identity with the
  [Cognitive Services OpenAI User role](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/how-to/role-based-access-control)
  on it.
- For `AiSearchKnowledgeBase`, an
  [Azure AI Search service](https://learn.microsoft.com/en-us/azure/search/search-create-service-portal), with
  either an [API key](https://learn.microsoft.com/en-us/azure/search/search-security-api-keys) or
  [role-based access](https://learn.microsoft.com/en-us/azure/search/search-security-rbac).

## Quickstart

To use the `ai.azure` module, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.azure` module.

```ballerina
import ballerinax/ai.azure;
```

### Step 2: Initialize the Model Provider

Initialize the provider. By default it uses the Chat Completions API. On a legacy (non-`/v1`) service URL a
date-based `apiVersion` is required:

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com/openai", "api-key", "deployment-id", "2024-10-21");
```

To use the Responses API instead, set `apiType` to `RESPONSES`:

```ballerina
final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com/openai", "api-key", "deployment-id", "2025-03-01-preview",
    apiType = azure:RESPONSES);
```

To target the Azure OpenAI **v1 GA** surface, use a `/v1`-suffixed service URL; the `apiVersion` is then optional
and can be omitted:

```ballerina
final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com/openai/v1", "api-key", "deployment-id");
```

### Step 3: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```

## Run as a Foundry hosted agent

The module can also run your agent as a [Microsoft Foundry hosted agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/deploy-hosted-agent)
that speaks the Foundry **Invocations** protocol over HTTP. Attach an `azure:FoundryInvocationService` to an
`azure:FoundryListener`; the service contains only your agent logic.

```ballerina
import ballerina/http;
import ballerinax/ai.azure;

listener azure:FoundryListener foundryListener = new; // the PORT environment variable, else 8088

service azure:FoundryInvocationService on foundryListener {
    resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx)
            returns json|error {
        string message = check payload.message;
        return {reply: message, sessionId: ctx.sessionId};
    }

    resource function get readiness() returns json => {status: "healthy"};
}
```

The listener handles the container contract Foundry expects:

- `GET /readiness` (and `HEAD`), served by your `get readiness` resource. Return `()` (or declare no return
  type) for the default `200 {"status":"healthy"}`, or a status-code record such as `http:ServiceUnavailable`
  to report the container as not ready. Readiness responses are never classified with
  `x-platform-error-source`; an error your readiness resource returns is a `500`.
- The session ID (the `agent_session_id` query parameter, else `FOUNDRY_AGENT_SESSION_ID`, else a generated
  UUID) and the invocation ID, passed to your resource in `azure:FoundryContext`.
- The platform request headers, read into `azure:FoundryContext`: `userId` (`x-agent-user-id`), `callId`
  (`x-agent-foundry-call-id`), `clientHeaders` (every `x-client-*` header), `originalSubject`
  (`x-ms-original-subject`), the trace headers and the `FOUNDRY_*` environment variables (`agent`).
- The response headers `x-platform-server`, `x-request-id`, `x-agent-invocation-id` and (on
  `POST /invocations`) `x-agent-session-id`.
- Errors, in the envelope `{"error":{"code":...,"message":...}}` with an `x-platform-error-source` header: an
  error your resource returns becomes a `500` with the message `Internal server error`, classified as
  `upstream`; a body that can't be bound to the payload type is a `400` classified as `user`; a failure of
  the listener itself is a `500` classified as `platform`.
- Graceful shutdown, with a timeout from `AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` (30 seconds by
  default). A graceful stop currently waits the full timeout even when no request is in flight.

The service declares these resources, and the compiler plugin checks them:

| Resource | Parameters (each optional, any order) | Returns |
| --- | --- | --- |
| `post invocations` (required) | `@http:Payload` of `json`, `string`, `byte[]`, `xml` or another `anydata` type; `azure:FoundryContext` | `anydata` (`200`), `()` (`202`), `http:Response`, an `http:StatusCodeResponse`, `error`, or a union of these |
| `get readiness` (required) | none | as above, except that `()` is `200` with `{"status":"healthy"}` |
| `get invocations/[string invocationId]` | `azure:FoundryContext` | as above |
| `post invocations/[string invocationId]/cancel` | `@http:Payload`; `azure:FoundryContext` | as above |

The service must be attached at the root base path. Streaming responses (server-sent events) are not
supported.

When your agent calls a Foundry platform service through the project endpoint (`FOUNDRY_PROJECT_ENDPOINT`,
for example storage, the toolbox (MCP) proxy or A2A), forward the platform headers of the invocation with
`azure:foundryPlatformHeaders(ctx)`, next to your managed-identity `Authorization` header. It returns the
opaque `x-agent-foundry-call-id` when the request carried one (never parse it), and never the user ID, which
platform services don't trust. The listener doesn't forward these headers for you.

```ballerina
map<string|string[]> headers = azure:foundryPlatformHeaders(ctx);
headers["Authorization"] = string `Bearer ${token}`;
json result = check projectClient->post("/storage/items", payload, headers);
```

Example:

- [Foundry hosted agent with Azure OpenAI](examples/foundry-hosted-agent): an `ai:Agent` with
  per-session memory, a Dockerfile for a `linux/amd64` image and the deployment steps.

Version 1.6.0 of this module, which adds the listener, requires Ballerina Swan Lake Update 14 (2201.14.x)
or later.

### Tracing

When Ballerina tracing is enabled, the listener adds the Foundry attributes the reference uses to the spans of
`POST /invocations` and the get and cancel routes. Enable tracing as for any Ballerina program: set
`observabilityIncluded = true` under `[build-options]` in `Ballerina.toml`, import a tracing extension (for
example `import ballerinax/jaeger as _;`) and enable it in `Config.toml`:

```toml
[ballerina.observe]
tracingEnabled = true
tracingProvider = "jaeger"
```

The request span and the span of your resource get `microsoft.foundry` (`True`),
`azure.ai.agentserver.invocations.invocation_id`, `azure.ai.agentserver.invocations.session_id` and
`microsoft.session.id`, and, when configured, `microsoft.foundry.project.id` (`FOUNDRY_PROJECT_ARM_ID`),
`gen_ai.agent.name`, `gen_ai.agent.version`, `gen_ai.agent.id`, `microsoft.a365.agent.blueprint.id` and
`microsoft.tenant.id`. An error response adds `azure.ai.agentserver.invocations.error.code` (the code only,
never the message) to the request span. Spans started inside your resource, such as a model provider's
calls, don't get these attributes, and no `baggage` header is added to outbound requests. With tracing
disabled the listener builds no attributes.

### Differences from the Microsoft Python reference

The listener follows the Microsoft `azure-ai-agentserver-invocations` Python library (the reference), with a
few differences. For example: a `4xx`/`5xx` response your resource returns is classified as `upstream`
(the reference leaves it unclassified); the request body is bound to the declared payload type, and a body
that doesn't fit is a `400` classified as `user`; the `404`/`405` bodies use the error envelope instead of
plain text; and a graceful stop always waits the full timeout. The WebSocket transport, streaming
responses and the Responses protocol are not included.
