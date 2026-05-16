// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:grpc/grpc.dart';

import 'grpc_semantics.dart';
import 'grpc_suppression.dart';

/// OpenTelemetry instrumentation for `package:grpc` outbound calls.
///
/// Attach to a `ClientChannel` via its `interceptors` parameter; the
/// interceptor wraps every unary and streaming call in a `CLIENT`-kind
/// span, sets the OTel `rpc.*` semantic-convention attributes, and
/// injects W3C `traceparent` / `tracestate` / `baggage` into the
/// gRPC call metadata so the receiving service joins the same trace.
///
/// ```dart
/// final channel = ClientChannel(
///   'api.example.com',
///   options: ChannelOptions(credentials: ChannelCredentials.secure()),
///   channelShutdownHandler: ...,
///   interceptors: [OTelGrpcClientInterceptor()],
/// );
/// ```
///
/// ## Self-recursion warning
///
/// gRPC export over OTLP travels through `ClientChannel` instances of
/// its own. The dartastic SDK's built-in OTLP/gRPC exporter creates
/// a private channel, so it does **not** pick up this interceptor —
/// you're safe by default. **If you wire OTLP/gRPC export over a
/// `ClientChannel` you control,** make sure either:
///
/// 1. That channel has **no** `OTelGrpcClientInterceptor` attached, OR
/// 2. Each export call is wrapped in
///    `runWithoutGrpcInstrumentationAsync(() async => ...)` so the
///    interceptor's suppression check fires.
///
/// Otherwise: every span you export creates another span when our
/// interceptor sees its gRPC call, which then needs to be exported —
/// classic instrumentation recursion.
///
/// ## Span shape
///
/// Per the OTel
/// [RPC semantic conventions](https://opentelemetry.io/docs/specs/semconv/rpc/rpc-spans/)
/// and [gRPC sub-spec](https://opentelemetry.io/docs/specs/semconv/rpc/grpc/).
///
/// | Attribute | Source |
/// |---|---|
/// | `rpc.system` | constant `grpc` |
/// | `rpc.service` | service portion of `ClientMethod.path` |
/// | `rpc.method` | method portion of `ClientMethod.path` |
/// | `rpc.grpc.status_code` | numeric code from the response trailers |
///
/// - **Span name**: `<service>/<method>` (the gRPC fully-qualified
///   path minus the leading slash), per the spec.
/// - **Span kind**: `CLIENT`.
/// - **Span status**: `Error` for any non-OK gRPC status, otherwise unset.
final class OTelGrpcClientInterceptor extends ClientInterceptor {
  /// Creates an interceptor.
  ///
  /// - [tracer] — the tracer to use. Defaults to
  ///   `OTel.tracerProvider().getTracer('otel_grpc')`.
  OTelGrpcClientInterceptor({Tracer? tracer})
      : _tracer =
            tracer ?? OTel.tracerProvider().getTracer('otel_grpc'),
        _traceContextPropagator = W3CTraceContextPropagator(),
        _baggagePropagator = W3CBaggagePropagator();

  final Tracer _tracer;
  final W3CTraceContextPropagator _traceContextPropagator;
  final W3CBaggagePropagator _baggagePropagator;

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    if (grpcInstrumentationSuppressed()) {
      return invoker(method, request, options);
    }

    final span = _startSpan(method);
    final injectedOptions = _injectContext(options, span);

    final response = invoker(method, request, injectedOptions);
    // ResponseFuture<R> is itself a Future that completes when the
    // call does (success or error), so we can hang completion off it
    // directly.
    response.then(
      (_) {
        _setOk(span);
        span.end();
      },
      onError: (Object e, StackTrace st) {
        _setError(span, e, st);
        span.end();
      },
    );
    return response;
  }

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) {
    if (grpcInstrumentationSuppressed()) {
      return invoker(method, requests, options);
    }

    final span = _startSpan(method);
    final injectedOptions = _injectContext(options, span);

    final response = invoker(method, requests, injectedOptions);
    // For streaming, `trailers` completes after the stream is closed
    // (success) or completes with an error if the call failed.
    response.trailers.then(
      (_) {
        _setOk(span);
        span.end();
      },
      onError: (Object e, StackTrace st) {
        _setError(span, e, st);
        span.end();
      },
    );
    return response;
  }

  APISpan _startSpan(ClientMethod<dynamic, dynamic> method) {
    final (service, methodName) = _splitPath(method.path);
    final attrs = <String, Object>{
      RPC.rpcSystem.key: 'grpc',
      if (service != null) RPC.rpcService.key: service,
      RPC.rpcMethod.key: methodName,
    };
    final spanName = service != null ? '$service/$methodName' : methodName;
    return _tracer.startSpan(
      spanName,
      kind: SpanKind.client,
      attributes: OTel.attributesFromMap(attrs),
    );
  }

  CallOptions _injectContext(CallOptions options, APISpan span) {
    final headers = <String, String>{};
    final ctx = Context.current.withSpan(span);
    _traceContextPropagator.inject(ctx, headers, _MapSetter(headers));
    _baggagePropagator.inject(ctx, headers, _MapSetter(headers));
    return options.mergedWith(CallOptions(metadata: headers));
  }

  void _setOk(APISpan span) {
    span.addAttributes(OTel.attributes([
      OTel.attributeInt(GrpcSemantics.grpcStatusCode.key, 0),
    ]));
  }

  void _setError(APISpan span, Object error, StackTrace stackTrace) {
    int? code;
    String? message;
    if (error is GrpcError) {
      code = error.code;
      message = error.message;
    }

    final attrs = <Attribute<Object>>[
      if (code != null)
        OTel.attributeInt(GrpcSemantics.grpcStatusCode.key, code),
      OTel.attributeString(
        ErrorResource.errorType.key,
        error.runtimeType.toString(),
      ),
    ];
    span.addAttributes(OTel.attributes(attrs));

    // Spec order: recordException first, THEN setStatus.
    span.recordException(error, stackTrace: stackTrace);
    span.setStatus(
      SpanStatusCode.Error,
      message ?? error.toString(),
    );
  }

  /// Splits a gRPC fully-qualified path `/foo.Bar/Baz` into
  /// `(foo.Bar, Baz)`. Returns `(null, path)` if the path doesn't
  /// have the expected shape.
  static (String?, String) _splitPath(String path) {
    final trimmed = path.startsWith('/') ? path.substring(1) : path;
    final slash = trimmed.indexOf('/');
    if (slash < 0) return (null, trimmed);
    return (trimmed.substring(0, slash), trimmed.substring(slash + 1));
  }
}

class _MapSetter implements TextMapSetter<String> {
  _MapSetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  void set(String key, String value) {
    _carrier[key] = value;
  }
}
