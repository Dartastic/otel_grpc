# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1-wip]

## [0.3.0] - 2026-10-11

### Changed

- Requires `dartastic_opentelemetry_api >=1.0.0-rc.4 <1.0.0-rc.5`.
- Context is propagated with the app's configured propagators
  (`OTelAPI.textMapPropagator`: W3C trace context and baggage by
  default, `OTEL_PROPAGATORS` to change them) instead of a fixed W3C
  propagator.
- **Breaking:** depends on `dartastic_opentelemetry_api` only, no
  longer on the SDK. The application chooses and initializes the
  OpenTelemetry SDK. Parameters and fields typed with SDK classes
  now use the API types (`APITracer`, `APISpan`, `APILogger`, ...);
  SDK instances are still accepted wherever an API type is expected.

## [0.2.0] - 2026-08-10

### Added

- `OTelGrpcClientInterceptor` — `ClientInterceptor` subclass that
  wraps every unary and streaming RPC in a `CLIENT`-kind span,
  injects W3C trace context into the call metadata, and maps gRPC
  status codes to OTel span status. Sets the registry-current RPC
  semconv attributes: `rpc.system.name=grpc`, fully-qualified
  `rpc.method`, `rpc.response.status_code` (canonical status name,
  e.g. `OK` / `NOT_FOUND`). Optional `serverAddress` / `serverPort`
  constructor parameters emit `server.address` / `server.port`
  (interceptors can't see the `ClientChannel`, so the values are
  caller-supplied — never fabricated).
- `OTelGrpcServerInterceptor` — class-based `ServerInterceptor`
  (grpc >= 4.1.0) for `Server.create(serverInterceptors: ...)`. The
  span wraps the whole handler invocation and ends when the response
  stream completes or errors, so durations and status codes are real
  (an earlier draft used the function-typedef hook, which fires
  before the call and cannot observe completion). Extracts W3C trace
  context from `ServiceCall.clientMetadata` so server spans parent
  into the calling trace.
- `grpcStatusCodeName` — canonical gRPC status names for the
  `rpc.response.status_code` values; unknown codes emit the numeric
  code as a string.
- `runWithoutGrpcInstrumentation` /
  `runWithoutGrpcInstrumentationAsync` — zone-scoped suppression
  helpers. The interceptors check a zone flag and skip span
  creation entirely, breaking the recursion hazard when an OTLP/gRPC
  export call would otherwise pass back through the interceptor.
- 8 unit tests against a real in-process gRPC `Server` on an
  ephemeral port: client happy path, traceparent injection,
  GrpcError → Error status, suppression, parent-span inheritance;
  server real-duration span, GrpcError mapping, W3C extraction.

### Changed

- Semantic conventions updated to the current OTel registry:
  registry-deprecated keys are no longer emitted — `rpc.system` →
  `rpc.system.name`, `rpc.service` → folded into a fully-qualified
  `rpc.method`, and the numeric `rpc.grpc.status_code` → the string
  `rpc.response.status_code`. The local `GrpcSemantics` enum is gone
  with them.
- Dependency floors raised to `dartastic_opentelemetry ^1.1.0-beta.12`
  and `dartastic_opentelemetry_api ^1.0.0-rc.1`. The previous floors
  declared compatibility with API versions that predate the semconv
  enums this package uses and could not actually resolve-and-compile.
- `repository` URL corrected to the canonical `Dartastic` org casing so
  pub.dev repository verification succeeds.

### Known limitations

- Server-side `rpc.method` is unqualified: `package:grpc`'s
  `ServiceMethod` doesn't carry a back-reference to its parent
  `Service`. The client emits the fully-qualified form.
