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
| `post invocations` (required) | optional `@http:Payload` of `json`, `string`, `byte[]`, `xml` or any `anydata` subtype (records, arrays, maps); optional `azure:FoundryContext` | `anydata`, `http:Response`, any `http:StatusCodeResponse`, `error`, `()`, or a union of these. No streams: the listener doesn't send server-sent events |
| `get invocations/[string invocationId]` (optional) | path parameter; optional `azure:FoundryContext` | same |
| `post invocations/[string invocationId]/cancel` (optional) | path parameter; optional `@http:Payload` (bound as for `post invocations`); optional `azure:FoundryContext` | same |

The compiler plugin enforces this table (Milestone 6). Until then, a resource that breaks it is
answered at run time with a `500` classified as `upstream` (the agent author's mistake): an
unsupported parameter (including a path parameter whose type doesn't accept every `string`), an
`@http:Payload` parameter on the get resource (a GET request has no body to bind), or a return value
outside the table (including a stream). The cancel resource may declare a payload because the
reference hands its handler the raw request, so a cancel request can carry a body such as a reason.

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
  - finds `post invocations`, `get invocations/*` and `post invocations/*/cancel` by accessor and
    path shape (`["invocations"]`, `["invocations", "^"]`, `["invocations", "^", "cancel"]`, with
    `^` for a path parameter as `getResourcePath()` reports it);
  - works out each parameter's role (path parameters first, then the `@http:Payload` parameter and
    the `azure:FoundryContext` parameter, each optional and in any order) and builds the argument
    list in declared order. Any other parameter is an error (a `500` until the compiler plugin
    rejects it at compile time);
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
  as the entrypoint.
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
  resource); the HTTP transport doesn't send the body of a `HEAD` response.
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
  | Readiness, the catch-all `404`/`405` (including `405` on `/invocations`) | none | Starlette produces these in the reference |

## Behaviour and its source

| Behaviour | Implementation | Reference |
|---|---|---|
| Port: explicit argument → `PORT` → `8088` | `init(listenOn = ())` | `core/_config.py:220-236` (`resolve_port`), `core/_constants.py:17-18` |
| Listen on all interfaces, HTTP/1.1, no TLS | `http:Listener` default host | deploy-hosted-agent docs |
| Accept an existing `http:Listener` | `init(http:Listener)` | `ai:Listener`, `websocket:Listener`, `mcp:Listener` |
| `GET /readiness` → `200 {"status":"healthy"}`, `application/json`, no model calls | dispatcher `get readiness` | `core/_base.py:46`, `482`, `1200-1210` |
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
| Custom readiness handler (`core/_base.py:1208`) | No: the prompt fixes the allowed resources; can be added later |
| `/invocations/docs/asyncapi.json` and `.yaml` (`inv/_invocation.py:284-295`) | No: these describe the WebSocket transport, which is out of scope |
| OpenTelemetry baggage entries `azure.ai.agentserver.invocation_id` / `session_id` (`inv/_invocation.py:564-575`) | No: Ballerina observability is configured separately; the IDs are on `FoundryContext` |
| `FOUNDRY_AGENT_SESSION_GUID` / `FOUNDRY_HOSTING_ENVIRONMENT` validation (`core/_config.py:50-55`) | No: not needed for Invocations routing |
| `model_attribution_headers()` / `x-ms-foundry-baggage` (`core/_request_context.py:148-219`) | No: outbound, experimental, out of scope. `originalSubject` is exposed so it can be added later. |
| Shutdown handler hook (`core/_base.py:760`) | No: Ballerina code can use a module-level `listener`'s lifecycle or `runtime:onGracefulStop` |
| Resilient task manager, WebSocket, Responses, snapshot/restore | No: out of scope per the prompt |
| SSE streaming responses with keep-alive comments (`inv/_sse.py`, `SSE_KEEPALIVE_INTERVAL`) | No: dropped from scope. A resource that returns a stream gets a `500` classified as `upstream`, and the compiler plugin rejects stream return types |

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
