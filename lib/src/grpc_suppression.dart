// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'dart:async';

/// Zone key used to mark a region of code as "do not instrument with
/// the gRPC interceptors." The key is a `Symbol` so it has no
/// runtime collision risk and never crosses isolate boundaries.
///
/// Kept package-private to discourage hand-rolled wiring — callers
/// should use [runWithoutGrpcInstrumentation] /
/// [runWithoutGrpcInstrumentationAsync] instead.
const Symbol _suppressKey = #otel_grpc_suppress;

/// Returns `true` when the current zone has explicitly opted out of
/// gRPC OTel instrumentation.
///
/// Public so an [OTelGrpcClientInterceptor] / [OTelGrpcServerInterceptor]
/// (and tests) can consult it cheaply.
bool grpcInstrumentationSuppressed() {
  return Zone.current[_suppressKey] == true;
}

/// Runs [body] in a zone where the gRPC interceptors will skip span
/// creation entirely.
///
/// The intended use case is the self-recursion hazard: if you call
/// `OTLP/gRPC` export over a `ClientChannel` that also has our
/// `OTelGrpcClientInterceptor` attached, exporting a span makes a
/// gRPC call that creates another span that gets exported… ad
/// infinitum. Wrap that export call in this helper to break the
/// cycle.
///
/// ```dart
/// runWithoutGrpcInstrumentationAsync(() async {
///   await otlpClient.export(spans);
/// });
/// ```
///
/// The flag propagates through `Future` chains and `await` points
/// via the surrounding [Zone], so async work started inside [body]
/// is also covered.
T runWithoutGrpcInstrumentation<T>(T Function() body) {
  return runZoned(body, zoneValues: {_suppressKey: true});
}

/// Async variant of [runWithoutGrpcInstrumentation]. Both forms are
/// safe to nest; they no-op once already inside a suppressed zone.
Future<T> runWithoutGrpcInstrumentationAsync<T>(
  Future<T> Function() body,
) {
  return runZoned(body, zoneValues: {_suppressKey: true});
}
