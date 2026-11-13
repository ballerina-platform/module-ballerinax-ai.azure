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

listener azure:FoundryListener foundryListener = new (9401);

service azure:FoundryInvocationService on foundryListener {
    resource function post invocations() returns json => {};

    remote function ping() returns string => "pong";

    // A plain method is allowed: it is not part of the service's network interface.
    function helper() returns string => "helper";

    resource function get readiness() returns json => {status: "healthy"};
}
