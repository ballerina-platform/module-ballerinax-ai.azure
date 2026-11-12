# Proposal: Microsoft Foundry hosted-agent listener (HTTP, Invocations protocol)

- **Package:** `ballerinax/ai.azure` (adds to 1.6.0, a minor release)
- **Status:** Implemented
- **Scope:** HTTP transport, Foundry **Invocations** protocol only

## Summary

A Ballerina developer runs an agent as a Microsoft Foundry hosted agent by attaching a
`azure:FoundryInvocationService` to an `azure:FoundryListener`. The listener implements the
container contract Foundry expects (port, readiness probe, routes, session and invocation IDs,
platform request headers, response headers, error classification, SSE streaming and graceful
shutdown), so the service contains only agent logic.

The design copies `ai:Listener` / `ai:ChatService` from `ballerina/ai`: the listener wraps an
`http:Listener` and attaches an internal, isolated **dispatcher service** in place of the user's
service; the dispatcher calls the user's resources reflectively through a native adaptor and
turns every result into an `http:Response` carrying the platform headers.

## References studied

| Reference | Revision |
|---|---|
| `Azure/azure-sdk-for-python` `sdk/agentserver/azure-ai-agentserver-core` | `main` (shallow clone, 2026-11-12) |
| `Azure/azure-sdk-for-python` `sdk/agentserver/azure-ai-agentserver-invocations` (`VERSION = "1.3.0"`) | `main` (shallow clone, 2026-11-12) |
| `ballerina-platform/module-ballerina-ai` (`listener.bal`, `dispatcher_service.bal`, `NativeHttpToChatServiceAdaptor.java`, `ChatResourceValidationTask.java`) | `main` |
| `ballerina-platform/module-ballerina-mcp` (`listener.bal`) | `main` |

Python paths below are abbreviated: `core/` is
`azure-ai-agentserver-core/azure/ai/agentserver/core/` and `inv/` is
`azure-ai-agentserver-invocations/azure/ai/agentserver/invocations/`.

## Public API

```ballerina
import ballerina/http;
import ballerinax/ai.azure;

listener azure:FoundryListener foundryListener = new; // explicit port, else PORT, else 8088

service azure:FoundryInvocationService on foundryListener {

    // Required. POST /invocations
    resource function post invocations(@http:Payload json payload, azure:FoundryContext ctx)
            returns json|error {
        string message = check payload.message;
        return {reply: message, session: ctx.sessionId};
    }

    // Optional. GET /invocations/{invocationId}
    resource function get invocations/[string invocationId](azure:FoundryContext ctx)
            returns json|error => {id: invocationId, status: "completed"};

    // Optional. POST /invocations/{invocationId}/cancel
    resource function post invocations/[string invocationId]/cancel(azure:FoundryContext ctx)
            returns json|error => {id: invocationId, status: "cancelled"};
}
```

### Types

```ballerina
# Service type for a Foundry hosted agent speaking the Invocations protocol.
public type FoundryInvocationService distinct service object {
    *http:Service;
};

# Listener configuration. Platform values default to the matching environment variables, so a
# test (or a non-hosted run) can inject them instead of setting real environment variables.
public type FoundryListenerConfiguration record {|
    *http:ListenerConfiguration;          // used only when the listener creates the http:Listener
    decimal gracefulStopTimeout = ...;    // AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS, else 30
    int sseKeepAliveInterval = ...;       // SSE_KEEPALIVE_INTERVAL, else 15; 0 disables
    FoundryAgentInfo agent = ...;         // FOUNDRY_* environment variables
    map<json>? openApiSpec = ();          // served at GET /invocations/docs/openapi.json when set
|};

# Listener for a Foundry hosted agent.
public isolated class FoundryListener {
    public isolated function init(int|http:Listener? listenOn = (),
            *FoundryListenerConfiguration config) returns error?;
    public isolated function attach(FoundryInvocationService svc, string[]|string? name = ())
            returns error?;
    public isolated function detach(FoundryInvocationService svc) returns error?;
    public isolated function 'start() returns error?;
    public isolated function gracefulStop() returns error?;
    public isolated function immediateStop() returns error?;
}

# Per-request platform context, passed to a resource that declares it.
public type FoundryContext record {|
    string sessionId;                          // "" on get/cancel when no session is known
    string invocationId;
    string? userId;                            // x-agent-user-id
    string? callId;                            // x-agent-foundry-call-id (opaque, never parsed)
    FoundryOriginalSubject? originalSubject;   // x-ms-original-subject
    map<string> clientHeaders;                 // every x-client-* header, keyed by lower-case name
    FoundryTraceContext trace;
    FoundryAgentInfo agent;
    http:Headers headers;                      // raw request headers
|};

public type FoundryOriginalSubject record {| string? oid; string? tid; string? idtype; |};

public type FoundryTraceContext record {|
    string? traceparent;
    string? tracestate;
    string? baggage;
    string? requestId;        // x-request-id
    string? clientRequestId;  // x-ms-client-request-id
|};

public type FoundryAgentInfo record {|
    string? projectEndpoint;  // FOUNDRY_PROJECT_ENDPOINT
    string? projectArmId;     // FOUNDRY_PROJECT_ARM_ID
    string? name;             // FOUNDRY_AGENT_NAME
    string? version;          // FOUNDRY_AGENT_VERSION
    string? id;               // FOUNDRY_AGENT_ID
    string? sessionId;        // FOUNDRY_AGENT_SESSION_ID
|};
```

