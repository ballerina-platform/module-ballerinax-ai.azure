## Overview

Microsoft Azure hosts both OpenAI's models (Azure OpenAI Service) and Anthropic's Claude models (Microsoft Foundry), and this module provides a Ballerina model provider for each.

The connector offers APIs for connecting with these Large Language Models (LLMs), enabling the integration of advanced conversational AI, text generation, and language processing capabilities into applications.

### Key Features

- Connect and interact with Azure-hosted Large Language Models (LLMs)
- **Azure OpenAI**: the GPT-5 series, GPT-4 series, GPT-3.5, and other advanced OpenAI models, through both the **Chat Completions API** and the **Responses API**, over both the **v1 GA** and **legacy** surfaces
- **Anthropic Claude in Microsoft Foundry**: the Claude models, through the **Anthropic Messages API**
- Parallel (multiple) tool calls in a single assistant turn, on every API surface
- Reasoning-effort control for reasoning models (`gpt-5`/`o`-series) and thinking/effort control for Claude models
- Text embeddings through a dedicated `EmbeddingProvider`, over both the v1 GA and legacy surfaces
- Seamless integration with Azure AI infrastructure
- Secure communication with API key and token authentication

### Model providers

| Class | Models | Wire API |
| --- | --- | --- |
| `OpenAiModelProvider` | Azure OpenAI (GPT-5/GPT-4/GPT-3.5, `o`-series) | Azure OpenAI Chat Completions or Responses API |
| `AnthropicModelProvider` | Claude models in Microsoft Foundry | Anthropic Messages API (`/v1/messages`) |
| `EmbeddingProvider` | Azure OpenAI embedding models | Azure OpenAI Embeddings API |

### Azure OpenAI API surfaces

`OpenAiModelProvider` implements `ai:ModelProvider`. The
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

### Anthropic (Claude) API surface

`AnthropicModelProvider` implements `ai:ModelProvider` for the Claude models deployed in Microsoft Foundry.
Those models are **not** served through an Azure OpenAI surface: they use Anthropic's own Messages API.

| | |
| --- | --- |
| Base URL | `https://<resource>.services.ai.azure.com/anthropic` |
| Route | `POST {serviceUrl}/v1/messages` |
| Authentication | the deployment's API key in the `x-api-key` header |
| API version | the `anthropic-version` header (default `"2023-06-01"`) — there is **no** `api-version` query parameter |
| `model` | the **deployment name** chosen at deployment time, which may differ from the model id |

The `serviceUrl` is normalised so that any of the shapes shown in the Foundry portal work: a bare resource origin
(`https://<resource>.services.ai.azure.com`) is completed with `/anthropic`, a `/v1` or `/v1/messages` suffix
copied from the deployment's target URI is trimmed, and a URL that already carries a path (for example an API
Management base path) is used verbatim.

```ballerina
import ballerina/ai;
import ballerinax/ai.azure;

final ai:ModelProvider claude = check new azure:AnthropicModelProvider(
    "https://<resource>.services.ai.azure.com/anthropic", "api-key", "claude-sonnet-4-6");
```

#### Model parameters

| Parameter | Notes |
| --- | --- |
| `maxTokens` | Required by the Messages API; defaults to `4096`. Thinking tokens count towards it. |
| `temperature` | Omitted unless set. **Leave it unset for Claude Opus 4.7 and later, Claude Sonnet 5 and Claude Fable 5**, which reject the parameter, and note that it cannot be combined with thinking (see below). |
| `thinking` | `{'type: "adaptive"}` on Claude Opus 4.6 / Sonnet 4.6 and later; `{'type: "enabled", budgetTokens: N}` (manual extended thinking) on Claude Sonnet 4.5 / Opus 4.5 / Haiku 4.5; `{'type: "disabled"}` to turn it off. Left off the wire when unset, so the deployed model applies its own default. |
| `effort` | Sent as `output_config.effort` (`"low"`/`"medium"`/`"high"`/`"xhigh"`/`"max"`). Support is per model: Claude Sonnet 4.5 and Claude Haiku 4.5 reject it, Claude Opus 4.5 accepts only `"low"`/`"medium"`/`"high"`, and `"xhigh"` arrived with Claude Opus 4.7. |
| `anthropicVersion` | The `anthropic-version` header value. |

