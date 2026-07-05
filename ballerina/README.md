## Overview

This module offers APIs for connecting with Azure OpenAI Large Language Models (LLM).

It provides a single chat-model provider class, `OpenAiModelProvider`, which implements `ai:ModelProvider`. The
provider can target either the Azure OpenAI **Chat Completions API** (the default) or the **Responses API**,
selected at initialization time through the `apiType` parameter. The concrete wire route additionally depends on
the shape of the `serviceUrl`: a URL ending with `/v1` (e.g. `https://<resource>.openai.azure.com/openai/v1`)
targets the Azure OpenAI **v1 GA** surface through the generated `ballerinax/azure.openai.chat` /
`ballerinax/azure.openai.responses` connectors, while any other URL targets the **legacy** route (with an
`?api-version=...` query parameter).

| `apiType` | `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
| --- | --- | --- |
| `CHAT_COMPLETION` (default) | `POST {serviceUrl}/chat/completions` | `POST {serviceUrl}/openai/deployments/{deploymentId}/chat/completions?api-version=...` |
| `RESPONSES` | `POST {serviceUrl}/responses` | `POST {serviceUrl}/openai/responses?api-version=...` |

The `apiVersion` argument is **required** for legacy (non-`/v1`) service URLs (e.g. `"2024-10-21"`). For v1 (`/v1`)
service URLs it is optional and normally omitted; pass `"preview"` or `"v1"` to opt into a specific v1 surface.

This module also provides an `EmbeddingProvider` for Azure OpenAI embedding models.

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
    "https://<resource>.openai.azure.com/openai/v1", "api-key", "deployment-id");
```

### Step 4: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```
