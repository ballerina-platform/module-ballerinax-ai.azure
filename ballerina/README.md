## Overview

This module offers APIs for connecting with AzureOpenAI Large Language Models (LLM).

## Prerequisites

Before using this module in your Ballerina application, first you must obtain the nessary configuration to engage the LLM.

- Create an [Azure](https://azure.microsoft.com/en-us/features/azure-portal/) account.
- Create an [Azure OpenAI resource](https://learn.microsoft.com/en-us/azure/cognitive-services/openai/how-to/create-resource).
- Obtain the tokens. Refer to the [Azure OpenAI Authentication](https://learn.microsoft.com/en-us/azure/cognitive-services/openai/reference#authentication) guide to learn how to generate and use tokens.

## Quickstart

To use the `ai.model.provider.azure` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.model.provider.azure;` module.

```ballerina
import ballerinax/ai.model.provider.azure;
```

### Step 2: Intialize the Model Provider

Here's how to initialize the Model Provider:

```ballerina
import ballerina/ai;
import ballerinax/ai.model.provider.azure;

final ai:ModelProvider  azureOpenAiModel = check new azure:OpenAiProvider("https://service-url", "api-key", "deployment-id", "deployment-version");
```

### Step 4: Invoke chat completion

```
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```