```ballerina
final ai:ModelProvider claude = check new azure:AnthropicModelProvider(
    "https://<resource>.services.ai.azure.com/anthropic", "api-key", "claude-opus-5",
    maxTokens = 8192, thinking = {'type: "adaptive"}, effort = "high");
```

Two combinations are rejected by the Messages API and therefore fail at initialization rather than on the first
request:

- `temperature` together with thinking that is *on* (`"adaptive"` or `"enabled"`). The service rejects a sampling
  temperature while thinking is active, so pass one or the other, or set the thinking type to `"disabled"`.
- `{'type: "enabled"}` without a `budgetTokens` value, with a budget below 1024, or with a budget that is not
  less than `maxTokens` (thinking tokens count towards the response limit).

Manual extended thinking is additionally incompatible with the forced tool call that `generate()` has to make,
so it is omitted from `generate()` requests (a warning is logged at initialization). Adaptive thinking works with
`generate()` unchanged.

#### Supported input

Text, image (URL or binary data) and file documents — the Messages API takes PDFs as `document` content blocks —
are supported. Binary image and file content must carry its media type in `metadata.mimeType` (for example
`"image/png"` or `"application/pdf"`), because the Messages API takes the media type as its own field. Audio
documents are not supported by the Messages API.

#### Conversation mapping

The Messages API differs structurally from the OpenAI chat shape, and the provider bridges the difference:

- `ai:ChatSystemMessage`s are concatenated into the request's top-level `system` field rather than sent as turns.
- `ai:ChatFunctionMessage`s (tool results) become `tool_result` content blocks inside a **user** turn.
- Consecutive messages that map to the same role are merged into a single turn, which is what keeps the results
  of parallel tool calls together in one user turn.
- Blank content is dropped rather than sent: the Messages API rejects empty text blocks. An assistant message
  with neither content nor tool calls therefore produces no turn at all.
- The optional `name` field of `ai:ChatUserMessage` and `ai:ChatSystemMessage` is **not** forwarded, because the
  Messages API has no per-message name field.
- A conversation ending with an `ai:ChatAssistantMessage` is a *response prefill* on the Messages API. Claude
  Opus 4.6 / Sonnet 4.6 and later reject it, so end the message list with the user turn (or a tool result) when
  targeting those models.

### Tool calling

Every API surface supports **parallel tool calls**: a single assistant turn may return several `ai:FunctionCall`
entries in `ai:ChatAssistantMessage.toolCalls`. When such a turn is sent back as history, each call is correlated
with its result through the tool call `id`, so an `ai:ChatFunctionMessage` per call must carry the matching `id`.

## Prerequisites

Before using this module in your Ballerina application, first you must obtain the nessary configuration to engage the LLM.

- Create an [Azure](https://azure.microsoft.com/en-us/features/azure-portal/) account.
- For the OpenAI models, create an [Azure OpenAI resource](https://learn.microsoft.com/en-us/azure/cognitive-services/openai/how-to/create-resource).
- For the Claude models, deploy one in Microsoft Foundry. Refer to [Deploy and use Claude models in Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-claude); note the deployment's base URL and deployment name.
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

To use an Anthropic Claude deployment in Microsoft Foundry instead, initialize an `AnthropicModelProvider` with
the deployment's base URL and deployment name. No `apiVersion` is involved:

```ballerina
final ai:ModelProvider claudeModel = check new azure:AnthropicModelProvider(
    "https://<resource>.services.ai.azure.com/anthropic", "api-key", "claude-sonnet-4-6");
```

### Step 3: Invoke chat completion

Both providers implement `ai:ModelProvider`, so the call is the same:

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check azureOpenAiModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```
