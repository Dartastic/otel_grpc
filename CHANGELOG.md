# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-beta.1-wip]

### Added

- `OTelGrpcClientInterceptor` — `ClientInterceptor` subclass that
  wraps every unary and streaming RPC in a `CLIENT`-kind span,
  injects W3C trace context into the call metadata, and maps gRPC
  status codes to OTel span status. Sets the RPC semconv attributes
  (`rpc.system=grpc`, `rpc.service`, `rpc.method`,
  `rpc.grpc.status_code`).
- `OTelGrpcServerInterceptor` — a holder class whose `intercept`
  tear-off slots into `Server.create(interceptors: ...)`. Extracts
  W3C trace context from `ServiceCall.clientMetadata` so server
  spans parent into the calling trace.
- `GrpcSemantics` — local enum implementing `OTelSemantic` for the
  `rpc.grpc.*` keys that aren't in the upstream API's `RPC` enum
  yet (the package uses the existing `RPC.rpcSystem` / `rpcService`
  / `rpcMethod` and only ships its own `grpcStatusCode`).
- `runWithoutGrpcInstrumentation` /
  `runWithoutGrpcInstrumentationAsync` — zone-scoped suppression
  helpers. The interceptors check a zone flag and skip span
  creation entirely, breaking the recursion hazard when an OTLP/gRPC
  export call would otherwise pass back through the interceptor.
- 5 unit tests run against a real in-process gRPC `Server`
  bound to an ephemeral port: happy-path unary call,
  traceparent injection, GrpcError → Error status, suppression
  helper, parent-span inheritance.

### Known limitations

- Server-side: `rpc.service` is not set because `package:grpc`'s
  `ServiceMethod` doesn't carry a back-reference to its parent
  `Service`. Client side does set it (from `ClientMethod.path`).
- Server interceptor uses the typedef-form interceptor hook, which
  only fires before the call. The span is ended on the next
  microtask, so long-running streaming calls finish their span
  before the stream completes. A future revision can switch to
  the `ServerInterceptor` abstract class for full lifecycle.
