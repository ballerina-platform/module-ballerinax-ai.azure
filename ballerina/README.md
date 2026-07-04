## Overview

This module offers APIs for connecting with Azure OpenAI Large Language Models (LLM).

It provides a single chat-model provider class, `OpenAiModelProvider`, which implements `ai:ModelProvider`. The
provider can target either the Azure OpenAI **Responses API** or the **Chat Completions API**. The API surface is
selected at initialization time through the `apiType` parameter:

| `apiType` | Azure OpenAI API surface |
| --- | --- |
| `RESPONSES` (default) | `/openai/responses` (Responses API) |
| `CHAT_COMPLETION` | `/openai/deployments/{deploymentId}/chat/completions` (Chat Completions API) |

When `apiType` is omitted, the provider defaults to `RESPONSES`. Both surfaces are backed by the
`ballerinax/azure.openai.responses` and `ballerinax/azure.openai.chat` connectors respectively.

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

Initialize the provider. By default it uses the Responses API:

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id", "2024-08-01-preview");
```

To use the Chat Completions API instead, set `apiType` to `CHAT_COMPLETION`:

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider azureOpenAiModel = check new azure:OpenAiModelProvider(
    "https://<resource>.openai.azure.com", "api-key", "deployment-id", "2024-08-01-preview",
    apiType = azure:CHAT_COMPLETION);
```

### Step 4: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```
