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

# A listener that runs a `FoundryInvocationService` as a Microsoft Foundry hosted agent.
#
# The listener serves the Foundry Invocations protocol over HTTP: `POST /invocations`, the
# optional get and cancel routes, and the `GET /readiness` probe. It resolves session and
# invocation IDs, reads the platform headers into a `FoundryContext`, sets the platform response
# headers and classifies errors, so the attached service contains only agent logic.
public isolated class FoundryListener {
    private final http:Listener httpListener;

    # Initializes the listener.
    #
    # + listenOn - The port to listen on, or an existing `http:Listener` to share. When it is not
    # given, the `PORT` environment variable is used, then port 8088
    # + config - The listener configuration. The `http:ListenerConfiguration` fields apply only when
    # the listener creates its own `http:Listener`
    # + return - An error if the listener cannot be created
    public isolated function init(int|http:Listener? listenOn = (), *FoundryListenerConfiguration config)
            returns error? {
        if listenOn is http:Listener {
            self.httpListener = listenOn;
        } else {
            self.httpListener = check new (listenOn ?: DEFAULT_PORT);
        }
    }

    # Attaches a Foundry service to the listener.
    #
    # + foundryService - The service to attach
    # + name - The base path of the service. Leave it empty so the routes are served at the root,
    # as Foundry expects
    # + return - An error if the service cannot be attached
    public isolated function attach(FoundryInvocationService foundryService, string[]|string? name = ())
            returns error? {
        return error("FoundryListener is not implemented yet");
    }

    # Detaches a Foundry service from the listener.
    #
    # + foundryService - The service to detach
    # + return - An error if the service cannot be detached
    public isolated function detach(FoundryInvocationService foundryService) returns error? {
        return error("FoundryListener is not implemented yet");
    }

    # Starts the listener.
    #
    # + return - An error if the listener cannot be started
    public isolated function 'start() returns error? {
        check self.httpListener.'start();
    }

    # Stops the listener after letting in-flight requests finish, up to the configured
    # `gracefulStopTimeout`.
    #
    # + return - An error if the listener cannot be stopped
    public isolated function gracefulStop() returns error? {
        check self.httpListener.gracefulStop();
    }

    # Stops the listener immediately.
    #
    # + return - An error if the listener cannot be stopped
    public isolated function immediateStop() returns error? {
        check self.httpListener.immediateStop();
    }
}
