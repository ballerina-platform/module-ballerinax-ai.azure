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

import ballerina/http as h;
import ballerinax/ai.azure as foundry;

listener foundry:FoundryListener foundryListener = new (14001);

service foundry:FoundryInvocationService on foundryListener {
    resource function post invocations(@h:Payload json payload, foundry:FoundryContext ctx, string extra)
            returns json|h:Response => payload;

    resource function get status() returns string => "ok";

    resource function get readiness(foundry:FoundryContext ctx) returns h:Response => new;
}
