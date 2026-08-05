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

// Prompt-content "trigger" markers. A test drives an edge-case wire response by sending a user message whose
// content begins with one of these markers; the mock services (`test_services.bal`) match on the marker and
// return a response shaped to exercise a specific response-handling branch. Ordinary prompts never begin with
// these markers, so normal tests are unaffected.

// ===== Chat Completions triggers =====
const TRIGGER_STREAMING = "TRIGGER_STREAMING";
const TRIGGER_EMPTY_CHOICES = "TRIGGER_EMPTY_CHOICES";
const TRIGGER_FUNCTION_CALL = "TRIGGER_FUNCTION_CALL";
const TRIGGER_BAD_TOOL_ARGS = "TRIGGER_BAD_TOOL_ARGS";

// Parallel tool calling. Unlike the markers above, these are matched *before* the mock's generic
// "tools present -> return one get_weather call" branch, because they must override it.
// `TRIGGER_PARALLEL_TOOL_CALLS` returns two `tool_calls` in one response; `TRIGGER_PARALLEL_HISTORY` asserts that a
// history carrying two tool calls and their two results is reconstructed correctly on the wire.
const TRIGGER_PARALLEL_TOOL_CALLS = "TRIGGER_PARALLEL_TOOL_CALLS";
const TRIGGER_PARALLEL_HISTORY = "TRIGGER_PARALLEL_HISTORY";

// ===== Responses API triggers =====
// The `_NOERR`/`_NODETAIL` variants MUST be listed before their base marker in the mock's dispatch, since the
// base marker is a prefix of the variant.
const TRIGGER_STATUS_FAILED = "TRIGGER_STATUS_FAILED";
const TRIGGER_STATUS_FAILED_NOERR = "TRIGGER_STATUS_FAILED_NOERR";
const TRIGGER_STATUS_INCOMPLETE = "TRIGGER_STATUS_INCOMPLETE";
const TRIGGER_STATUS_INCOMPLETE_NODETAIL = "TRIGGER_STATUS_INCOMPLETE_NODETAIL";
const TRIGGER_STATUS_CANCELLED = "TRIGGER_STATUS_CANCELLED";
const TRIGGER_STATUS_INPROGRESS = "TRIGGER_STATUS_INPROGRESS";
const TRIGGER_STATUS_QUEUED = "TRIGGER_STATUS_QUEUED";
const TRIGGER_EMPTY_OUTPUT = "TRIGGER_EMPTY_OUTPUT";
const TRIGGER_BAD_ARGS = "TRIGGER_BAD_ARGS";
const TRIGGER_OUTPUT_MESSAGE = "TRIGGER_OUTPUT_MESSAGE";
const TRIGGER_CONTENT_AND_TOOL = "TRIGGER_CONTENT_AND_TOOL";

// ===== generate() (getResults tool) triggers =====
// These bypass the strict schema/content validation of the normal generate() path so that a direct-call test can
// drive the argument-parsing error branches (invalid JSON, and valid JSON of the wrong type).
const TRIGGER_GEN_BAD_ARGS = "TRIGGER_GEN_BAD_ARGS";
const TRIGGER_GEN_TYPE_MISMATCH = "TRIGGER_GEN_TYPE_MISMATCH";
const TRIGGER_GEN_EMPTY_CHOICES = "TRIGGER_GEN_EMPTY_CHOICES";

// Responses: a function_call whose arguments are valid JSON but not a JSON object (exercises the
// arguments-to-map conversion failure branch of the chat() output converter).
const TRIGGER_ARGS_NOT_OBJECT = "TRIGGER_ARGS_NOT_OBJECT";

// ===== Embeddings trigger =====
const EMPTY_EMBED_TRIGGER = "EMPTY_EMBED_TRIGGER";