Naming notes:

- `FoundryContext` is shorter than the reference's `FoundryAgentRequestContext` and also carries
  the IDs, trace headers and agent info, so it is more than the reference's identity context.
- The `Foundry` prefix avoids clashes with the existing `azure:` model-provider symbols.
- Port resolution is a constructor default rather than a config field, so `new` alone is the
  hosted-agent setup and `new(9090)` or `new(httpListener)` work as with `ai:Listener`.

### Resource signatures

| Resource | Parameters (any order) | Return types |
|---|---|---|
| `post invocations` (required) | optional `@http:Payload` of `json`, `string`, `byte[]`, `xml` or any `anydata` subtype (records, arrays, maps); optional `azure:FoundryContext` | `anydata`, `http:Response`, any `http:StatusCodeResponse`, `stream<http:SseEvent, error?>`, `stream<anydata, error?>`, `error`, `()`, or a union of these |
| `get invocations/[string invocationId]` (optional) | path parameter; optional `azure:FoundryContext` | same, without streams |
| `post invocations/[string invocationId]/cancel` (optional) | path parameter; optional `azure:FoundryContext` | same, without streams |

The compiler plugin enforces this table (Milestone 6).

## Dispatcher design

- `FoundryListener.attach` creates an internal `FoundryDispatcherService` (an `isolated service
  class`) and attaches *it* to the `http:Listener`. The user's service and the dispatcher are
  linked as native data in both directions (same as `ai:Listener`), so the dispatcher holds no
  Ballerina state and requests run concurrently.
- **Decision: a new native adaptor in `ai.azure`** (`NativeFoundryServiceAdaptor`), not reuse of
  the `ballerina/ai` one. The `ai` adaptor is internal Java (not exported) and hard-codes the
  `chat`/`decision` resources and a fixed payload type. The Foundry adaptor must instead:
  - find `post invocations`, `get invocations/*` and `post invocations/*/cancel` by accessor and
    path shape;
  - work out each parameter's role (payload by `@http:Payload`, context by type, path parameter)
    and build the argument list in declared order;
  - convert the request body to the declared payload type (`string`, `byte[]`, `xml`, `json`, or
    `json` → target type with `ValueUtils.convert`), reporting a conversion failure as a
    `400 user` error.
  It keeps the observability handling from the `ai` adaptor, so traces name the user's service
  as the entrypoint.
- The dispatcher declares a catch-all `default [string... path]` resource, so unknown paths
  (`404`) and wrong methods on known paths (`405`) also get the platform headers.
- **SSE keep-alive is native.** Ballerina cannot wait on a stream's `next()` with a timeout, so a
  native wrapper runs the user stream's `next()` on its own thread and waits on a future with the
  keep-alive interval as timeout. A timeout emits a comment event and keeps the pending future,
  which is what `inv/_sse.py:13-77` does with `asyncio.wait_for(asyncio.shield(...))`.

## Behaviour and its source

