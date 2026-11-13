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

import ballerina/http;
import ballerinax/ai.azure;

isolated service class AgentService {
    *azure:FoundryInvocationService;

    isolated resource function get invocations/[string invocationId]() returns json => {id: invocationId};

    isolated resource function get health() returns string => "ok";
}

final azure:FoundryInvocationService agentObject = service object {
    resource function post invocations(@http:Payload json payload, string extra) returns json => payload;

    resource function get readiness() returns json => {status: "healthy"};
};

// A service class of another service type is not validated.
service class PlainService {
    *http:Service;

    resource function get health() returns string => "ok";
}
