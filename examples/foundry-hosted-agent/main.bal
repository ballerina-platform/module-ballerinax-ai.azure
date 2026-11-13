// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
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

import ballerina/ai;
import ballerina/http;
import ballerinax/ai.azure;

// Azure OpenAI connection settings, from Config.toml or BAL_CONFIG_VAR_* environment variables.
configurable string serviceUrl = ?;
configurable string apiKey = ?;
configurable string deploymentId = ?;
// Required for a legacy service URL (`https://<resource>.openai.azure.com/openai`); ignored for a
// v1 service URL (`.../openai/v1`).
configurable string apiVersion = "2024-10-21";

final ai:Agent agent = check new ({
    systemPrompt: {
        role: "Helpful Assistant",
        instructions: "You are a helpful assistant running as a Microsoft Foundry hosted agent. "
            + "Answer concisely."
    },
    model: check new azure:OpenAiModelProvider(serviceUrl, apiKey, deploymentId, apiVersion),
    // In-memory conversation history, kept per memory key (see below). It is lost on restart and
    // not shared between replicas; use a persistent `ai:ShortTermMemoryStore` in production.
    memory: check new ai:ShortTermMemory()
});

// Listens on the port in the `PORT` environment variable, else on 8088.
listener azure:FoundryListener foundryListener = new;

service azure:FoundryInvocationService on foundryListener {

    // Required. Serves the `GET /readiness` probe. Keep it cheap: Foundry calls it often, and any
    // status other than 2xx takes the container out of rotation. It never calls the model.
    resource function get readiness() returns json => {status: "healthy"};

    resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx)
            returns json|error {
        string message = check payload.message;
        // Keep a separate history per session and, when Foundry sends one, per user.
        string? userId = ctx.userId;
        string memoryKey = userId is string ? string `${userId}:${ctx.sessionId}` : ctx.sessionId;
        // A failed model call is returned as an error, which the listener answers with a 500.
        string reply = check agent.run(message, memoryKey);
        return {reply, sessionId: ctx.sessionId, invocationId: ctx.invocationId};
    }
}
