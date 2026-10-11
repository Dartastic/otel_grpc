// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:grpc/grpc.dart' as grpc;

import 'grpc_status.dart';
import 'grpc_suppression.dart';

/// OpenTelemetry instrumentation for `package:grpc` inbound calls.
///
/// Attach to a `Server` via its `serverInterceptors` parameter; the
/// interceptor wraps every service-method invocation in a
/// `SERVER`-kind span, extracts W3C trace context from the incoming
/// gRPC metadata so the span joins the caller's trace, and sets the
/// OTel `rpc.*` semantic-convention attributes.
///
/// ```dart
/// final server = Server.create(
///   services: [MyService()],
///   serverInterceptors: [OTelGrpcServerInterceptor()],
/// );
/// ```
///
/// This is `package:grpc`'s class-based `ServerInterceptor`
/// (available since grpc 4.1.0), which wraps the whole invocation as
/// middleware — the span covers the real handler execution and ends
/// when the response stream completes or errors, so durations and
/// status codes are real. (The older function-typedef `interceptors:`
/// hook only fires *before* the handler and cannot observe
/// completion.)
///
/// ## Span shape
///
/// | Attribute | Source |
/// |---|---|
/// | `rpc.system.name` | constant `grpc` |
/// | `rpc.method` | `ServiceMethod.name` |
/// | `rpc.response.status_code` | `OK` on success; the canonical status name (e.g. `NOT_FOUND`) on a `GrpcError` |
/// | `error.type` | runtime class of the thrown error | on error |
///
/// `rpc.method` is unqualified here: `package:grpc`'s `ServiceMethod`
/// carries no back-reference to its parent `Service`, so the service name
/// isn't available server-side. The client interceptor emits the fully
/// qualified form. (`rpc.system` and `rpc.service` are deprecated in the
/// OTel registry and are not emitted; the numeric `rpc.grpc.status_code`
/// is likewise deprecated in favor of the string
/// `rpc.response.status_code`.)
///
/// - **Span name**: `ServiceMethod.name`.
/// - **Span kind**: `SERVER`.
/// - **Span status**: `Error` if the call throws (including
///   `GrpcError`); otherwise the SDK default.
final class OTelGrpcServerInterceptor extends grpc.ServerInterceptor {
  /// Creates an interceptor.
  ///
  /// - [tracer] — the tracer to use. Defaults to
  ///   `OTel.tracerProvider().getTracer('otel_grpc')`.
  OTelGrpcServerInterceptor({APITracer? tracer})
      : _tracer = tracer ?? OTelAPI.tracerProvider().getTracer('otel_grpc');

  final APITracer _tracer;

  @override
  Stream<R> intercept<Q, R>(
    grpc.ServiceCall call,
    grpc.ServiceMethod<Q, R> method,
    Stream<Q> requests,
    grpc.ServerStreamingInvoker<Q, R> invoker,
  ) {
    if (grpcInstrumentationSuppressed()) {
      return invoker(call, method, requests);
    }

    final span = _tracer.startSpan(
      method.name,
      kind: SpanKind.server,
      context: _extractContext(call),
      attributes: OTelAPI.attributesFromMap(<String, Object>{
        // `rpc.system` is deprecated in favour of `rpc.system.name`.
        Rpc.rpcSystemName.key: 'grpc',
        Rpc.rpcMethod.key: method.name,
      }),
    );

    var ended = false;
    void endOnce(void Function() finish) {
      if (ended) return;
      ended = true;
      finish();
      span.end();
    }

    Stream<R> responses;
    try {
      responses = invoker(call, method, requests);
    } catch (error, stackTrace) {
      endOnce(() => _setError(span, error, stackTrace));
      rethrow;
    }

    return responses.transform(
      StreamTransformer<R, R>.fromHandlers(
        handleError: (Object error, StackTrace stackTrace, EventSink<R> sink) {
          endOnce(() => _setError(span, error, stackTrace));
          sink.addError(error, stackTrace);
        },
        handleDone: (EventSink<R> sink) {
          endOnce(() => _setOk(span));
          sink.close();
        },
      ),
    );
  }

  Context _extractContext(grpc.ServiceCall call) {
    final headers = call.clientMetadata ?? const <String, String>{};
    final getter = _MapGetter(headers);
    // The app's configured propagators (W3C trace context + baggage by
    // default; OTEL_PROPAGATORS overrides).
    return OTelAPI.textMapPropagator.extract(Context.current, headers, getter);
  }

  void _setOk(APISpan span) {
    span.addAttributes(OTelAPI.attributes([
      OTelAPI.attributeString(
        Rpc.rpcResponseStatusCode.key,
        grpcStatusCodeName(grpc.StatusCode.ok),
      ),
    ]));
  }

  void _setError(APISpan span, Object error, StackTrace stackTrace) {
    final attrs = <Attribute<Object>>[
      if (error is grpc.GrpcError)
        OTelAPI.attributeString(
          Rpc.rpcResponseStatusCode.key,
          grpcStatusCodeName(error.code),
        ),
      OTelAPI.attributeString(
        ErrorAttributes.errorType.key,
        error.runtimeType.toString(),
      ),
    ];
    span.addAttributes(OTelAPI.attributes(attrs));

    // Spec order: recordException first, THEN setStatus.
    span.recordException(error, stackTrace: stackTrace);
    span.setStatus(
      SpanStatusCode.Error,
      error is grpc.GrpcError
          ? (error.message ?? error.toString())
          : error.toString(),
    );
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