| Behaviour | Implementation | Reference |
|---|---|---|
| Port: explicit argument → `PORT` → `8088` | `init(listenOn = ())` | `core/_config.py:220-236` (`resolve_port`), `core/_constants.py:17-18` |
| Listen on all interfaces, HTTP/1.1, no TLS | `http:Listener` default host | deploy-hosted-agent docs |
| Accept an existing `http:Listener` | `init(http:Listener)` | `ai:Listener`, `websocket:Listener`, `mcp:Listener` |
| `GET /readiness` → `200 {"status":"healthy"}`, `application/json`, no model calls | dispatcher `get readiness` | `core/_base.py:46`, `482`, `1200-1210` |
| `x-platform-server` on every response, format `<sdk>/<version> (<runtime>/<version>)` | dispatcher + catch-all resource; value `ballerinax-ai.azure/<pkg version> (ballerina/<runtime version>)` | `core/_base.py:180-202`, `662-693`; `core/_server_version.py:11-33` |
| `x-request-id` on every response: incoming header, else a generated UUID | dispatcher | `core/_request_id.py:51-120` (**not in the prompt; included**) |
| Graceful stop with timeout; `AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS`, default 30 | `gracefulStopTimeout` | `core/_config.py:239-266`, `core/_base.py:404-429` |
| Routes: `POST /invocations`, `GET /invocations/{id}`, `POST /invocations/{id}/cancel`, `GET /invocations/docs/openapi.json` | dispatcher resources | `inv/_invocation.py:277-316` |
| Session ID on invoke: `agent_session_id` query → `FOUNDRY_AGENT_SESSION_ID` → UUID; invalid → UUID | `resolveSessionId` | `inv/_invocation.py:547-551`, `135-152` |
| Session ID on get/cancel: query → env → `""`; invalid → `""` (no UUID is generated) | same | `inv/_invocation.py:647-662` |
| Invocation ID on invoke: `x-agent-invocation-id` header if valid, else UUID | `sanitizeId` | `inv/_invocation.py:542-545` |
| Invocation ID on get/cancel: the path value, kept even when it fails validation | `sanitizeId(raw, fallback = raw)` | `inv/_invocation.py:643-645` |
| ID rule: 1–256 chars, `^[a-zA-Z0-9\-_.:]+$` | `sanitizeId` | `inv/_invocation.py:95-97` |
| `x-agent-user-id`, `x-agent-foundry-call-id` read as optional; empty → `()` | `FoundryContext.userId`, `callId` | `inv/_invocation.py:155-175`; `core/_platform_headers.py:56-76` |
| `x-client-*` pass-through headers | `clientHeaders` | `core/_platform_headers.py:80-85` |
| `traceparent`, `x-ms-client-request-id`, `x-request-id` (plus `tracestate`, `baggage`) | `FoundryTraceContext` | `core/_platform_headers.py:35-41`, `89-97` |
| `x-ms-original-subject`: RFC 9651 dictionary profile with unique `oid`/`tid`/`idtype` string members; exactly one header field; empty dictionary rejected | `parseOriginalSubject` | `core/_request_context.py:46-52`, `76-111` |
| Invalid original subject → `400`, `x-platform-error-source: platform`, `x-platform-error-detail: invalid_original_subject` | dispatcher | `inv/_invocation.py:178-192` |
| `x-agent-invocation-id` and `x-agent-session-id` on invoke responses, including errors and streams | dispatcher | `inv/_invocation.py:585-617` |
| `x-agent-invocation-id` only (no session header) on get/cancel responses | dispatcher | `inv/_invocation.py:673-689` |
| Error envelope `{"error":{"code","message"}}` | `errorResponse` | `core/_errors.py:28-63` |
| Invoke resource missing → `501`, `upstream` | dispatcher | `inv/_invocation.py:401-404`, `588-601` |
| Get/cancel not implemented → `404`, `upstream` | dispatcher | `inv/_invocation.py:406-424` |
| No OpenAPI spec → `404`, `upstream`; otherwise the spec as JSON | dispatcher | `inv/_invocation.py:446-455` |
| Error from the user's code → `500 "Internal server error"`, `upstream`, no detail | dispatcher | `inv/_invocation.py:78-92`, `602-617` |
| Platform (framework) failure → `500`, `platform`, detail `"<type>: <message>"` truncated to 2048 chars with `...[truncated]` | `classifyError` | `inv/_invocation.py:78-92`; `core/_platform_headers.py:121-130` |
| SSE: `text/event-stream`; keep-alive comment `: keep-alive` after each idle interval; `SSE_KEEPALIVE_INTERVAL`, default 15, `0` disables | native keep-alive stream | `inv/_sse.py:10-77`; `core/_config.py:445-461`; `inv/_invocation.py:530-539` |
| Error raised mid-stream → logged, stream terminated (no synthetic event) | dispatcher stream wrapper | `inv/_invocation.py:502-528` |
| Client disconnect → source stream closed | native wrapper closes the user stream | `inv/_sse.py:49-52`, `73-77` |
| `FOUNDRY_*` environment exposed read-only | `FoundryAgentInfo` | `core/_constants.py:9-14`, `31-33`; `core/_config.py:130-160` |

