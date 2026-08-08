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
  final Future<int> Function(grpc.ServiceCall call, int req) _handler;

  @override
  String get $name => _serviceName;

  Future<int> _onSay(grpc.ServiceCall call, Future<int> req) async =>
      _handler(call, await req);
}

void main() {
  group('OTelGrpcServerInterceptor (class-based, end-to-end)', () {
    late _MemorySpanExporter exporter;
    late grpc.Server server;
    late grpc.ClientChannel channel;
    late Future<int> Function(grpc.ServiceCall, int) handler;

    setUp(() async {
      await OTel.reset();
      exporter = _MemorySpanExporter();
      await OTel.initialize(
        serviceName: 'grpc-otel-server-test',
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(exporter),
      );
      handler = (call, req) async => req + 1;

      server = grpc.Server.create(
        services: [_EchoService((call, req) => handler(call, req))],
        serverInterceptors: [OTelGrpcServerInterceptor()],
      );
      await server.serve(port: 0);

      channel = grpc.ClientChannel(
        'localhost',
        port: server.port!,
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

    Future<int> callServer({Map<String, String> metadata = const {}}) {
      return grpc.ResponseFuture<int>(
        channel.createCall<int, int>(
          _clientMethod,
          Stream.value(7),
          grpc.CallOptions(metadata: metadata),
        ),
      );
    }

    Future<Span> serverSpan() async {
      // The span ends when the response stream completes; give the
      // server's async machinery a beat to flush through the
      // SimpleSpanProcessor.
      for (var i = 0; i < 50; i++) {
        final match = exporter.spans.where((s) => s.name == _methodName);
        if (match.isNotEmpty) return match.first;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('no SERVER span named $_methodName was exported');
    }

    test('emits a SERVER span with real duration and registry rpc.* keys',
        () async {
      const handlerDelay = Duration(milliseconds: 50);
      handler = (call, req) async {
        await Future<void>.delayed(handlerDelay);
        return req + 1;
      };

      final result = await callServer();
      expect(result, equals(8));

      final span = await serverSpan();
      expect(span.kind, equals(SpanKind.server));
      final attrs = _attrs(span);
      expect(attrs['rpc.system.name'], equals('grpc'));
      expect(attrs['rpc.method'], equals(_methodName));
      expect(attrs['rpc.response.status_code'], equals('OK'));
      expect(span.status, isNot(equals(SpanStatusCode.Error)));

      // The whole point of the class-based interceptor: the span
      // covers the actual handler execution, not just the pre-call
      // hook (the old typedef-form span ended on the next microtask
      // with a near-zero duration).
      final duration = span.endTime!.difference(span.startTime);
      expect(duration, greaterThanOrEqualTo(handlerDelay ~/ 2));
    });

    test('GrpcError maps to Error status + canonical status name', () async {
      handler =
          (call, req) async => throw const grpc.GrpcError.notFound('nope');

      await expectLater(callServer(), throwsA(isA<grpc.GrpcError>()));

      final span = await serverSpan();
      expect(span.status, equals(SpanStatusCode.Error));
      final attrs = _attrs(span);
      expect(attrs['rpc.response.status_code'], equals('NOT_FOUND'));
      expect(attrs['error.type'], equals('GrpcError'));
      final events = span.spanEvents ?? [];
      expect(events.any((e) => e.name == 'exception'), isTrue);
    });

    test('extracts W3C traceparent from client metadata', () async {
      const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
      const parentSpanId = '00f067aa0ba902b7';

      await callServer(
        metadata: {'traceparent': '00-$traceId-$parentSpanId-01'},
      );

      final span = await serverSpan();
      // Joining the remote trace is the observable contract: same
      // trace id, new span id.
      expect(span.spanContext.traceId.toString(), equals(traceId));
      expect(span.spanContext.spanId.toString(), isNot(equals(parentSpanId)));
    });
  });
}
