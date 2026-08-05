// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Additional providers used by the reasoning-model, all-parameter, and edge-case coverage tests. Each targets a
// specific (apiType, surface) combination so that both the legacy and v1 GA paths are exercised.

// ===== Reasoning-model providers (temperature omitted, reasoning effort set) =====
// Chat Completions, legacy surface (a post-threshold api-version so the token limit is sent as
// `max_completion_tokens`, which reasoning models require).
final OpenAiModelProvider reasoningChatLegacyProvider = check new (SERVICE_URL, API_KEY, REASONING_DEPLOYMENT,
    NEW_API_VERSION, reasoningEffort = HIGH, temperature = (), apiType = CHAT_COMPLETION);

// Chat Completions, v1 GA surface.
final OpenAiModelProvider reasoningChatV1Provider = check new (SERVICE_URL_V1, API_KEY, REASONING_DEPLOYMENT,
    reasoningEffort = MEDIUM, temperature = (), apiType = CHAT_COMPLETION);

// Responses, legacy preview surface.
final OpenAiModelProvider reasoningResponsesLegacyProvider = check new (SERVICE_URL, API_KEY, REASONING_DEPLOYMENT,
    API_VERSION, reasoningEffort = LOW, temperature = (), apiType = RESPONSES);

// Responses, v1 GA surface.
final OpenAiModelProvider reasoningResponsesV1Provider = check new (SERVICE_URL_V1, API_KEY, REASONING_DEPLOYMENT,
    reasoningEffort = MINIMAL, temperature = (), apiType = RESPONSES);

// ===== Custom max-token providers (pin the exact token-limit value on the wire) =====
final OpenAiModelProvider customTokensChatProvider = check new (SERVICE_URL, API_KEY, CUSTOM_TOKENS_DEPLOYMENT,
    NEW_API_VERSION, maxTokens = CUSTOM_MAX_TOKENS, apiType = CHAT_COMPLETION);

final OpenAiModelProvider customTokensResponsesV1Provider = check new (SERVICE_URL_V1, API_KEY,
    CUSTOM_TOKENS_DEPLOYMENT, maxTokens = CUSTOM_MAX_TOKENS, apiType = RESPONSES);

// ===== v1 GA `preview`/`v1` api-version opt-in providers =====
final OpenAiModelProvider v1PreviewChatProvider = check new (SERVICE_URL_V1, API_KEY, DEPLOYMENT_ID,
    "preview", apiType = CHAT_COMPLETION);

final OpenAiModelProvider v1OptInResponsesProvider = check new (SERVICE_URL_V1, API_KEY, DEPLOYMENT_ID,
    "v1", apiType = RESPONSES);

// ===== providers whose endpoint is unreachable (drive the chat() connection-failure branches) =====
final OpenAiModelProvider unreachableChatProvider = check new ("http://localhost:8099/nowhere", API_KEY,
    DEPLOYMENT_ID, API_VERSION, apiType = CHAT_COMPLETION);

final OpenAiModelProvider unreachableResponsesProvider = check new ("http://localhost:8099/nowhere", API_KEY,
    DEPLOYMENT_ID, API_VERSION, apiType = RESPONSES);
