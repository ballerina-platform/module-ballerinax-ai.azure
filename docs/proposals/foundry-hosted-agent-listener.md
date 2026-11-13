# Proposal: Microsoft Foundry hosted-agent listener (HTTP, Invocations protocol)

- **Package:** `ballerinax/ai.azure` (adds to 1.6.0, a minor release)
- **Status:** Implemented
- **Scope:** HTTP transport, Foundry **Invocations** protocol only

## Summary

A Ballerina developer runs an agent as a Microsoft Foundry hosted agent by attaching a
`azure:FoundryInvocationService` to an `azure:FoundryListener`. The listener implements the
container contract Foundry expects (port, readiness probe, routes, session and invocation IDs,
platform request headers, response headers, error classification and graceful shutdown), so the service contains only agent logic.

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

    // Required. GET /readiness (and HEAD). `()` is the default 200 {"status":"healthy"}.
    resource function get readiness() returns json => {status: "healthy"};

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
# Service type for a Foundry hosted agent speaking the Invocations protocol. A marker type: the
# required resources (`post invocations`, `get readiness`) are enforced by the compiler plugin, not
# declared here, so the payload and context parameters stay flexible.
public type FoundryInvocationService distinct service object {
    *http:Service;
};

# Listener configuration. Platform values default to the matching environment variables, so a
# test (or a non-hosted run) can inject them instead of setting real environment variables.
public type FoundryListenerConfiguration record {|
    *http:ListenerConfiguration;          // used only when the listener creates the http:Listener
    decimal gracefulStopTimeout = ...;    // AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS, else 30
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

# The headers to forward on outbound calls to Foundry platform services: `x-agent-foundry-call-id`
# when `ctx.callId` is set, otherwise none. The user ID is never included.
public isolated function foundryPlatformHeaders(FoundryContext ctx) returns map<string>;
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
| `post invocations` (required) | optional `@http:Payload` of `json`, `string`, `byte[]`, `xml` or any `anydata` subtype (records, arrays, maps); optional `azure:FoundryContext` | `anydata`, `http:Response`, any `http:StatusCodeResponse`, `error`, `()`, or a union of these. No streams: the listener doesn't send server-sent events |
| `get readiness` (required) | none | same, but `()` means "ready" (see below) |
| `get invocations/[string invocationId]` (optional) | path parameter; optional `azure:FoundryContext` | same |
| `post invocations/[string invocationId]/cancel` (optional) | path parameter; optional `@http:Payload` (bound as for `post invocations`); optional `azure:FoundryContext` | same |

The compiler plugin enforces this table at compile time (see [Compiler plugin](#compiler-plugin)).
The dispatcher still checks it at run time, as a safety net: a protocol resource that breaks it is
answered with a `500` classified as `upstream` (the agent author's mistake): an unsupported parameter
(including a path parameter whose type doesn't accept every `string`), an `@http:Payload` parameter
on the get resource (a GET request has no body to bind), or a return value outside the table
(including a stream). The cancel resource may declare a payload because the reference hands its
handler the raw request, so a cancel request can carry a body such as a reason.

**Decision: both resources are required, enforced by the compiler plugin, not declared in the type.**
`FoundryInvocationService` stays the marker type `distinct service object { *http:Service; }`.
Declaring `resource function post invocations(...)` in the type would fix one parameter list and
return type, while the listener accepts many (any `anydata` payload type, the context anywhere or
not at all). The plugin makes both resources mandatory (`101`, `113`) with that flexibility kept.

#### The readiness resource

The reference lets an agent register a readiness handler (`readiness_handler`, `core/_base.py:771-790`)
that replaces the default `200 {"status":"healthy"}` (`_readiness_endpoint`, `core/_base.py:1200-1210`).
Here the `get readiness` resource is that handler, and it is required, so every agent states its
readiness logic explicitly (often just "always ready").

- **No parameters.** The reference passes the raw request, but a health probe carries no body and no
  platform headers (no session, invocation or user ID), so neither an `@http:Payload` nor an
  `azure:FoundryContext` parameter would have anything to bind. A readiness check that needs state
  reads it from the module (for example a flag set when a model client is warmed up). An
  `http:Request` parameter is not supported by any Foundry resource. The compiler plugin rejects any
  parameter (`114`).
- **Returns**, mapped by `toReadinessResponse`:
  - `()` (or no return type): the default response, `200` with `{"status":"healthy"}`
    (`application/json`), byte-for-byte the reference's default. For `post invocations` `()` is
    `202 Accepted`, but readiness has no "accepted" meaning; a resource that returns nothing reports
    ready, as the reference does with no handler registered, so `resource function get readiness() {}`
    is the minimal "always ready" probe.
  - any other `anydata` value: `200` with that body, by the same rule as `post invocations` (JSON, or
    `text/plain` for `string`, and so on).
  - `http:Response` or a status-code record: sent as it is, so `http:ServiceUnavailable` (with a body
    and headers such as `retry-after`) reports "not ready". Foundry treats any non-2xx as not ready.
  - an error, returned or panicked: as the http module maps an error: a `500` with the error envelope
    and the generic `Internal server error` message, or the status of an `httpscerr` status-code error
    (so `httpscerr:ServiceUnavailableError` is a `503`). In the reference an exception raised by the
    readiness handler reaches Starlette's `ServerErrorMiddleware`, which also answers `500`.
  - anything else (a stream): a `500`; the compiler plugin rejects it (`110`, `111`).
- **Not a protocol endpoint.** Readiness responses carry `x-platform-server` and `x-request-id`, but
  never `x-platform-error-source`, `x-platform-error-detail` or the `x-agent-*` ID headers, whatever the
  status, as in the reference, where nothing classifies the readiness response. The listener-owned
  headers an `http:ApplicationResponseError` brings from another service's response are dropped, as on
  the protocol routes.
- **`HEAD /readiness`** calls the readiness resource and sends the `GET` response without its body, as
  Starlette serves `HEAD` on a `GET` route.
- **Missing at run time** (only possible if the compiler plugin did not run): the default
  `200 {"status":"healthy"}`, logged at debug level, as the reference answers when no handler is
  registered. A `500` would take a running agent out of rotation for a mistake the compiler already
  reports. A readiness resource with a parameter, or a dispatcher with no linked service (a probe that
  races a detach), is a `500`, unclassified like every readiness response.

## Dispatcher design

- `FoundryListener.attach` creates an internal `FoundryDispatcherService` (an `isolated service
  class`) and attaches *it* to the `http:Listener`. The user's service and the dispatcher are
  linked as native data (same as `ai:Listener`), so the dispatcher holds no Ballerina state and
  requests run concurrently. The link is made before the dispatcher is attached, so it never
  serves a request without it. The user's service records one dispatcher per `FoundryListener`,
  so the same service can be attached to several listeners and `detach` on one listener removes
  only that listener's dispatcher. Attaching a service twice to the same listener is an error.
- `attach` accepts only the root base path (`()`, `"/"` or empty): Foundry calls `/readiness` and
  `/invocations` at the root (`core/_base.py:482`), and only a dispatcher at the root also gets the
  platform headers onto unmatched paths.
- **Decision: a new native adaptor in `ai.azure`** (`NativeFoundryServiceAdaptor` links the
  services; `NativeFoundryResourceInvoker` calls the user's resources), not reuse of the
  `ballerina/ai` one. The `ai` adaptor is internal Java (not exported) and hard-codes the
  `chat`/`decision` resources and a fixed payload type. The Foundry adaptor instead:
  - finds `post invocations`, `get readiness`, `get invocations/*` and `post invocations/*/cancel` by
    accessor and path shape (`["invocations"]`, `["readiness"]`, `["invocations", "^"]`,
    `["invocations", "^", "cancel"]`, with `^` for a path parameter as `getResourcePath()` reports it);
    the signature it reports (`payloadType`, `hasContext`) lets the dispatcher reject a readiness
    resource that declares a parameter before calling it;
  - works out each parameter's role (path parameters first, then the `@http:Payload` parameter and
    the `azure:FoundryContext` parameter, each optional and in any order) and builds the argument
    list in declared order. Any other parameter is an error (rejected at compile time by the
    compiler plugin, and a `500` if it is ever reached at run time);
  - reports the declared payload type to the dispatcher, which binds the body in Ballerina: a
    `string`, `byte[]` or `xml` subtype is read as UTF-8 text, bytes or XML; any other `anydata`
    type is parsed with `data.jsondata`'s `parseBytes` straight to the declared type, with no data
    projection (as `ballerina/http`'s record binding) and constraint validation. This is strict: a
    closed record rejects unknown fields and a fraction is not accepted for an `int`. (`http` itself
    converts an already-parsed `json` value with `parseAsType`, which rounds `1.5` to `2`.) An empty
    body binds to `()` when the type allows nil, to `""` / `[]` for text and bytes, and is otherwise
    a `400`. The declared type, not `content-type`, decides how the body is read. A binding failure
    is a `400 invalid_request` with `x-platform-error-source: user` and a fixed message that never
    quotes the body. Only that message and the underlying error's type are logged (debug level),
    never the parser's message, which quotes the offending value;
  - returns a panic in the user's resource as an error, so the request gets a `500` instead of no
    response;
  - keeps `http`'s locking: an isolated resource of an isolated service runs on the dispatcher's
    (concurrent-safe) strand, and any other resource is called from a new virtual thread with a
    strand that is not concurrent-safe, so it holds the runtime's global lock as it would on an
    `http:Listener`. (Reusing the dispatcher's strand would run a non-isolated service with no
    lock, since the runtime reuses the current strand whatever metadata it is given.)
  It keeps the observability handling from the `ai` adaptor, so traces name the user's service
  as the entrypoint, and gives the user's resource span the Foundry attributes (see
  [Tracing](#tracing)).
- **Result mapping mostly follows `ballerina/http`.** A plain `anydata` result is sent as `200`
  (wrapped in `http:Ok`), as the reference's handlers do, instead of the `201` that `http` uses for
  a `post` resource. Otherwise the dispatcher returns the user's value unchanged, so `http` builds
  the response as for a `post` resource of its own: `anydata` → `200` (JSON, or `text/plain` for `string`, `application/xml` for
  `xml`, `application/octet-stream` for `byte[]`), `()` → `202` with no body, `http:Response` as
  is, a status-code record with its status, body, headers and `mediaType`. A returned error goes to
  the error interceptor. The resolved IDs are stored in the `http:RequestContext`, and the response
  interceptor adds `x-agent-invocation-id` / `x-agent-session-id` to every response of the request,
  including error-interceptor responses, replacing any value the user set. A returned stream is
  outside the contract: it is closed and answered with a `500` classified as `upstream`.
- The dispatcher declares a catch-all `default [string... path]` resource, so unknown paths
  (`404`) and wrong methods on known paths (`405`) also get the platform headers. Their body is the
  error envelope (codes `not_found` and `method_not_allowed`), not Starlette's plain-text
  `Not Found` / `Method Not Allowed`; see the deviations below. `HEAD` on a `GET` route is served
  there with the `GET` response, as Starlette does (so `HEAD /invocations/{id}` calls the get
  resource and `HEAD /readiness` the readiness resource); the HTTP transport doesn't send the body of a
  `HEAD` response.
- The dispatcher's interceptors are a response interceptor (platform headers, ID headers, `upstream`
  for a user's 4xx/5xx) and an error interceptor. There is deliberately no request interceptor:
  http 2.18 never answers a request whose path a request interceptor's `[string... path]` can't
  decode (for example `/x/%zz`), so the connection would hang. The response interceptor takes the
  `http:Request` and resolves `x-request-id` itself.
- **Error classification.** Every protocol resource (`/invocations` and the routes under it) turns
  the errors it meets into responses itself, so it can classify them (`foundry_errors.bal`):
  - an error the user's resource returns or panics with is `upstream`: a `500` with the generic
    `Internal server error` message, or the status of an `httpscerr` status-code error (or an
    `http:ApplicationResponseError`), with no detail header. The headers an `httpscerr` error carries
    are the agent's choice and are kept, like those of an `http:Response` (so an
    `x-platform-error-source` the agent set wins). The headers of an `http:ApplicationResponseError`
    come from another service's response (possibly another Foundry agent's), so the ones the listener
    owns (`x-platform-error-source`, `x-platform-error-detail`, `x-agent-invocation-id`,
    `x-agent-session-id`) are dropped and the others (for example `retry-after`) kept;
  - a failure of the listener itself is an internal `FoundryPlatformError`, the counterpart of the
    reference's `PLATFORM_ERROR_TAG`: a `500` with `platform` and `x-platform-error-detail` =
    `"<type>: <message>"`, truncated as the reference does (`detail[:2048 - len(suffix)] + suffix`,
    suffix `...[truncated]`). Its message is always text the listener writes, never request content
    or a secret. The response interceptor marks a protocol request with a request-context flag and
    adds `upstream` to any 4xx/5xx response of such a request that has no `x-platform-error-source`
    yet, which is exactly the responses the user's resource returned itself;
  - the error interceptor only sees errors the http module raises for a protocol request before the
    resource runs (for example a path segment it can't decode): a 4xx is `user`, a 5xx `platform`
    with a detail that names only the error type.

  Which existing failure paths are which:

  | Failure | Source | Why |
  |---|---|---|
  | The user's resource returns an error or panics | `upstream` | The agent's code (`_classify_error` without the platform tag) |
  | The user's resource returns an `httpscerr` error, a 4xx/5xx `http:Response` or status-code record | `upstream` (unless the user set the header) | The agent chose the status |
  | `post invocations` missing (`501`), get/cancel missing (`404`), no OpenAPI document (`404`) | `upstream` | As the reference |
  | A resource with an unsupported parameter (including a non-`string` path parameter), a payload parameter on get, or a return value outside the contract (including a stream) | `upstream` | The agent author's mistake; the reference also classifies a handler returning a non-`Response` as `upstream` (the `AttributeError` it raises is untagged) |
  | No service linked with the dispatcher (a request racing a detach), a resource that disappears between lookup and call, a path-argument count mismatch, an interrupted or failed call of the resource outside the user's code | `platform` | Listener failures; the message names only fixed text (for an unexpected Java exception, only its class) |
  | A body that can't be bound, a 4xx the http module raises for a protocol request (a protocol path that can't be decoded is answered `400`) | `user` | The caller's request |
  | An invalid `x-ms-original-subject` | `platform`, detail `invalid_original_subject` | As the reference |
  | Readiness, whatever the user's readiness resource returns (including an error, a `503`, a readiness resource with a parameter, or no linked service); the catch-all `404`/`405` (including `405` on `/invocations`) | none | Not protocol responses: nothing classifies the readiness response in the reference, and Starlette produces the `404`/`405` |

## Behaviour and its source

| Behaviour | Implementation | Reference |
|---|---|---|
| Port: explicit argument → `PORT` → `8088` | `init(listenOn = ())` | `core/_config.py:220-236` (`resolve_port`), `core/_constants.py:17-18` |
| Listen on all interfaces, HTTP/1.1, no TLS | `http:Listener` default host | deploy-hosted-agent docs |
| Accept an existing `http:Listener` | `init(http:Listener)` | `ai:Listener`, `websocket:Listener`, `mcp:Listener` |
| `GET /readiness` → the response of the user's required `get readiness` resource; `()` → `200 {"status":"healthy"}`, `application/json` (the reference's default) | dispatcher `get readiness` → `readinessResponse`, `toReadinessResponse` | `core/_base.py:46`, `482`, `771-790`, `1200-1210` |
| `HEAD /readiness` → the `GET /readiness` response without a body (the readiness resource is called) | catch-all resource → `headResponse` | Starlette serves `HEAD` on a `GET` route |
| An error from the readiness resource → `500` (or an `httpscerr` status), error envelope, no `x-platform-error-source`; a readiness response never carries the `x-agent-*` ID headers | `readinessErrorResponse` | `ServerErrorMiddleware` answers an exception from the readiness handler with a `500` |
| Readiness resource missing at run time → `200 {"status":"healthy"}` | `readinessResponse` | `core/_base.py:1210` (no handler registered) |
| `x-platform-server` on every response, format `<sdk>/<version> (<runtime>/<version>)` | dispatcher + catch-all resource; value `ballerinax-ai.azure/<pkg version> (ballerina/<runtime version>)`. The runtime version is the distribution the package was built with: the program JVM carries no Ballerina version under `bal run` or `java -jar` (the `ballerina.version` system property is used when set) | `core/_base.py:180-202`, `662-693`; `core/_server_version.py:11-33` |
| `x-request-id` on every response: the trace ID of a valid incoming `traceparent` (32 chars, not all zeros), else the incoming `x-request-id`, else a generated UUID (32 hex digits) | dispatcher | `core/_request_id.py:51-120`, `core/_middleware.py:97-142` (**not in the prompt; included**). The reference asks OpenTelemetry for an active span first; none is active where it resolves the ID, so it parses `traceparent` |
| Graceful stop with timeout; `AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS`, default 30 | `gracefulStopTimeout` | `core/_config.py:239-266`, `core/_base.py:404-429` |
| Routes: `POST /invocations`, `GET /invocations/{id}`, `POST /invocations/{id}/cancel`, `GET /invocations/docs/openapi.json` | dispatcher resources | `inv/_invocation.py:277-316` |
| Session ID on invoke: `agent_session_id` query → `FOUNDRY_AGENT_SESSION_ID` → UUID; empty counts as absent; invalid → UUID; a repeated query parameter resolves to its last value (Starlette `query_params.get`). The raw query is parsed as `parse_qsl(keep_blank_values=True)` does (split on `&`, `+` → space, name and value percent-decoded), not through `http:Request.getQueryParamValues`, which splits values on commas, trims them and doesn't decode names, so `agent_session_id=a,b` is invalid (→ UUID) rather than `b` | `resolveInvokeSessionId`, `lastQueryParamValue`, `lastRawQueryParamValue` | `inv/_invocation.py:547-551`, `135-152` |
| Session ID on get/cancel: query → env → `""`; empty counts as absent; invalid → `""` (no UUID is generated, and no fallback to the env value) | `resolveGetOrCancelSessionId` | `inv/_invocation.py:647-662` |
| Invocation ID on invoke: `x-agent-invocation-id` header (first value) if valid, else UUID (`str(uuid4())`, with dashes) | `resolveInvokeInvocationId` | `inv/_invocation.py:542-545` |
| Invocation ID on get/cancel: the raw path segment percent-decoded once, as the reference's ASGI server decodes it (`+` stays `+`, `abc%2541` → `abc%41`), for `GET`, `HEAD` and cancel alike, kept even when it fails validation, passed to the resource and in `FoundryContext.invocationId` unchanged. It is sent back in `x-agent-invocation-id` only when it is a valid header value (visible ASCII, inner spaces or tabs); otherwise (CR/LF or other control characters, non-ASCII text, leading or trailing whitespace) the header is left out and a warning is logged without the value, so it can't inject a header or break the response | `invocationIdFromRawPath`, `decodePathSegment`, `resolveGetOrCancelInvocationId`, `isHeaderSafe` | `inv/_invocation.py:643-645`. The reference writes the raw value into the header: h11 then rejects CR/LF and a non-Latin-1 value raises, so such requests end in a bare `500` there |
| Get/cancel route precedence: `GET /invocations/docs/openapi.json` is the OpenAPI route, `GET /invocations/docs` and `POST /invocations/docs/cancel` are get/cancel for the ID `docs`; wrong methods get `405` with `Allow: GET, HEAD` (get, OpenAPI) or `Allow: POST` (cancel) | literal path segments win in `http`; `allowedMethods` | `inv/_invocation.py:277-316` (Starlette tries routes in order) |
| ID rule: 1–256 chars, `^[a-zA-Z0-9\-_.:]+$`, matched against the whole value (Python's `re.match` with `$` also accepts a trailing newline; we don't, so an ID can't break a response header) | `sanitizeFoundryId` | `inv/_invocation.py:95-97` |
| `x-agent-user-id`, `x-agent-foundry-call-id` read as optional; empty → `()` | `FoundryContext.userId`, `callId` | `inv/_invocation.py:155-175`; `core/_platform_headers.py:56-76` |
| `x-client-*` pass-through headers, keyed by lower-case name; a repeated header keeps all values joined with `", "` (RFC 9110 field combination; the reference has no rule) | `clientHeaders` | `core/_platform_headers.py:80-85` |
| `traceparent`, `x-ms-client-request-id`, `x-request-id` (plus `tracestate`, `baggage`); first value, empty → `()` | `FoundryTraceContext` | `core/_platform_headers.py:35-41`, `89-97` |
| `x-ms-original-subject`: RFC 9651 dictionary profile with unique `oid`/`tid`/`idtype` string members; exactly one header field; empty dictionary rejected | `parseOriginalSubject` (a hand-written scanner equivalent to the reference's member regex) | `core/_request_context.py:46-52`, `76-111` |
| Invalid original subject → `400`, `x-platform-error-source: platform`, `x-platform-error-detail: invalid_original_subject`, both ID headers; the resource is not called and the value is never echoed or logged | dispatcher | `inv/_invocation.py:178-192`, `553-559` |
| `x-agent-invocation-id` and `x-agent-session-id` on invoke responses, including errors | dispatcher | `inv/_invocation.py:585-617` |
| `x-agent-invocation-id` only (no session header) on get/cancel responses, including the `404`s, the `400` for an invalid original subject and every error response | dispatcher | `inv/_invocation.py:664-689` |
| Error envelope `{"error":{"code","message"}}` | `errorResponse` | `core/_errors.py:28-63` |
| Invoke resource missing → `501` `not_implemented`, `upstream`, both ID headers | dispatcher | `inv/_invocation.py:401-404`, `588-601` |
| Get/cancel not implemented → `404` `{"error":{"code":"not_found","message":"get_invocation not implemented"}}` (`cancel_invocation` for cancel), `upstream` | dispatcher | `inv/_invocation.py:406-424` |
| No OpenAPI spec → `404` `No OpenAPI spec registered`, `upstream`; otherwise `200` with the spec as JSON (`application/json`), no ID headers | dispatcher | `inv/_invocation.py:446-455` |
| Error from the user's code → `500 "Internal server error"`, `upstream`, no detail; an `httpscerr` status-code error keeps its status | `foundryErrorResponse` | `inv/_invocation.py:78-92`, `602-617`, `676-689` |
| A 4xx/5xx `http:Response` or status-code record from the user's code → `upstream` added unless the user set the header | response interceptor | deviation, see below |
| Platform (framework) failure → `500`, `platform`, detail `"<type>: <message>"` truncated to 2048 chars with `...[truncated]` | `FoundryPlatformError`, `classifyFoundryError`, `truncateErrorDetail` | `inv/_invocation.py:78-92`; `core/_platform_headers.py:106-130` |
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
| `x-platform-error-source` on every 4xx/5xx from protocol endpoints | the reference adds it only to responses the framework builds; a 4xx/5xx the handler returns itself has none | We follow the platform contract doc instead and add `upstream` to any 4xx/5xx the user returns (`http:Response`, status-code record, `httpscerr` error), unless the user already set the header. Responses that are not from a protocol route (readiness, the catch-all `404`/`405`) are not classified, as in the reference. |
| 4xx generated by the HTTP stack itself → `user` | only what reaches the listener can be classified | A 4xx the http module raises after routing (for example a `%` escape it can't decode, which it would answer with a `500`, is answered `400 invalid_request`) is `user`. The transport's own request limits (`413` body too large, `414` URI too long, `431` headers too large) are answered by the HTTP transport before any service or interceptor runs, so they carry neither `x-platform-error-source` nor `x-platform-server`. |
| "Detail when there is diagnostic detail" | detail only on `platform` errors (and `invalid_original_subject`) | User error messages never reach the header, so user content and secrets can't leak. |
| Result mapping follows `ballerina/http`, except `anydata` → `200` | the reference sends whatever `Response` the handler builds (its samples send `200`) | A `post invocations` returning `anydata` gets `200 OK`, matching the reference, not the `201 Created` of a plain Ballerina `post` resource; `()` gets `202 Accepted`; return `http:Created` (or an `http:Response`) for a `201`. Annotations on the user's return type (`@http:Payload {mediaType}`, `@http:Cache`) are not applied, because `http` sees the dispatcher's resource; use a status-code record's `mediaType` or an `http:Response` instead. |

## Other differences from the reference

| Reference | Here | Why |
|---|---|---|
| The path is decoded once by the ASGI server before routing (`unquote`): `+` stays `+`, `%2F` splits the path, a malformed `%` escape is kept as it is | The get/cancel ID is the raw path segment decoded once the same way (`+` stays `+`), but `%2F` stays inside the ID (as `/`). `http` decodes a path parameter twice before the resource runs, so a malformed escape (`%zz`), or an ID that still holds one after one decoding (`%25zz`), is rejected: `400 invalid_request` "The request path could not be decoded.", `user`, for `GET`, `HEAD` and cancel alike. Any other path that can't be decoded gets the catch-all `404` | `http` routes on raw segments and decodes path parameters itself (twice); reading the raw path gives the reference's value wherever `http` lets the request through. Only IDs that are invalid anyway are affected |
| Hypercorn's graceful shutdown returns as soon as in-flight requests finish | `http:Listener.gracefulStop` closes the server socket and then always waits the whole `gracefulStopTimeout` (the transport sleeps for it), even when nothing is in flight | A hosted agent's graceful stop takes `AGENTSERVER_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` (30 s by default). The tests use short timeouts for this reason. Fixing it needs the `http` module |

## Reference behaviour the prompt doesn't mention

| Reference behaviour | Included? |
|---|---|
| `x-request-id` response header on every response (`core/_request_id.py`) | **Yes** |
| `405` for a known path with the wrong method (Starlette routing) | **Yes**, via the catch-all resource, with the `Allow` header and `HEAD` served on `GET` routes. The `404`/`405` body is the error envelope instead of Starlette's plain text, so all listener errors have one shape |
| Custom readiness handler (`readiness_handler`, `core/_base.py:771-790`, `1208`) | **Yes**, and required: the service's `get readiness` resource is the handler. It takes no parameters (the reference passes the raw request, but a probe carries nothing to bind), its result replaces the default response, and `()` gives the reference's default `200 {"status":"healthy"}`. See [The readiness resource](#the-readiness-resource) |
| `/invocations/docs/asyncapi.json` and `.yaml` (`inv/_invocation.py:284-295`) | No: these describe the WebSocket transport, which is out of scope |
| OpenTelemetry baggage entries `azure.ai.agentserver.invocation_id` / `session_id` (`inv/_invocation.py:561-575`), which the span processor turns into attributes of every span (`core/_tracing.py:797-874`) | **Partly**: when Ballerina tracing is enabled, the request span and the user resource's span get the same attributes; spans started beneath the user's resource don't, and no baggage is propagated. See [Tracing](#tracing) |
| `FOUNDRY_AGENT_SESSION_GUID` / `FOUNDRY_HOSTING_ENVIRONMENT` validation (`core/_config.py:50-55`) | No: not needed for Invocations routing |
| `platform_headers()`: `x-agent-foundry-call-id` (only when present, never `x-agent-user-id`) for outbound calls to Foundry platform services (`core/_request_context.py:221-239`) | **Yes**, as `azure:foundryPlatformHeaders(FoundryContext ctx) returns map<string>`, which can be passed as an `http:Client` method's `headers`. Outbound headers are not forwarded automatically; the agent adds them to its own outbound calls |
| `model_attribution_headers()` / `x-ms-foundry-baggage` (`core/_request_context.py:148-219`) | No: outbound, experimental, out of scope. `originalSubject` is exposed so it can be added later. |
| Shutdown handler hook (`core/_base.py:760`) | No: Ballerina code can use a module-level `listener`'s lifecycle or `runtime:onGracefulStop` |
| Resilient task manager, WebSocket, Responses, snapshot/restore | No: out of scope per the prompt |
| SSE streaming responses with keep-alive comments (`inv/_sse.py`, `SSE_KEEPALIVE_INTERVAL`) | No: dropped from scope. A resource that returns a stream gets a `500` classified as `upstream`, and the compiler plugin rejects stream return types |

## Tracing

The reference installs an OpenTelemetry span processor, `_FoundryEnrichmentSpanProcessor`
(`core/_tracing.py:797-874`), that stamps Foundry attributes on **every** span of the process: on start, the
`microsoft.foundry` marker, the project ID and the session, conversation and invocation IDs it finds in
the OpenTelemetry baggage (`POST /invocations` puts the invocation and session IDs there,
`inv/_invocation.py:561-575`); on end, the agent identity. Ballerina has no span processor hook and no
OpenTelemetry context or baggage that follows a request through Ballerina code, so the listener tags the spans
it can reach.

**When.** Only when Ballerina tracing is enabled (`ballerina.observe.tracingEnabled`, with the program built
with `observabilityIncluded`). Otherwise the dispatcher checks one static flag per protocol request and builds
nothing.

**Which spans.** For `POST /invocations`, `GET /invocations/{invocationId}` (and `HEAD`) and
`POST /invocations/{invocationId}/cancel`:

- the dispatcher's request span: the span of the http listener's observer context, which the dispatcher
  resource continues (it carries `http.method`, `http.url`, `http.status_code`);
- the span of the user's resource, a child of the request span.

Readiness, the OpenAPI route and the catch-all `404`/`405` are not tagged, although the reference's
processor would stamp `microsoft.foundry` and the identity on their spans too: they are not protocol
requests, and readiness is probed every few seconds.

**Attributes** (names and values as in the reference; a value that is not configured, or empty, is left out,
as the reference does):

| Attribute | Value | Reference |
|---|---|---|
| `microsoft.foundry` | `True` | `core/_tracing.py:66`, `83`, `818` |
| `microsoft.foundry.project.id` | `FoundryAgentInfo.projectArmId` (`FOUNDRY_PROJECT_ARM_ID`) | `core/_tracing.py:64`, `819-820`; `core/_config.py:424-433` |
| `gen_ai.agent.name`, `gen_ai.agent.version` | `FoundryAgentInfo.name` / `version` | `core/_tracing.py:59-60`, `858-863` |
| `gen_ai.agent.id` | `FOUNDRY_AGENT_INSTANCE_CLIENT_ID`, else `<name>:<version>`, else `<name>` (not `FOUNDRY_AGENT_ID`, the agent GUID, which the reference doesn't put on spans) | `core/_tracing.py:56`, `864-865`; `resolve_agent_id`, `core/_config.py:375-394` |
| `microsoft.a365.agent.blueprint.id` | `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID` | `core/_tracing.py:57`, `866-867` |
| `microsoft.tenant.id` | `FOUNDRY_AGENT_TENANT_ID` | `core/_tracing.py:58`, `868-869` |
| `azure.ai.agentserver.invocations.invocation_id` | the resolved invocation ID; on get/cancel only when the path value is a valid ID (`[a-zA-Z0-9\-_.:]{1,256}`), so a value that is not an ID (request content) never becomes an attribute | `inv/_constants.py:22` (`ATTR_SPAN_INVOCATION_ID`); `core/_tracing.py:77`, `831-833` |
| `azure.ai.agentserver.invocations.session_id` | the resolved session ID, when not empty | `inv/_constants.py:23` (`ATTR_SPAN_SESSION_ID`) |
| `microsoft.session.id` | the same session ID | `core/_tracing.py:65`, `825-827` |
| `azure.ai.agentserver.invocations.error.code` | the error-envelope code (`internal_error`, `invalid_request`, `not_implemented`, `not_found`, `method_not_allowed`), request span only | `inv/_constants.py:24` (`ATTR_SPAN_ERROR_CODE`) |

The three agent identity values that `FoundryAgentInfo` doesn't carry (`FOUNDRY_AGENT_INSTANCE_CLIENT_ID`,
`FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID`, `FOUNDRY_AGENT_TENANT_ID`) are read from the environment once, at module
initialisation, so the public API is unchanged. The error code is set wherever the listener builds an error
envelope (`errorResponse`), so the catch-all `404`/`405` spans, and a readiness error, get it too. `ATTR_SPAN_ERROR_MESSAGE` is not
set: like `x-platform-error-detail`, attributes never carry user error messages or request content. (Ballerina's
own instrumentation does record an `error.message`, with the error's message and stack trace, on the span of a
user resource that returns an error; that is the runtime's standard behaviour for every Ballerina resource, not
something the listener adds.)

In the reference, `ATTR_SPAN_SESSION_ID`, `ATTR_SPAN_ERROR_CODE` and `ATTR_SPAN_ERROR_MESSAGE` are defined but
not set by the HTTP invocations code, and get/cancel set no baggage, so their spans get no IDs there. The
listener sets the session and error-code attributes anyway, and tags get/cancel with the IDs it resolved.

**How.** `tagFoundryRequestSpan` (`foundry_tracing.bal`) builds the attributes (`foundrySpanTags`) and
`FoundryTracing.setFoundrySpanTags` (`native/.../FoundryTracing.java`) writes them straight to the current
span with `BSpan.addTags`, not with `ObserverContext.addTag`: the observer context's tags also become metric
tags, and per-request values would give the metrics unbounded tag values. The attributes are also kept as a
property of the dispatcher's observer context. The user's span doesn't exist yet when the dispatcher calls
the resource, so the observer context the invoker creates for it (`newUserContext`, see the dispatcher design)
is a small `ObserverContext` subclass that writes the attributes to the span the runtime gives it when the
resource starts (`setSpan`), the closest Ballerina has to a span processor's `on_start`.

**What Ballerina can't do.** Spans started beneath the user's resource (for example a model provider's
`http:Client` calls, or `ballerina/ai` agent spans) get fresh observer contexts from the runtime
(`ObserveUtils.startCallableObservation` creates a new `ObserverContext` with the parent link only), so they
can't be given the attributes; a trace backend can still find them through the tagged parent. No W3C `baggage`
is added to outbound requests: neither `ballerina/observe` nor the runtime has a baggage API (a span is started
from the thread's current OpenTelemetry `Context` plus the parent span, `BSpan.start`), and a `Context` made
current on a thread would not follow a Ballerina strand across yields and virtual threads, so it couldn't be
done cleanly. Incoming `baggage` (including `x_request_id`, which the reference adds,
`core/_tracing.py:529-536`) is exposed on `FoundryContext.trace` but not turned into attributes.

**Tests.** The package tests run with tracing enabled and `ballerina/observe`'s in-memory `mock` tracer provider
(`ballerina/tests/Config.toml`; `bal test --observability-included`, passed through `testCoverageParam` in
`ballerina/build.gradle`, so the published package itself gains no observability dependencies). `foundry_tracing_test.bal`
reads the finished spans back with `observe.mockextension:getFinishedSpans` and checks the attributes on the
request and user spans, the parent link, the error code without the user's message, the get route and the
absence of the attributes on the user's outbound call. The mock provider's tracers are keyed by service name; a
service with no attach point (the dispatcher, a service object or a declaration without a base path) is named
`<org>_<package>_svc_<n>` by the compiler (`JvmObservabilityGen`), so the test scans those names. The mock
provider exports nothing and its propagators are no-ops, so outbound requests of the other tests carry no
trace headers and their behaviour doesn't change; metrics stay disabled. `foundrySpanTags` also has unit tests.

## Compiler plugin

`AiAzureCodeAnalyzer` registers `FoundryServiceValidationTask`
(`compiler-plugin/src/main/java/io/ballerina/lib/ai/azure/FoundryServiceValidationTask.java`) next to
the existing code modifier. It validates every service whose type is a subtype of
`azure:FoundryInvocationService`: service declarations (`service azure:FoundryInvocationService on
...`), service classes (`service class S { *azure:FoundryInvocationService; ... }`) and service object
constructors whose type is the Foundry service type. A service declaration without a type descriptor
(`service on foundryListener { ... }`, `service on new azure:FoundryListener(8088) { ... }`) takes its type
from the listener's `attach`, so it is validated when one of its listeners is an `azure:FoundryListener`
(a listener expression typed `azure:FoundryListener|error` counts). Types are resolved through the semantic model, not
by text, so import prefixes (`import ballerinax/ai.azure as foundry;`, `import ballerina/http as h;`)
and type aliases (`type Ctx azure:FoundryContext;`) work, and plain `http:Service` services in the same
package are ignored. Like `ballerina/ai`'s `ChatResourceValidationTask`, the task skips a module that
already has compilation errors.

Every diagnostic is an error. The codes are defined in
`compiler-plugin/src/main/java/io/ballerina/lib/ai/azure/diagnostics/FoundryDiagnostic.java`; `{n}` is a
placeholder.

| Code | Rule | Message | Points at |
|---|---|---|---|
| `AI_AZURE_FOUNDRY_101` | The service declares `post invocations` | an `` `azure:FoundryInvocationService` `` must declare a `` `resource function post invocations` ``, which serves `` `POST /invocations` ``. | The service type of a declaration (the `service` keyword when it has none), the class name, or `service object` |
| `AI_AZURE_FOUNDRY_102` | The only resources are `post invocations`, `get readiness`, `get invocations/[string invocationId]` and `post invocations/[string invocationId]/cancel` (any other accessor or path, such as `post readiness` or `get readiness/status`, `default`, a rest path parameter or `.` is rejected) | the resource '{0}' is not supported in an `` `azure:FoundryInvocationService` ``, which serves only `` `post invocations` ``, `` `get readiness` ``, `` `get invocations/[string invocationId]` `` and `` `post invocations/[string invocationId]/cancel` ``. | The accessor and resource path |
| `AI_AZURE_FOUNDRY_103` | No remote functions | the remote function '{0}' is not allowed in an `` `azure:FoundryInvocationService` ``; declare resource functions instead. | The function name |
| `AI_AZURE_FOUNDRY_104` | A parameter is either the `@http:Payload` parameter or an `azure:FoundryContext` parameter (an un-annotated parameter of another type, `http:Request`, `http:Caller`, `http:Headers`, a query parameter, `azure:FoundryContext?`, a defaultable non-payload parameter, a rest or included-record parameter are rejected) | the parameter '{1}' of the resource '{0}' is not supported. Declare only {2}. (`{2}` is "an `` `azure:FoundryContext` `` parameter" on the get resource, otherwise "an `` `@http:Payload` `` parameter and an `` `azure:FoundryContext` `` parameter") | The parameter |
| `AI_AZURE_FOUNDRY_105` | At most one `@http:Payload` parameter | the resource '{0}' declares more than one `` `@http:Payload` `` parameter. | The second payload parameter |
| `AI_AZURE_FOUNDRY_106` | At most one `azure:FoundryContext` parameter | the resource '{0}' declares more than one `` `azure:FoundryContext` `` parameter. | The second context parameter |
| `AI_AZURE_FOUNDRY_107` | The payload type is a subtype of `anydata` (`json`, `string`, `byte[]`, `xml`, records, arrays, maps, unions of these) | the `` `@http:Payload` `` parameter '{1}' of the resource '{0}' must be a subtype of `` `anydata` `` (for example `` `json` ``, `` `string` ``, `` `byte[]` ``, `` `xml` `` or a record), found '{2}'. | The parameter type |
| `AI_AZURE_FOUNDRY_108` | No payload on the get resource | the resource '{0}' can't declare an `` `@http:Payload` `` parameter, because a `` `GET` `` request has no body to bind. | The parameter |
| `AI_AZURE_FOUNDRY_109` | The path parameter of get and cancel is `string` | the path parameter '{1}' of the resource '{0}' must be of type `` `string` ``, found '{2}'. | The path parameter type |
| `AI_AZURE_FOUNDRY_110` | The return type is a subtype of `anydata\|http:Response\|http:StatusCodeResponse\|error` (nil is allowed through `anydata`; no return type means `()`; the whole type is checked, so an intersection such as `readonly & (json\|error)` is accepted) | the resource '{0}' must return a subtype of `` `anydata\|http:Response\|http:StatusCodeResponse\|error` ``, found '{1}'. | The return type |
| `AI_AZURE_FOUNDRY_111` | The return type contains no stream | the resource '{0}' returns a stream ('{1}'), but streaming responses are not supported by `` `azure:FoundryListener` ``; return the complete response instead. | The return type |
| `AI_AZURE_FOUNDRY_112` | A service declaration has no base path other than `/` (or a string whose value, after trimming, is made only of `/`; escapes such as `"\u{2F}"` are decoded first, as the listener sees the value) | an `` `azure:FoundryInvocationService` `` must be attached at the root base path, because Foundry calls `` `/readiness` `` and `` `/invocations` `` at the root; remove the base path '{0}'. | The base path |
| `AI_AZURE_FOUNDRY_113` | The service declares `get readiness` | an `` `azure:FoundryInvocationService` `` must declare a `` `resource function get readiness` ``, which serves the `` `GET /readiness` `` probe. | As `101` |
| `AI_AZURE_FOUNDRY_114` | `get readiness` declares no parameters (of any kind: payload, context, `http:Request`, defaultable, rest) | the parameter '{1}' of the resource '{0}' is not supported: the readiness probe carries no payload or platform headers, so the resource must declare no parameters. | The parameter |

Rules `104` to `109` apply to the invocation resources, `114` to `get readiness`; `110` and `111` apply to
all four. A service missing both required resources gets both `101` and `113`, at the same position.
`101` keeps its meaning (only `post invocations`), so the readiness rule has its own code.

Types in messages are shown as written in the source (for example `azure:FoundryContext`). A return
type that holds a stream gets only `111`, not also `110`. A client object (such as `http:Caller`) or a
function type in a resource's return type is already a compiler error (`BCE4033`), so the plugin never
sees it.

### Compile time versus run time

The rules were checked against `NativeFoundryResourceInvoker` (`ResourceParams`, `findResource`) and the
dispatcher (`dispatchInvocationRoute`, `toFoundryResourceResponse`, `readinessResponse`,
`toReadinessResponse`) and `FoundryListener.attach`. Everything the runtime serves compiles, and
everything the runtime answers with a `500` (classified as `upstream` on a protocol route, unclassified on
readiness) or rejects at attach is a compile error. Where the two differ, the compiler is deliberately the
stricter side:

| Shape | Runtime | Compiler plugin |
|---|---|---|
| Path parameter of a type that accepts every string but isn't `string`, such as `string\|int` | Served | `109`: the documented contract is `[string invocationId]` |
| No `post invocations` | `501 not_implemented` | `101` |
| No `get readiness` | `200 {"status":"healthy"}` (the reference's default) | `113` |
| `get readiness` with a payload or context parameter, or any other parameter | `500`, unclassified; the resource is not called | `114` |
| `get readiness` returning a stream or another unsupported value | `500`, unclassified | `110`, `111` |
| Another resource, a remote function | Never called (the catch-all answers `404`/`405`) | `102`, `103` |
| `*azure:FoundryContext` included-record parameter | Passed the context | `104` |
| A Foundry service on a listener other than `azure:FoundryListener` | Not dispatched by the Foundry listener | Still validated, because the type is what is checked |

## Testing the compiler plugin

The `compiler-plugin-tests` Gradle project (`:ai.azure-compiler-plugin-tests`), modelled on
`ballerina/ai`'s, compiles one small Ballerina package per case under
`src/test/resources/ballerina_sources/foundry_service_validation/` and asserts the exact Foundry
diagnostics (code, severity, message, line and column). The expected codes and messages are written out
in the test, not formatted from the plugin's templates, so a broken template fails the tests.
`01_valid_service` uses every allowed shape (including untyped declarations on a Foundry listener, an
intersection return type and an escaped `"/"` base path) and must have no errors; one package per
diagnostic follows, plus an import alias, a service class and object constructor, non-Foundry HTTP
services in the same package (which must be ignored), untyped service declarations on a Foundry
listener (`17_untyped_service_declaration`), a missing readiness resource on every kind of service
(`18_missing_readiness_resource`) and readiness parameters (`19_readiness_parameter`). Every valid service
in these packages declares `get readiness`. Diagnostics at the same position are ordered by code.

The compiler plugin validates the packages that depend on `ballerinax/ai.azure`, not the package itself,
so the package's own tests (`ballerina/tests`) can still exercise the run-time answers to services the
plugin rejects (a missing `post invocations` or `get readiness`, unsupported parameters).

The package is built on Docker (`connector = true`), so the Ballerina Gradle plugin unpacks no
distribution. The test project's `prepareBallerinaDistribution` task builds one instead: the
`org.ballerinalang:jballerina-tools` distribution of `ballerinaLangVersion`, plus `ballerinai/observe`
(`io.ballerina:observe-ballerina`, which jballerina-tools lacks and the dependency graph needs), plus the
`ballerinax/ai.azure` bala that `:ai.azure-ballerina:build` just packed (it carries the freshly built
compiler plugin jar). The bala's version is the `Ballerina.toml` version (computed as
`ballerina/build.gradle` does, so timestamped builds work), and its platform directory is taken from the
bala's file name. Other dependencies come from Ballerina Central, as with `bal build`. The tests get
the distribution's path through the `ai.azure.test.distribution` system property, so nothing depends on
a local Ballerina installation. The root `build` task runs the tests.

## Ballerina distribution

This release moves the package from `2201.12.0` (`java21`) to `2201.14.1` (`java25`), matching
`ballerina/ai` and `ballerina/mcp`, which are already on 2201.14 / `java25`. The listener itself
doesn't need the bump: everything it uses (`http:ListenerConfiguration.gracefulStopTimeout`,
status-code response records, `http.httpscerr`) also exists in `ballerina/http` 2.14.x on 2201.12.
The bump keeps `ai.azure` on the same distribution and Java platform as the `ballerina/ai` it
depends on. As a result, users of 1.6.0 need Swan Lake Update 14 or later.

## Future WebSocket listener

`FoundryListener.init` accepts an `http:Listener`, and the dispatcher only claims the
`/invocations*`, `/readiness` and catch-all routes, so a later `websocket:Listener`-based
`/invocations_ws` listener can share the same `http:Listener` and port. Header building, ID
resolution and context parsing are package-private functions the WebSocket listener can reuse.
