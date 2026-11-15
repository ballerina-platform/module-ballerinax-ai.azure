# Foundry hosted agent with Azure OpenAI

## Overview

An `ai:Agent` backed by `azure:OpenAiModelProvider`, served as a Microsoft Foundry hosted agent through
`azure:FoundryInvocationService` and `azure:FoundryListener`. The agent keeps a conversation history per
session (and per user, when Foundry sends `x-agent-user-id`), so follow-up questions in the same session
have context.

The history is kept in memory: it is lost when the container restarts and is not shared between
replicas. Use a persistent `ai:ShortTermMemoryStore` for production.

## Prerequisites

- Ballerina Swan Lake Update 14 (2201.14.x) or later.
- `ballerinax/ai.azure` 1.6.0 or later, the first version with `azure:FoundryListener`. Until 1.6.0 is
  published to Ballerina Central, use a local build of the package (see below).
- An [Azure OpenAI resource](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/create-resource)
  with a chat model deployment, and its endpoint and API key.
- Docker, to build the container image.

## Configure

Copy the template and fill in your values:

```bash
cp Config.toml.template Config.toml
```

```toml
serviceUrl = "https://<resource>.openai.azure.com/openai"
apiKey = "<AZURE_OPENAI_API_KEY>"
deploymentId = "<MODEL_DEPLOYMENT_NAME>"
apiVersion = "2024-10-21"
```

`apiVersion` is required for a legacy service URL (`https://<resource>.openai.azure.com/openai`) and
ignored for a v1 service URL (`https://<resource>.services.ai.azure.com/openai/v1`). `Config.toml` is
git-ignored; don't commit it.

## Use a local build of `ballerinax/ai.azure`

Skip this step once `ballerinax/ai.azure` 1.6.0 is on Ballerina Central. Before that, `bal run` resolves
the latest published version, which lacks the Foundry listener, and fails to compile `main.bal`.

Build the package from the repository root and publish it to the local repository
(`~/.ballerina/repositories/local`):

```bash
./gradlew clean build -x test -PpublishToLocalCentral=true
```

Then make the example use it, by adding this to `Ballerina.toml`:

```toml
[[dependency]]
org = "ballerinax"
name = "ai.azure"
version = "1.6.0"
repository = "local"
```

## Run locally

```bash
bal run
```

The listener uses the port in the `PORT` environment variable, or 8088 when it is not set.

```bash
curl -i http://localhost:8088/readiness
```

```
HTTP/1.1 200 OK
content-type: application/json
x-platform-server: ballerinax-ai.azure/1.6.0 (ballerina/2201.14.1)
x-request-id: 1da8865308f443328a20c59a8e6fec9c
content-length: 20
...

{"status":"healthy"}
```

The service's required `get readiness` resource serves the probe. It returns `{"status":"healthy"}` and
never calls the model; return a status-code record such as `http:ServiceUnavailable` from it instead to
report the container as not ready.

```bash
curl -i -X POST "http://localhost:8088/invocations?agent_session_id=s1" \
    -H "Content-Type: application/json" \
    -H "x-agent-user-id: u1" \
    -d '{"message":"Hi! My name is Alex."}'
```

```
HTTP/1.1 200 OK
content-type: application/json
x-platform-server: ballerinax-ai.azure/1.6.0 (ballerina/2201.14.1)
x-request-id: <32 hex digits>
x-agent-invocation-id: <generated UUID>
x-agent-session-id: s1
...

{"reply":"<the model's answer>", "sessionId":"s1", "invocationId":"<generated UUID>"}
```

Ask a follow-up in the same session (and as the same user) and the agent remembers the earlier turn:

```bash
curl -i -X POST "http://localhost:8088/invocations?agent_session_id=s1" \
    -H "Content-Type: application/json" \
    -H "x-agent-user-id: u1" \
    -d '{"message":"What is my name?"}'
```

If the model call fails (for example, a wrong API key or deployment name), the agent returns the error and
the listener answers `500` with `x-platform-error-source: upstream` and the body
`{"error":{"code":"internal_error","message":"Internal server error"}}`. The details are not sent to the
caller.

Responses are plain JSON: the listener doesn't support streaming responses.

## Build the container image

Foundry hosted agents run `linux/amd64` images. Build the executable, then the image:

```bash
bal build
docker build --platform linux/amd64 -t foundry-hosted-agent:v1 .
```

The [Dockerfile](Dockerfile) copies only `target/bin/foundry_hosted_agent.jar` into an
`eclipse-temurin:25-jre` image and runs it on port 8088. No configuration or secret is baked into the
image.

## Run the container

Pass the configuration when the container starts, either as environment variables (Ballerina reads a
configurable `x` of the root module from `BAL_CONFIG_VAR_X`):

```bash
docker run --rm -p 8088:8088 --stop-timeout 40 \
    -e BAL_CONFIG_VAR_SERVICEURL="https://<resource>.openai.azure.com/openai" \
    -e BAL_CONFIG_VAR_APIKEY="$AZURE_OPENAI_API_KEY" \
    -e BAL_CONFIG_VAR_DEPLOYMENTID="<MODEL_DEPLOYMENT_NAME>" \
    foundry-hosted-agent:v1
```

or by mounting your `Config.toml` read-only:

```bash
docker run --rm -p 8088:8088 --stop-timeout 40 \
    -v "$(pwd)/Config.toml:/home/ballerina/config/Config.toml:ro" \
    -e BAL_CONFIG_FILES=/home/ballerina/config/Config.toml \
    foundry-hosted-agent:v1
```

Then use the same `curl` commands as above. Stopping the container (`docker stop`) waits the full
graceful-stop timeout, 30 seconds by default, before the agent exits; set
`AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` to change it. Docker kills a container that is still
running 10 seconds after `docker stop` unless told otherwise, so the commands above set
`--stop-timeout 40`. Keep it above the graceful-stop timeout.

## Deploy to Foundry (optional)

Follow [Deploy a hosted agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/deploy-hosted-agent)
on Microsoft Learn, using this image as the container:

1. Push the image to an Azure Container Registry the Foundry project can pull from.
2. Create a hosted agent version with the image, the **`invocations`** protocol at version **`2.0.0`**
   (`{"protocol": "invocations", "version": "2.0.0"}` in `protocol_versions`), and the configuration as
   environment variables (`BAL_CONFIG_VAR_SERVICEURL`, `BAL_CONFIG_VAR_APIKEY`,
   `BAL_CONFIG_VAR_DEPLOYMENTID`). Keep the API key out of the agent definition: the deploy page
   describes how to reference a secret stored in a project connection.
3. When the version is `active`, call the agent's `invocations` endpoint as the deploy page shows.

Foundry sets `FOUNDRY_*` environment variables and platform headers on each request; the listener reads
them into `azure:FoundryContext`, so the code needs no changes.
