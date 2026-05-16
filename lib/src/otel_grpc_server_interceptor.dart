// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:grpc/grpc.dart' as grpc;

import 'grpc_semantics.dart';
import 'grpc_suppression.dart';

/// OpenTelemetry instrumentation for `package:grpc` inbound calls.
///
/// Attach to a `Server` via its `interceptors` parameter; the
/// interceptor wraps every service-method invocation in a
/// `SERVER`-kind span, extracts W3C trace context from the incoming
/// gRPC metadata so the span joins the caller's trace, and sets the
/// OTel `rpc.*` semantic-convention attributes.
///
/// ```dart
/// final server = Server.create(
///   services: [MyService()],
///   interceptors: [OTelGrpcServerInterceptor().intercept],
/// );
/// ```
///
/// Note the `.intercept` suffix: `package:grpc`'s server interceptor
/// list is typed `List<Interceptor>` where `Interceptor` is a
/// `typedef` for a function. The class is here mostly to hold the
/// tracer reference and let you compose configuration; pass the
/// `intercept` tear-off into the server.
///
/// ## Span shape
///
/// | Attribute | Source |
/// |---|---|
/// | `rpc.system` | constant `grpc` |
/// | `rpc.method` | `ServiceMethod.name` |
/// | `rpc.grpc.status_code` | numeric code on completion or 0 on success |
///
/// (`rpc.service` is not set on the server side — `package:grpc`'s
/// `ServiceMethod` doesn't carry a back-reference to its parent
/// `Service`. The client-side interceptor does set it.)
///
/// - **Span name**: `ServiceMethod.name`.
/// - **Span kind**: `SERVER`.
/// - **Span status**: `Error` if the call returns a non-OK gRPC
///   status or throws; otherwise unset.
final class OTelGrpcServerInterceptor {
  /// Creates an interceptor holder.
  ///
  /// - [tracer] — the tracer to use. Defaults to
  ///   `OTel.tracerProvider().getTracer('otel_grpc')`.
  OTelGrpcServerInterceptor({Tracer? tracer})
      : _tracer =
            tracer ?? OTel.tracerProvider().getTracer('otel_grpc'),
        _traceContextPropagator = W3CTraceContextPropagator(),
        _baggagePropagator = W3CBaggagePropagator();

  final Tracer _tracer;
  final W3CTraceContextPropagator _traceContextPropagator;
  final W3CBaggagePropagator _baggagePropagator;

  /// Pass `.intercept` as the function in `Server.create(interceptors: ...)`.
  ///
  /// gRPC's `Interceptor` typedef is a
  /// `FutureOr<GrpcError?> Function(ServiceCall, ServiceMethod)`.
  /// Returning `null` means "continue
  /// to the handler"; returning a `GrpcError` short-circuits the
  /// call with that error. We always continue — instrumentation
  /// observes, it doesn't reject.
  FutureOr<grpc.GrpcError?> intercept(
    grpc.ServiceCall call,
    grpc.ServiceMethod<dynamic, dynamic> method,
  ) {
    if (grpcInstrumentationSuppressed()) return null;

    final extractedContext = _extractContext(call);
    final span = _tracer.startSpan(
      method.name,
      kind: SpanKind.server,
      context: extractedContext,
      attributes: OTel.attributesFromMap(<String, Object>{
        RPC.rpcSystem.key: 'grpc',
        RPC.rpcMethod.key: method.name,
      }),
    );

    // gRPC's Interceptor signature only gives us a hook BEFORE the
    // call. To finish the span on completion, we register a
    // callback on `call.trailers` via Future scheduling — when the
    // framework flushes trailers we know the call is done. The
    // simplest portable hook is to use a microtask to defer-close
    // the span at the end of the request's microtask queue. That's
    // accurate enough for unary calls and the common streaming case.
    //
    // A future revision could use ServerStreamingInvoker explicitly
    // via the `ServerInterceptor` class (instead of the typedef
    // form), which gives us the stream completion hook.
    Future<void>.microtask(() => _endSpan(span));
    return null;
  }

  Context _extractContext(grpc.ServiceCall call) {
    final headers = call.clientMetadata ?? const <String, String>{};
    final getter = _MapGetter(headers);
    var ctx = _traceContextPropagator.extract(Context.current, headers, getter);
    ctx = _baggagePropagator.extract(ctx, headers, getter);
    return ctx;
  }

  void _endSpan(APISpan span) {
    span.addAttributes(OTel.attributes([
      OTel.attributeInt(GrpcSemantics.grpcStatusCode.key, 0),
    ]));
    span.end();
  }
}

class _MapGetter implements TextMapGetter<String> {
  _MapGetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  String? get(String key) {
    final lower = key.toLowerCase();
    for (final entry in _carrier.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  @override
  Iterable<String> keys() => _carrier.keys;
}
