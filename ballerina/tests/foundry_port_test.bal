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
import ballerina/test;

// Port resolution and listener configuration (no environment variables involved).

@test:Config {groups: ["foundry"]}
function testFoundryPortExplicitWins() returns error? {
    test:assertEquals(check resolveFoundryPort(9000, "1234"), 9000);
    // The explicit port is used without looking at PORT, so an invalid PORT doesn't matter.
    test:assertEquals(check resolveFoundryPort(9000, "not-a-port"), 9000);
    test:assertEquals(check resolveFoundryPort(1, ""), 1);
    test:assertEquals(check resolveFoundryPort(65535, ""), 65535);
}

@test:Config {groups: ["foundry"]}
function testFoundryPortFromEnv() returns error? {
    test:assertEquals(check resolveFoundryPort((), "1234"), 1234);
    test:assertEquals(check resolveFoundryPort((), " 8081 "), 8081);
}

@test:Config {groups: ["foundry"]}
function testFoundryPortDefault() returns error? {
    test:assertEquals(check resolveFoundryPort((), ""), 8088);
    test:assertEquals(check resolveFoundryPort((), "   "), 8088);
}

@test:Config {groups: ["foundry"]}
function testFoundryPortInvalid() {
    assertPortError(resolveFoundryPort((), "abc"), "Invalid value for PORT: 'abc' (expected an integer)");
    assertPortError(resolveFoundryPort((), "80.5"), "Invalid value for PORT: '80.5' (expected an integer)");
    assertPortError(resolveFoundryPort((), "0"), "Invalid value for PORT: 0 (expected 1-65535)");
    assertPortError(resolveFoundryPort((), "65536"), "Invalid value for PORT: 65536 (expected 1-65535)");
    assertPortError(resolveFoundryPort((), "-1"), "Invalid value for PORT: -1 (expected 1-65535)");
    assertPortError(resolveFoundryPort(0, ""), "Invalid value for port: 0 (expected 1-65535)");
    assertPortError(resolveFoundryPort(70000, "8080"), "Invalid value for port: 70000 (expected 1-65535)");
}

@test:Config {groups: ["foundry"]}
function testFoundryListenerRejectsInvalidPort() {
    FoundryListener|error foundryListener = new (70000);
    if foundryListener !is error {
        test:assertFail("a listener was created on port 70000");
    }
    test:assertEquals(foundryListener.message(), "Invalid value for port: 70000 (expected 1-65535)");
}

@test:Config {groups: ["foundry"]}
function testFoundryHttpListenerConfiguration() {
    FoundryListenerConfiguration config = {
        gracefulStopTimeout: 3,
        timeout: 12,
        server: "foundry-test",
        host: "127.0.0.1",
        httpVersion: http:HTTP_1_1,
        requestLimits: {maxUriLength: 1024}
    };
    http:ListenerConfiguration httpConfig = toHttpListenerConfiguration(config);
    test:assertEquals(httpConfig.gracefulStopTimeout, 3d);
    test:assertEquals(httpConfig.timeout, 12d);
    test:assertEquals(httpConfig.server, "foundry-test");
    test:assertEquals(httpConfig.host, "127.0.0.1");
    test:assertEquals(httpConfig.httpVersion, http:HTTP_1_1);
    test:assertEquals(httpConfig.requestLimits.maxUriLength, 1024);
}

@test:Config {groups: ["foundry"]}
function testFoundryConfigOverrides() {
    FoundryAgentInfo agent = {name: "configured-agent", version: "3", sessionId: "s-1"};
    FoundryListenerConfiguration config = {
        gracefulStopTimeout: 0,
        agent,
        openApiSpec: {openapi: "3.0.1", info: {title: "agent"}}
    };
    test:assertEquals(config.gracefulStopTimeout, 0d);
    readonly & FoundryDispatcherConfig dispatcherConfig = toDispatcherConfig(config);
    FoundryDispatcherConfig expected = {
        agent: {name: "configured-agent", version: "3", sessionId: "s-1"},
        openApiSpec: {openapi: "3.0.1", info: {title: "agent"}}
    };
    test:assertEquals(dispatcherConfig, expected);
    test:assertTrue(dispatcherConfig.agent.projectEndpoint is ());
    test:assertEquals(toHttpListenerConfiguration(config).gracefulStopTimeout, 0d);
}

function assertPortError(int|error result, string expectedMessage) {
    if result is int {
        test:assertFail(string `expected an error, got port ${result}`);
    }
    test:assertEquals(result.message(), expectedMessage);
}
