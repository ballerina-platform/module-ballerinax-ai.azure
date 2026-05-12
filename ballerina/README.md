## Overview

This module offers APIs for connecting with Azure OpenAI Large Language Models (LLM).

It provides two chat-model provider classes, both of which implement `ai:ModelProvider` and automatically try the
Azure OpenAI **Responses API** first, falling back to the **Chat Completions API** when the targeted model or
API version does not support it:

| Provider | Azure OpenAI API surface | `apiVersion` |
| --- | --- | --- |
| `OpenAiModelProvider` | Legacy, deployment-scoped routes (`/openai/deployments/{deploymentId}/chat/completions`, `/openai/responses`) | Required date-based version, e.g. `"2024-08-01-preview"` |
| `OpenAiModelProviderV2` | v1 (GA) routes (`/openai/v1/chat/completions`, `/openai/v1/responses`) | Optional; only `"v1"` / `"preview"` are honored |

`OpenAiModelProvider` keeps the same public API as previous releases (with the addition of the optional
`reasoningEffort` parameter), so existing code continues to work unchanged. New applications targeting the Azure
OpenAI v1 (GA) API surface should prefer `OpenAiModelProviderV2`.

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

Initialize the legacy provider (deployment-scoped routes, date-based `api-version`):

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id", "2024-08-01-preview");
```

Or initialize the v1 (GA) provider:

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModelV2 = check new azure:OpenAiModelProviderV2(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id");
```

### Step 4: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```
