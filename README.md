## Overview

Azure OpenAI Service provides access to OpenAI's powerful language models within the Microsoft Azure platform.

The Azure OpenAI connector offers APIs for connecting with Azure OpenAI Large Language Models (LLMs), enabling the integration of advanced conversational AI, text generation, and language processing capabilities into applications.

### Key Features

- Connect and interact with Azure OpenAI Large Language Models (LLMs)
- Support for the GPT-5 series, GPT-4 series, GPT-3.5, and other advanced OpenAI models
- Both the **Chat Completions API** and the **Responses API**, over both the **v1 GA** and **legacy** surfaces
- Parallel (multiple) tool calls in a single assistant turn, on both API surfaces
- Reasoning-effort control for reasoning models (`gpt-5`/`o`-series)
- Text embeddings through a dedicated `EmbeddingProvider`, over both the v1 GA and legacy surfaces
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
| `CHAT_COMPLETION` (default) | `POST {serviceUrl}/chat/completions` | `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version=...` |
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

### Tool calling

Both API surfaces support **parallel tool calls**: a single assistant turn may return several `ai:FunctionCall`
entries in `ai:ChatAssistantMessage.toolCalls`. When such a turn is sent back as history, each call is correlated
with its result through the tool call `id`, so an `ai:ChatFunctionMessage` per call must carry the matching `id`.

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
