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

import ballerinax/ai.azure;

listener azure:FoundryListener pathListener = new (13001);
listener azure:FoundryListener literalListener = new (13002);

service azure:FoundryInvocationService /agents/v1 on pathListener {
    resource function post invocations() returns json => {};

    resource function get readiness() returns json => {status: "healthy"};
}

service azure:FoundryInvocationService "agent" on literalListener {
    resource function post invocations() returns json => {};

    resource function get readiness() returns json => {status: "healthy"};
}

listener azure:FoundryListener escapedListener = new (13003);
listener azure:FoundryListener untypedListener = new (13004);

// The value of the literal ("/a"), not its text, is what is checked.
service azure:FoundryInvocationService "\u{2F}a" on escapedListener {
    resource function post invocations() returns json => {};

    resource function get readiness() returns json => {status: "healthy"};
}

// A declaration without a type descriptor is still checked.
service /api on untypedListener {
    resource function post invocations() returns json => {};

    resource function get readiness() returns json => {status: "healthy"};
}
