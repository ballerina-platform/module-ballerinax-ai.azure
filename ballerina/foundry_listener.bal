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
import ballerina/os;

// The Foundry listener follows the Microsoft `azure-ai-agentserver-core` and
// `azure-ai-agentserver-invocations` Python libraries (the reference). Code comments in the Foundry
// files cite the reference as `core/<file>:<lines>` and `inv/<file>:<lines>`, where `core/` is
// `sdk/agentserver/azure-ai-agentserver-core/azure/ai/agentserver/core/` and `inv/` is
// `sdk/agentserver/azure-ai-agentserver-invocations/azure/ai/agentserver/invocations/` in
// `Azure/azure-sdk-for-python` at commit `815c4b283a6013c803d0d3bd051c7bea6f4e6464`. The line numbers
// refer to that commit.

# A listener that runs a `FoundryInvocationService` as a Microsoft Foundry hosted agent.
#
# The listener serves the Foundry Invocations protocol over HTTP: `POST /invocations`, the
# optional get and cancel routes, and the `GET /readiness` probe (served by the service's
# `get readiness` resource). It resolves session and
# invocation IDs, reads the platform headers into a `FoundryContext`, sets the platform response
# headers and classifies errors, so the attached service contains only agent logic.
public isolated class FoundryListener {
    private final http:Listener httpListener;
    private final readonly & FoundryDispatcherConfig dispatcherConfig;

    # Initializes the listener.
    #
    # + listenOn - The port to listen on, or an existing `http:Listener` to share. When it is not
    # given, the `PORT` environment variable is used, then port 8088
    # + config - The listener configuration. The `http:ListenerConfiguration` fields apply only when
    # the listener creates its own `http:Listener`
    # + return - An error if the port is not valid or the listener cannot be created
    public isolated function init(int|http:Listener? listenOn = (), *FoundryListenerConfiguration config)
            returns error? {
        if listenOn is http:Listener {
            self.httpListener = listenOn;
        } else {
            int port = check resolveFoundryPort(listenOn, os:getEnv(ENV_PORT));
            self.httpListener = check new (port, toHttpListenerConfiguration(config));
        }
        self.dispatcherConfig = toDispatcherConfig(config);
    }

    # Attaches a Foundry service to the listener.
    #
    # + foundryService - The service to attach
    # + name - The base path of the service. Only the root base path (`()`, `"/"` or empty) is
    # accepted, because Foundry probes `/readiness` and calls `/invocations` at the root
    # + return - An error if the base path is not the root, the service is already attached to this
    # listener, or the service cannot be attached
    public isolated function attach(FoundryInvocationService foundryService, string[]|string? name = ())
            returns error? {
        if !isRootBasePath(name) {
            return error(string `A FoundryInvocationService must be attached at the root base path, `
                + string `because Foundry calls /readiness and /invocations there: got '${basePathToString(name)}'`);
        }
        // Attach an internal dispatcher in place of the user's service. It serves the platform routes,
        // sets the platform headers and forwards protocol requests to the user's service. The link is
        // made before the dispatcher is attached, so it never serves a request without it.
        FoundryDispatcherService dispatcher = new (self.dispatcherConfig);
        setFoundryService(dispatcher, foundryService);
        if !registerFoundryDispatcher(foundryService, self, dispatcher) {
            unlinkFoundryService(dispatcher);
            return error("The FoundryInvocationService is already attached to this FoundryListener");
        }
        error? result = self.httpListener.attach(dispatcher, name);
        if result is error {
            _ = removeFoundryDispatcher(foundryService, self);
            unlinkFoundryService(dispatcher);
            return result;
        }
    }

    # Detaches a Foundry service from the listener. Detaching a service that is not attached to this
    # listener does nothing.
    #
    # + foundryService - The service to detach
    # + return - An error if the service cannot be detached
    public isolated function detach(FoundryInvocationService foundryService) returns error? {
        // Only the dispatcher this listener attached for the service is detached, so the same service
        // attached to another FoundryListener keeps working.
        FoundryDispatcherService? dispatcher = removeFoundryDispatcher(foundryService, self);
        if dispatcher is () {
            return;
        }
        error? result = self.httpListener.detach(dispatcher);
        if result is error {
            _ = registerFoundryDispatcher(foundryService, self, dispatcher);
            return result;
        }
        unlinkFoundryService(dispatcher);
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

    # Returns the underlying `http:Listener`.
    #
    # + return - The `http:Listener` the dispatcher is attached to
    isolated function getHttpListener() returns http:Listener => self.httpListener;
}

# Returns whether an attach name is the root base path: `()`, a string made only of `/`, or path
# segments that are all empty.
#
# + name - The attach name
# + return - `true` for the root base path
isolated function isRootBasePath(string[]|string? name) returns boolean {
    if name is () {
        return true;
    }
    if name is string {
        return re `/*`.isFullMatch(name.trim());
    }
    foreach string segment in name {
        if !re `/*`.isFullMatch(segment.trim()) {
            return false;
        }
    }
    return true;
}

isolated function basePathToString(string[]|string? name) returns string {
    if name is string[] {
        return "/" + string:'join("/", ...name);
    }
    return name ?: "";
}

# Resolves the listening port: the explicit port, else the `PORT` environment variable, else 8088
# (`core/_config.py:220-236`).
#
# + explicitPort - The port passed to the listener, if any
# + portEnv - The raw value of the `PORT` environment variable; `""` when it is not set
# + return - The port, or an error when the chosen value is not an integer in 1-65535
isolated function resolveFoundryPort(int? explicitPort, string portEnv) returns int|error {
    if explicitPort is int {
        return validatePort(explicitPort, "port");
    }
    string value = portEnv.trim();
    if value == "" {
        return DEFAULT_PORT;
    }
    int|error port = int:fromString(value);
    if port is error {
        return error(string `Invalid value for ${ENV_PORT}: '${portEnv}' (expected an integer)`);
    }
    return validatePort(port, ENV_PORT);
}

isolated function validatePort(int port, string sourceName) returns int|error {
    if port < 1 || port > 65535 {
        return error(string `Invalid value for ${sourceName}: ${port} (expected 1-65535)`);
    }
    return port;
}

# Builds the configuration of the `http:Listener` the Foundry listener creates. The Foundry
# `gracefulStopTimeout` replaces the http default.
#
# + config - The Foundry listener configuration
# + return - The `http:Listener` configuration
isolated function toHttpListenerConfiguration(FoundryListenerConfiguration config)
        returns http:ListenerConfiguration {
    // A rest binding keeps every `http:ListenerConfiguration` field, including any the http module
    // adds later; only the Foundry-specific fields are left out.
    var {agent: _, openApiSpec: _, ...httpConfig} = config;
    return httpConfig;
}

# Extracts what the dispatcher needs from the Foundry listener configuration, as read-only data.
#
# + config - The Foundry listener configuration
# + return - The dispatcher configuration
isolated function toDispatcherConfig(FoundryListenerConfiguration config) returns readonly & FoundryDispatcherConfig
    => {
    agent: config.agent.cloneReadOnly(),
    openApiSpec: config.openApiSpec.cloneReadOnly()
};
