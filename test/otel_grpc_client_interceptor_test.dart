// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:otel_grpc/otel_grpc.dart';
import 'package:test/test.dart';

class _MemorySpanExporter implements SpanExporter {
  final List<Span> spans = [];
  bool _shutdown = false;

  @override
  Future<void> export(List<Span> s) async {
    if (_shutdown) return;
    spans.addAll(s);
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _shutdown = true;
  }
}

Map<String, Object> _attrs(Span span) =>
    {for (final a in span.attributes.toList()) a.key: a.value};

// --- Tiny in-process service ---
//
// We avoid protoc-generated code by building a `ClientMethod` and a
// `Service` by hand. The wire payload is a single int encoded as one
// byte (we never send anything `> 255`).

const _serviceName = 'test.EchoService';
const _methodName = 'Say';
const _methodPath = '/$_serviceName/$_methodName';

List<int> _intSerializer(int v) => [v];
int _intDeserializer(List<int> b) => b.first;

final _clientMethod = grpc.ClientMethod<int, int>(
  _methodPath,
  _intSerializer,
  _intDeserializer,
);

class _EchoService extends grpc.Service {
  _EchoService(this._handler) {
    $addMethod(
      grpc.ServiceMethod<int, int>(
        _methodName,
        _onSay,
        false,
        false,
        _intDeserializer,
        _intSerializer,
      ),
    );
  }
  final int Function(grpc.ServiceCall call, int req) _handler;

  /// Stash the headers the server saw on the most recent call so
  /// tests can assert traceparent propagation.
  Map<String, String> lastClientMetadata = const {};

  @override
  String get $name => _serviceName;

  Future<int> _onSay(grpc.ServiceCall call, Future<int> req) async {
    lastClientMetadata = Map<String, String>.from(
      call.clientMetadata ?? const {},
    );
    return _handler(call, await req);
  }
}

grpc.ResponseFuture<int> _invokeOnChannel(
  grpc.ClientChannel channel,
  grpc.ClientMethod<int, int> method,
  int req,
  grpc.CallOptions options,
) {
  return grpc.ResponseFuture<int>(
    channel.createCall<int, int>(method, Stream.value(req), options),
  );
}

void main() {
  group('OTelGrpcClientInterceptor (end-to-end via in-process gRPC)', () {
    late _MemorySpanExporter exporter;
    late OTelGrpcClientInterceptor clientInterceptor;
    late grpc.Server server;
    late grpc.ClientChannel channel;
    late _EchoService service;
    late int Function(grpc.ServiceCall, int) handler;

    setUp(() async {
      await OTel.reset();
      exporter = _MemorySpanExporter();
      await OTel.initialize(
        serviceName: 'grpc-otel-test',
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(exporter),
      );
      clientInterceptor = OTelGrpcClientInterceptor();
      handler = (call, req) => req + 1;
      service = _EchoService((call, req) => handler(call, req));

      server = grpc.Server.create(services: [service]);
      await server.serve(port: 0);
      final port = server.port!;

      channel = grpc.ClientChannel(
        'localhost',
        port: port,
        options: const grpc.ChannelOptions(
          credentials: grpc.ChannelCredentials.insecure(),
        ),
      );
    });

    tearDown(() async {
      await channel.shutdown();
      await server.shutdown();
      await OTel.shutdown();
      await OTel.reset();
    });

    test('unary call emits a CLIENT span with full rpc.* attribute set',
        () async {
      final result = await clientInterceptor.interceptUnary<int, int>(
        _clientMethod,
        7,
        grpc.CallOptions(),
        (m, req, opts) => _invokeOnChannel(channel, m, req, opts),
      );

      expect(result, equals(8));
      await Future<void>.delayed(Duration.zero);

      final span = exporter.spans.firstWhere(
        (s) => s.name == '$_serviceName/$_methodName',
      );
      expect(span.kind, equals(SpanKind.client));
      final attrs = _attrs(span);
      expect(attrs['rpc.system'], equals('grpc'));
      expect(attrs['rpc.service'], equals(_serviceName));
      expect(attrs['rpc.method'], equals(_methodName));
      expect(attrs['rpc.grpc.status_code'], equals(0));
      expect(span.status, isNot(equals(SpanStatusCode.Error)));
    });

    test('injects traceparent into outbound call metadata', () async {
      await clientInterceptor.interceptUnary<int, int>(
        _clientMethod,
        7,
        grpc.CallOptions(),
        (m, req, opts) => _invokeOnChannel(channel, m, req, opts),
      );

      expect(service.lastClientMetadata['traceparent'], isNotNull);
      final tp = service.lastClientMetadata['traceparent']!;
      expect(tp.length, equals(55));
      expect(tp.startsWith('00-'), isTrue);
    });

    test('GrpcError on the server flips span status to Error', () async {
      handler = (call, req) => throw const grpc.GrpcError.notFound('nope');

      final response = clientInterceptor.interceptUnary<int, int>(
        _clientMethod,
        7,
        grpc.CallOptions(),
        (m, req, opts) => _invokeOnChannel(channel, m, req, opts),
      );

      await expectLater(response, throwsA(isA<grpc.GrpcError>()));
      await Future<void>.delayed(Duration.zero);

      final span = exporter.spans.firstWhere(
        (s) => s.name == '$_serviceName/$_methodName',
      );
      expect(span.status, equals(SpanStatusCode.Error));
      final attrs = _attrs(span);
      expect(attrs['rpc.grpc.status_code'], equals(5));
      expect(attrs['error.type'], equals('GrpcError'));
      final events = span.spanEvents ?? [];
      expect(events.any((e) => e.name == 'exception'), isTrue);
    });

    test('runWithoutGrpcInstrumentationAsync skips span creation', () async {
      await runWithoutGrpcInstrumentationAsync(() async {
        await clientInterceptor.interceptUnary<int, int>(
          _clientMethod,
          7,
          grpc.CallOptions(),
          (m, req, opts) => _invokeOnChannel(channel, m, req, opts),
        );
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        exporter.spans.where((s) => s.name.startsWith('$_serviceName/')),
        isEmpty,
        reason: 'suppression scope should bypass the interceptor entirely',
      );
      expect(service.lastClientMetadata['traceparent'], isNull);
    });

    test('span inherits parent when called inside startActiveSpan', () async {
      await OTel.tracer().startActiveSpanAsync<void>(
        name: 'parent',
        fn: (_) async {
          await clientInterceptor.interceptUnary<int, int>(
            _clientMethod,
            7,
            grpc.CallOptions(),
            (m, req, opts) => _invokeOnChannel(channel, m, req, opts),
          );
        },
      );
      await Future<void>.delayed(Duration.zero);

      final parent = exporter.spans.firstWhere((s) => s.name == 'parent');
      final child = exporter.spans.firstWhere(
        (s) => s.name == '$_serviceName/$_methodName',
      );
      expect(
        child.parentSpanContext?.spanId,
        equals(parent.spanContext.spanId),
      );
    });
  });
}
