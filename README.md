# otel_grpc

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
