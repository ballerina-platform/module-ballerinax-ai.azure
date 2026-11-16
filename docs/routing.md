# Request routing

This page lists the HTTP requests that the `ballerinax/ai.azure` providers send for each configuration. The
package README covers how to choose an API; this page is for debugging, gateways and API Management policies.

## Chat model provider

`OpenAiModelProvider` selects the route from `apiType` and from the shape of the `serviceUrl`. A URL ending with `/v1`
targets the Azure OpenAI v1 GA surface; any other URL targets the legacy surface, with an `?api-version=...` query
parameter.

| `apiType` | `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
| --- | --- | --- |
| `CHAT_COMPLETIONS` (default) | `POST {serviceUrl}/chat/completions` | `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version=...` |
| `RESPONSES` | `POST {serviceUrl}/responses` | `POST {legacyBase}/responses?api-version=...` |

On the v1 GA surface the deployment is sent as `model` in the request body, and `api-version` is sent only when the
caller passes `"preview"` or `"v1"` as `apiVersion`.

## Embedding provider

`EmbeddingProvider` uses the same rules:

| `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
| --- | --- |
| `POST {serviceUrl}/embeddings` (deployment sent as `model` in the body) | `POST {legacyBase}/deployments/{deploymentId}/embeddings?api-version=...` |

## The legacy base URL

On the legacy surface, `legacyBase` is derived from the `serviceUrl`:

- A bare origin (for example `https://<resource>.openai.azure.com`) is completed with `/openai`, matching Azure's own
  legacy spec server (`https://{endpoint}/openai`).
- A URL that already has a path is used verbatim. This keeps existing `.../openai` service URLs working unchanged,
  and lets callers who front Azure OpenAI through API Management or another gateway (for example
  `https://gw.example.com/azure-openai`) own their base path without the module rewriting it.

## Authentication headers and clients

An API key is sent as the `api-key` header and a Microsoft Entra ID credential as `Authorization: Bearer <token>`;
a request never carries both.

The generated `ballerinax/azure.openai.*` connectors can only send the `api-key` header, so some routes use a raw
HTTP client with the same request body:

| Route | API key | Credential |
| --- | --- | --- |
| Chat Completions and Responses, v1 GA | Generated connector | Raw HTTP client |
| Chat Completions and Responses, legacy | Raw HTTP client | Raw HTTP client |
| Embeddings, v1 GA | Raw HTTP client | Raw HTTP client |
| Embeddings, legacy | Generated connector | Raw HTTP client |

`AiSearchKnowledgeBase` always uses the generated `ballerinax/azure.ai.search` and `ballerinax/azure.ai.search.index`
connectors, and adds the authentication header to each call:

| Operation | Request | Client |
| --- | --- | --- |
| Initialization with an index name | `GET {serviceUrl}/indexes('{name}')` | Service client |
| Initialization with a `search:SearchIndex` | `PUT {serviceUrl}/indexes('{name}')` | Service client |
| `ingest` | `POST {serviceUrl}/indexes('{name}')/docs/search.index` | Index client |
| `retrieve` | `POST {serviceUrl}/indexes('{name}')/docs/search.post.search` | Index client |
| `deleteByFilter` | `POST .../docs/search.post.search`, then `POST .../docs/search.index` | Index client |

Each request carries `?api-version=...` (by default `2025-09-01`).
