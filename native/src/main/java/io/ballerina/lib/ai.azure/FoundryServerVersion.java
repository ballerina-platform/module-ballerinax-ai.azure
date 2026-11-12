/*
 * Copyright (c) 2026, WSO2 LLC. (http://wso2.com).
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.ballerina.lib.ai.azure;

import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BString;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Builds the value of the {@code x-platform-server} response header of the Foundry listener.
 *
 * <p>The format follows the Foundry agent server's {@code build_server_version}:
 * {@code <sdk name>/<sdk version> (<runtime>/<runtime version>)}, for example
 * {@code ballerinax-ai.azure/1.6.0 (ballerina/2201.14.1)}.
 *
 * <p>Both versions come from {@link FoundryBuildInfo}, which the native Gradle build generates. The package version
 * is stripped there by the same rule that writes the {@code Ballerina.toml} version, so the two cannot drift.
 *
 * <p>The Ballerina version is, in practice, the distribution this package was built with. The program's JVM carries
 * no runtime version: the {@code bal} launcher sets {@code -Dballerina.version} only on its own JVM, and both
 * {@code bal run} (which starts the program in a child process) and {@code java -jar} run the program without it.
 * The {@code ballerina.version} system property is still honoured when it is set explicitly.
 *
 * @since 1.6.0
 */
public final class FoundryServerVersion {

    static final String SDK_NAME = "ballerinax-ai.azure";
    static final String RUNTIME_NAME = "ballerina";
    static final String BALLERINA_VERSION_PROPERTY = "ballerina.version";
    private static final Pattern RELEASE_VERSION = Pattern.compile("^(\\d+\\.\\d+\\.\\d+)");

    private FoundryServerVersion() {
    }

    /**
     * Returns the {@code x-platform-server} header value.
     *
     * @return the server version string
     */
    public static BString getServerVersion() {
        return StringUtils.fromString(buildServerVersion(FoundryBuildInfo.PACKAGE_VERSION,
                System.getProperty(BALLERINA_VERSION_PROPERTY), FoundryBuildInfo.BALLERINA_VERSION));
    }

    static String buildServerVersion(String packageVersion, String runtimeVersion, String buildBallerinaVersion) {
        return SDK_NAME + "/" + packageVersion + " (" + RUNTIME_NAME + "/"
                + resolveRuntimeVersion(runtimeVersion, buildBallerinaVersion) + ")";
    }

    static String resolveRuntimeVersion(String runtimeVersion, String buildBallerinaVersion) {
        if (runtimeVersion != null) {
            Matcher matcher = RELEASE_VERSION.matcher(runtimeVersion.trim());
            if (matcher.find()) {
                return matcher.group(1);
            }
        }
        return buildBallerinaVersion;
    }
}