## Where the implementation differs from the prompt (and why)

The prompt says to follow the reference when the two disagree. None of these changes the
public API.

| Prompt | Reference (implemented) | Note |
|---|---|---|
| A user `error` → `500` with error source `user` | `500` with source **`upstream`**: anything the agent's code raises is `upstream`; only framework errors are `platform` (`inv/_invocation.py:78-92`) | In the reference, `user` is for a caller's bad request. We use `user` only for a payload that can't be bound to the declared type, which is the one caller error the reference has no equivalent for, since its handlers read the raw request themselves. |
| Prompt port order: `PORT`, then 8088, then explicit | explicit → `PORT` → 8088 (`core/_config.py:223`) | An explicit argument wins, as in the reference. |
| Both ID headers on every protocol response | invoke: both; get/cancel: **`x-agent-invocation-id` only** (`inv/_invocation.py:673-689`) | |
| Session and invocation IDs on get/cancel validated and replaced like invoke | invocation ID: the raw path value is **kept** when invalid (`_sanitize_id(raw, raw)`); session ID: invalid or missing → `""`, never a new UUID | Replacing the path ID with a UUID would look up the wrong invocation. `FoundryContext.sessionId` is `""` when unknown. |
| `x-platform-error-source` on every 4xx/5xx from protocol endpoints | the reference adds it only to responses the framework builds; a 4xx/5xx the handler returns itself has none | We follow the platform contract doc instead and add `upstream` to any 4xx/5xx the user returns (`http:Response`, status-code record, `httpscerr` error), unless the user already set the header. |
| "Detail when there is diagnostic detail" | detail only on `platform` errors (and `invalid_original_subject`) | User error messages never reach the header, so user content and secrets can't leak. |

## Reference behaviour the prompt doesn't mention

| Reference behaviour | Included? |
|---|---|
| `x-request-id` response header on every response (`core/_request_id.py`) | **Yes** |
| `405` for a known path with the wrong method (Starlette routing) | **Yes**, via the catch-all resource |
| Custom readiness handler (`core/_base.py:1208`) | No: the prompt fixes the allowed resources; can be added later |
| `/invocations/docs/asyncapi.json` and `.yaml` (`inv/_invocation.py:284-295`) | No: these describe the WebSocket transport, which is out of scope |
| OpenTelemetry baggage entries `azure.ai.agentserver.invocation_id` / `session_id` (`inv/_invocation.py:564-575`) | No: Ballerina observability is configured separately; the IDs are on `FoundryContext` |
| `FOUNDRY_AGENT_SESSION_GUID` / `FOUNDRY_HOSTING_ENVIRONMENT` validation (`core/_config.py:50-55`) | No: not needed for Invocations routing |
| `model_attribution_headers()` / `x-ms-foundry-baggage` (`core/_request_context.py:148-219`) | No: outbound, experimental, out of scope. `originalSubject` is exposed so it can be added later. |
| Shutdown handler hook (`core/_base.py:760`) | No: Ballerina code can use a module-level `listener`'s lifecycle or `runtime:onGracefulStop` |
| Resilient task manager, WebSocket, Responses, snapshot/restore | No: out of scope per the prompt |

## Ballerina distribution

This release moves the package from `2201.12.0` (`java21`) to `2201.14.1` (`java25`), matching
`ballerina/ai` and `ballerina/mcp`, which are already on 2201.14 / `java25`. The listener itself
doesn't need the bump: everything it uses (`http:SseEvent`, `stream<http:SseEvent, error?>`
returns, `http:Response.setSseEventStream`, `http:ListenerConfiguration.gracefulStopTimeout`,
status-code response records, `http.httpscerr`) also exists in `ballerina/http` 2.14.x on 2201.12.
The bump keeps `ai.azure` on the same distribution and Java platform as the `ballerina/ai` it
depends on. As a result, users of 1.6.0 need Swan Lake Update 14 or later.

## Future WebSocket listener

`FoundryListener.init` accepts an `http:Listener`, and the dispatcher only claims the
`/invocations*`, `/readiness` and catch-all routes, so a later `websocket:Listener`-based
`/invocations_ws` listener can share the same `http:Listener` and port. Header building, ID
resolution and context parsing are package-private functions the WebSocket listener can reuse.
