## Overview

Azure OpenAI Service provides access to OpenAI's powerful language models within the Microsoft Azure platform.

The Azure OpenAI connector offers APIs for connecting with Azure OpenAI Large Language Models (LLMs), enabling the integration of advanced conversational AI, text generation, and language processing capabilities into applications.

### Key Features

- Connect and interact with Azure OpenAI Large Language Models (LLMs)
- Support for GPT-5, GPT-4, GPT-3.5, and other advanced OpenAI models
- Support for both the Chat Completions API and the Responses API, selected through the `apiType` parameter
- Seamless integration with Azure AI infrastructure
- Secure communication with API key and token authentication

### API surfaces

It provides a single chat-model provider class, `OpenAiModelProvider`, which implements `ai:ModelProvider`. The
provider can target either the Azure OpenAI **Chat Completions API** (the default) or the **Responses API**,
selected at initialization time through the `apiType` parameter. The concrete wire route additionally depends on
the shape of the `serviceUrl`: a URL ending with `/v1` targets the Azure OpenAI **v1 GA** surface through the
generated `ballerinax/azure.openai.chat` / `ballerinax/azure.openai.responses` connectors, while any other URL
targets the **legacy** route (with an `?api-version=...` query parameter).

The new v1 GA URL is `https://<resource>.services.ai.azure.com/openai/v1`; the legacy URL is
`https://<resource>.openai.azure.com/openai`.

| `apiType` | `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
| --- | --- | --- |
| `CHAT_COMPLETIONS` (default) | `POST {serviceUrl}/chat/completions` | `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version=...` |
| `RESPONSES` | `POST {serviceUrl}/responses` | `POST {legacyBase}/responses?api-version=...` |

On the legacy surface, `legacyBase` is derived from the `serviceUrl` as follows:

- a **bare origin** (e.g. `https://<resource>.openai.azure.com`) is completed with `/openai`, matching Azure's own
  legacy spec server (`https://{endpoint}/openai`);
- a URL that **already carries a path** is used **verbatim**. This keeps existing `.../openai` service URLs working
  unchanged, and lets callers who front Azure OpenAI through API Management or another gateway
  (e.g. `https://gw.example.com/azure-openai`) own their base path without the module rewriting it.

The `apiVersion` argument is **required** for legacy (non-`/v1`) service URLs (e.g. `"2024-10-21"`). For v1 (`/v1`)
service URLs it is optional and normally omitted; pass `"preview"` or `"v1"` to opt into a specific v1 surface.

This module also provides an `EmbeddingProvider` for Azure OpenAI embedding models. It resolves the `apiVersion` and
the legacy base URL exactly the same way, so one `serviceUrl` means the same thing to both providers:

| `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
| --- | --- |
| `POST {serviceUrl}/embeddings` (deployment sent as `model` in the body) | `POST {legacyBase}/deployments/{deploymentId}/embeddings?api-version=...` |

```ballerina
// Legacy service URL — a date-based `apiVersion` is required.
final ai:EmbeddingProvider legacyEmbeddingProvider = check new azure:EmbeddingProvider(
    "https://<resource>.openai.azure.com/openai", "api-key", "2023-05-15", "deployment-id");

// v1 GA service URL — the `apiVersion` is not needed, so pass `()`.
final ai:EmbeddingProvider embeddingProvider = check new azure:EmbeddingProvider(
    "https://<resource>.services.ai.azure.com/openai/v1", "api-key", (), "deployment-id");
```

## Prerequisites

Before using this module in your Ballerina application, first you must obtain the nessary configuration to engage the LLM.

- Create an [Azure](https://azure.microsoft.com/en-us/features/azure-portal/) account.
- Create an [Azure OpenAI resource](https://learn.microsoft.com/en-us/azure/cognitive-services/openai/how-to/create-resource).
- Obtain the tokens. Refer to the [Azure OpenAI Authentication](https://learn.microsoft.com/en-us/azure/cognitive-services/openai/reference#authentication) guide to learn how to generate and use tokens.

## Quickstart

To use the `ai.azure` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.azure;` module.

```ballerina
import ballerinax/ai.azure;
```

### Step 2: Intialize the Model Provider

Initialize the provider. By default it uses the Chat Completions API. On a legacy (non-`/v1`) service URL a
date-based `apiVersion` is required:

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id", "2024-10-21");
```

To use the Responses API instead, set `apiType` to `RESPONSES`:

```ballerina
final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id", "2025-03-01-preview",
    apiType = azure:RESPONSES);
```

To target the Azure OpenAI **v1 GA** surface, use a `/v1`-suffixed service URL; the `apiVersion` is then optional
and can be omitted:

```ballerina
final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.services.ai.azure.com/openai/v1", "api-key", "deployment-id");
```

### Step 4: Invoke chat completion

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
}
```

The listener handles the container contract Foundry expects:

- `GET /readiness`, answered with `{"status":"healthy"}` without calling your code.
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
| `get invocations/[string invocationId]` | `azure:FoundryContext` | as above |
| `post invocations/[string invocationId]/cancel` | `@http:Payload`; `azure:FoundryContext` | as above |

The service must be attached at the root base path. Streaming responses (server-sent events) are not
supported.

Example:

- [Foundry hosted agent with Azure OpenAI](https://github.com/ballerina-platform/module-ballerinax-ai.azure/tree/main/examples/foundry-hosted-agent): an `ai:Agent` with
  per-session memory, a Dockerfile for a `linux/amd64` image and the deployment steps.

Version 1.6.0 of this module, which adds the listener, requires Ballerina Swan Lake Update 14 (2201.14.x)
or later.

### Differences from the Microsoft Python reference

The listener follows the Microsoft `azure-ai-agentserver-invocations` Python library (the reference), with a
few differences. For example: a `4xx`/`5xx` response your resource returns is classified as `upstream`
(the reference leaves it unclassified); the request body is bound to the declared payload type, and a body
that doesn't fit is a `400` classified as `user`; the `404`/`405` bodies use the error envelope instead of
plain text; and a graceful stop always waits the full timeout. The WebSocket transport, streaming
responses and the Responses protocol are not included. See the [design document](https://github.com/ballerina-platform/module-ballerinax-ai.azure/blob/main/docs/proposals/foundry-hosted-agent-listener.md) for the
full list and the reasons.
