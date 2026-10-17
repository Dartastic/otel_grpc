<!-- dartastic-header:start -->
# OpenTelemetry instrumentation for `grpc`

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OpenTelemetry Specification](https://img.shields.io/badge/OpenTelemetry-Specification-blueviolet)](https://opentelemetry.io/docs/specs/otel/)

`otel_grpc` is an [OpenTelemetry](https://opentelemetry.io/) instrumentation for `grpc` that
easily adds standard observability to applications that use `grpc`.  This package depends on 
[dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api).

This package can be used with any OTel backend because it's compliant with the OpenTelemetry Specification.

This package supports Android, iOS, Linux, macOS and Windows, for versions of `grpc` that support those platforms.

This Apache-2.0 package is professionally maintained and supported with 💙 by Michael Bushe,
Dart and Flutter Maintainer at OpenTelemetry and the creator of [dartastic_opentelemetry](https://pub.dev/packages/dartastic_opentelemetry)
and [dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api). This package is professionally supported by
[Dartastic.io](https://dartastic.io).

---
## Dartastic.io: AI Code Healing and Real User Monitoring for Flutter

**See what your users experience. Find problems with Flutter apps in production. Fix them with AI.**

[Dartastic.io](https://dartastic.io) brings AI code healing, real user monitoring, and OpenTelemetry observability together in one platform built for Dart and Flutter. (Patents pending)

![Dartastic AI answering "Why did crashes jump after the last release?" over a Flutter App Health dashboard](https://dartastic.io/img/pub-dev/HomePageCrashesQuestion.png)

### Dartastic AI — From Production Problems to Code Fixes

Dartastic AI analyzes production telemetry alongside your application source code to diagnose problems and propose fixes.

- **Investigate production issues** using crashes, errors, traces, metrics, and real user telemetry.
- **Find the offending code** by connecting observed problems with your application's source in Dartastic Pub or your source code repos.
- **Generate code patches** that address the underlying problems.
- **Create actionable issues** in your issue tracker, complete with findings and the proposed code patch.

### Dartastic RUM — See What Your Users See

Understand how people actually experience your Flutter application.

- **Replay user sessions** in the Dartastic Observatory session player.
- **Choose your replay fidelity**, from privacy-preserving widget outlines to pixel-level reproductions of the user experience.
- **Investigate real user problems** using session replay and production observability data.

![Dartastic RUM Session Replay](https://dartastic.io/img/pub-dev/session-replay.png)

### Dartastic Observatory — Observability Built for Flutter

A complete observability backend where Flutter and Dart are first-class citizens.

- **Flutter-specific dashboards** for application performance, health, and reliability.
- **Alerts and notifications** through email, Slack, and PagerDuty.
- **Dartastic Cloud Observatory** — Start with a 30-day free trial on isolated, shared infrastructure, as low as $39/mo.
- **Dartastic Hosted Observatory** — Run the observability stack in a private managed environment, sized from Mini to Enterprise XL.
- **Dartastic Self-Hosted Observatory** — The whole platform inside your own network. Your keys, your cluster, with nothing leaving your perimeter.

### Dartastic Native OTel Runtime — Native OpenTelemetry Performance

Collect production telemetry without burdening Flutter's main isolate.

- **Native OpenTelemetry runtime** that moves telemetry processing off the main isolate.
- **Native crash reporting** for problems that Dart can't catch.
- **Widget performance diagnostics** to identify janky widgets.
- **On-device PII filtering** before sensitive data leaves your application.
- **Source-level error diagnostics** powered by the Dartastic Symbolizer API.
- **Platform-native metrics** for iOS, Android, and Linux, including iOS MetricKit and Android Vitals.
- **OpenTelemetry compatibility** — Send telemetry to Dartastic Observatory or any OpenTelemetry platform.

### Dartastic Labs — OpenTelemetry Integrations

Instrument more of your application without writing everything yourself.

- **650+ open-source integrations** for Dart and Flutter libraries and services, including Dio, Shelf, Logger, Anthropic, AWS, Azure, and Stripe. Look for otel_* on pub.dev.

### More Dartastic Tools

**[Dartastic Pub](https://dartastic.io/pub)**

A private Dart package registry for sharing packages and plugins with your team, partners, and customers.

**[Dartastic Symbolizer](https://dartastic.io/symbolizer)**

Turn production errors into lines of source code through a web API, while keeping your source code artifacts private.

### Professional Support and Training

Dartastic.io offers commercial support for the open-source `dartastic_opentelemetry` and `dartastic_opentelemetry_api` packages and the complete Dartastic product suite.

- **Professional support** with available around-the-clock coverage and response times under four hours on qualifying plans.
- **OpenTelemetry training** for teams instrumenting Dart, Flutter, mobile, and web applications.

### Open Standards. No Mandatory Backend.

The Dartastic OpenTelemetry API and SDK are open source and standards-based. You can use them independently of Dartastic's commercial services and send telemetry to any compatible OpenTelemetry backend.

Dartastic's commercial products add native performance, advanced diagnostics, session replay, AI-assisted remediation, and managed observability services.

**[Explore Dartastic.io](https://dartastic.io)**

---
<!-- dartastic-header:end -->

OpenTelemetry instrumentation for [`package:grpc`](https://pub.dev/packages/grpc),
built on the [Dartastic OpenTelemetry SDK](https://pub.dev/packages/dartastic_opentelemetry).

Two interceptors:

- **`OTelGrpcClientInterceptor`** — attach to a `ClientChannel` to get
  a `CLIENT`-kind span per outbound RPC, with W3C trace context
  injected into the call metadata.
- **`OTelGrpcServerInterceptor`** — add to a `Server`'s
  `serverInterceptors:` list to get a `SERVER`-kind span per inbound
  RPC, with W3C trace context extracted from the metadata so the span
  joins the caller's trace. The span wraps the whole handler
  invocation, so durations and status codes are real.

```dart
final channel = ClientChannel(
  'api.example.com',
  options: ChannelOptions(credentials: ChannelCredentials.secure()),
  interceptors: [
    OTelGrpcClientInterceptor(
      // Optional: interceptors can't see the channel, so pass the
      // host/port you gave the channel to get server.address/port
      // on the spans.
      serverAddress: 'api.example.com',
    ),
  ],
);

final server = Server.create(
  services: [MyService()],
  serverInterceptors: [OTelGrpcServerInterceptor()],
);
```

## ⚠️ Self-recursion: don't instrument your OTLP/gRPC export channel

gRPC export over OTLP is itself gRPC. If you put
`OTelGrpcClientInterceptor` on a `ClientChannel` that's also used
by your OTLP/gRPC exporter, every span you export creates another
span (the export call), which gets exported, which creates another
span — instrumentation recursion until you blow the stack or
saturate your backend.

**You're safe by default** — the dartastic SDK's built-in
OTLP/gRPC exporter creates its own private `ClientChannel` that
your interceptor isn't attached to. The risk only appears if you
manually wire OTLP export over a `ClientChannel` you control. If
that's your setup, do one of:

1. **Don't attach the interceptor to that channel.** Use a
   separate, dedicated channel for OTLP traffic.
2. **Wrap export calls in the suppression helper:**
   ```dart
   import 'package:otel_grpc/otel_grpc.dart';

   await runWithoutGrpcInstrumentationAsync(() async {
     await myOtlpClient.export(spans);
   });
   ```
   The interceptor checks a zone-scoped flag and bails before
   creating the span. Sync variant: `runWithoutGrpcInstrumentation`.

## Span shape

Per the OTel [RPC semantic conventions](https://opentelemetry.io/docs/specs/semconv/rpc/rpc-spans/)
and [gRPC sub-spec](https://opentelemetry.io/docs/specs/semconv/rpc/grpc/).

| Attribute | Source | Set on |
|---|---|---|
| `rpc.system.name` | constant `grpc` | client + server |
| `rpc.method` | fully-qualified `<service>/<method>` on the client; `ServiceMethod.name` on the server (`ServiceMethod` doesn't carry the parent `Service`) | client + server |
| `rpc.response.status_code` | canonical status name (`OK`, `NOT_FOUND`, `DEADLINE_EXCEEDED`, ...) | both, on completion |
| `server.address` / `server.port` | constructor parameters (interceptors can't see the channel) | client, when provided |
| `error.type` | exception's runtime class | client + server, on error |

The registry-deprecated keys are not emitted: `rpc.system` became
`rpc.system.name`, `rpc.service` folds into the fully-qualified
`rpc.method`, and the numeric `rpc.grpc.status_code` became the string
form on `rpc.response.status_code`.

- **Span name**: `<service>/<method>` on the client (e.g.
  `com.example.UserService/GetUser`); `<method>` on the server.
- **Span kind**: `CLIENT` for outbound, `SERVER` for inbound.
- **Span status**: `Error` for any non-OK gRPC status or thrown
  exception; otherwise unset.

## W3C trace context propagation

- Outbound: `traceparent` / `tracestate` / `baggage` are added to
  `CallOptions.metadata` so the receiving service joins the same
  trace.
- Inbound: those same headers are extracted from
  `ServiceCall.clientMetadata` and used to parent the server span.

If the receiving service also runs this package's server
interceptor (or any OTel-aware gRPC server), spans on both sides
join into a single distributed trace automatically.

## Caveats

- Both interceptors call `OTel.tracerProvider().getTracer(...)` in
  their constructors — `OTel.initialize()` must have run first.
- The server interceptor is the class-based `ServerInterceptor`
  (`package:grpc` >= 4.1.0), which wraps the whole invocation — the
  span ends when the response stream completes or errors, so
  streaming-call durations are real. It goes in `serverInterceptors:`,
  not the legacy function-typedef `interceptors:` list.
- Streaming client calls hang completion off `ResponseStream.trailers`,
  which fires after the stream is closed (success) or errors
  (failure) — that's the correct end-of-call signal per
  `package:grpc`'s contract.

## License

Apache 2.0 — see `LICENSE`.
