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

listener azure:FoundryListener foundryListener = new (18001);
listener azure:FoundryListener untypedListener = new (18002);
listener azure:FoundryListener emptyListener = new (18003);

// Only `post invocations`: nothing serves the readiness probe.
service azure:FoundryInvocationService on foundryListener {
    resource function post invocations() returns json => {};
}

// A declaration without a type descriptor on a Foundry listener.
service on untypedListener {
    resource function post invocations() returns json => {};
}

// Neither required resource.
service azure:FoundryInvocationService on emptyListener {
}

isolated service class AgentService {
    *azure:FoundryInvocationService;

    isolated resource function post invocations() returns json => {};
}

final azure:FoundryInvocationService agentObject = service object {
    resource function post invocations() returns json => {};
};
