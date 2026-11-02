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

// Providers used by the Azure Anthropic (Claude) tests.

// A path-carrying service URL, which is used verbatim (`{serviceUrl}/v1/messages`).
const ANTHROPIC_SERVICE_URL = "http://localhost:8080/llm/azureanthropic/anthropic";
// The bare origin form: the provider completes it with `/anthropic`, exactly as it completes a bare Azure
// resource origin (`https://<resource>.services.ai.azure.com`).
const ANTHROPIC_ORIGIN_URL = "http://localhost:8080";

// The default provider: no temperature, no thinking, no effort - the shape that works on every Claude model.
final AnthropicModelProvider anthropicProvider =
    check new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_DEPLOYMENT);

// Reached through the bare-origin service URL.
final AnthropicModelProvider anthropicOriginProvider =
    check new (ANTHROPIC_ORIGIN_URL, API_KEY, ANTHROPIC_DEPLOYMENT);

// Adaptive thinking, the mode available on Claude Opus 4.6 / Sonnet 4.6 and later. Each thinking provider uses
// its own deployment so the mock can pin the exact `thinking` object it must produce.
final AnthropicModelProvider anthropicAdaptiveThinkingProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_ADAPTIVE_THINKING_DEPLOYMENT, thinking = {'type: "adaptive", display: "summarized"});

// Manual extended thinking, the only mode on Claude Sonnet 4.5 / Opus 4.5 / Haiku 4.5.
final AnthropicModelProvider anthropicExtendedThinkingProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_EXTENDED_THINKING_DEPLOYMENT, maxTokens = 8192, thinking = {'type: "enabled", budgetTokens: 2048});

// Thinking explicitly turned off. This is the only mode a `temperature` may be combined with.
final AnthropicModelProvider anthropicDisabledThinkingProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_DISABLED_THINKING_DEPLOYMENT, thinking = {'type: "disabled"});

// `output_config.effort` reaches the wire.
final AnthropicModelProvider anthropicEffortProvider =
    check new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_EFFORT_DEPLOYMENT, effort = "xhigh");

// A configured `temperature` reaches the wire (accepted by Claude 4.6 and earlier when thinking is off); the
// mock pins the exact value for this deployment.
final AnthropicModelProvider anthropicTemperatureProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_TEMPERATURE_DEPLOYMENT, temperature = ANTHROPIC_EXPECTED_TEMPERATURE);

// The newer Claude models reject `temperature`, so the field must stay off the wire by default.
final AnthropicModelProvider anthropicNoTemperatureProvider =
    check new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_NO_TEMPERATURE_DEPLOYMENT);

// Pins the configured `maxTokens` on the wire.
final AnthropicModelProvider anthropicCustomTokensProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    CUSTOM_TOKENS_DEPLOYMENT, maxTokens = CUSTOM_MAX_TOKENS);

// An endpoint with nothing listening, to drive the connection-failure branches.
final AnthropicModelProvider anthropicUnreachableProvider =
    check new ("http://localhost:8099/nowhere/anthropic", API_KEY, ANTHROPIC_DEPLOYMENT);

// Sends a non-default `anthropic-version` header.
final AnthropicModelProvider anthropicCustomVersionProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_CUSTOM_VERSION_DEPLOYMENT, anthropicVersion = ANTHROPIC_CUSTOM_VERSION);

// Asserts that system messages reach the request's top-level `system` field.
final AnthropicModelProvider anthropicSystemProvider =
    check new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_SYSTEM_DEPLOYMENT);

// Carries a custom HTTP connection configuration.
final AnthropicModelProvider anthropicCustomConnectionProvider = check new (ANTHROPIC_SERVICE_URL, API_KEY,
    ANTHROPIC_DEPLOYMENT, timeout = 120, forwarded = "enable");

// Used to prove a blank stop sequence never reaches the wire; the mock asserts `stop_sequences` is absent for
// this deployment.
final AnthropicModelProvider anthropicNoStopProvider =
    check new (ANTHROPIC_SERVICE_URL, API_KEY, ANTHROPIC_NO_STOP_DEPLOYMENT);
