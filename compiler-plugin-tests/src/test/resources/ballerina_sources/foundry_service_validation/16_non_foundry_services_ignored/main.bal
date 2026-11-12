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

listener azure:FoundryListener foundryListener = new (16001);
listener http:Listener httpListener = new (16002);

// A valid Foundry service next to plain HTTP services, which may declare any resource.
service azure:FoundryInvocationService on foundryListener {
    resource function post invocations(@http:Payload json payload) returns json => payload;
}

service /api on httpListener {
    resource function post invocations(string extra) returns json => {extra};

    resource function get status() returns string => "ok";
}

service http:Service /other on httpListener {
    resource function get invocations/[int id]() returns int => id;
}

final http:Service plainObject = service object {
    resource function get health() returns string => "ok";
};
