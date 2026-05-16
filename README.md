# otel_grpc

OpenTelemetry instrumentation for [`package:grpc`](https://pub.dev/packages/grpc),
built on the [Dartastic OpenTelemetry SDK](https://pub.dev/packages/dartastic_opentelemetry).

Two interceptors:

- **`OTelGrpcClientInterceptor`** — attach to a `ClientChannel` to get
  a `CLIENT`-kind span per outbound RPC, with W3C trace context
  injected into the call metadata.
- **`OTelGrpcServerInterceptor`** — pass `.intercept` into a `Server`'s
  `interceptors:` list to get a `SERVER`-kind span per inbound RPC,
  with W3C trace context extracted from the metadata so the span
  joins the caller's trace.

```dart
final channel = ClientChannel(
  'api.example.com',
  options: ChannelOptions(credentials: ChannelCredentials.secure()),
  interceptors: [OTelGrpcClientInterceptor()],
);

final server = Server.create(
  services: [MyService()],
  interceptors: [OTelGrpcServerInterceptor().intercept],
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
| `rpc.system` | constant `grpc` | client + server |
| `rpc.service` | service portion of `ClientMethod.path` | client only (server's `ServiceMethod` doesn't carry the parent `Service`) |
| `rpc.method` | method portion of the path / `ServiceMethod.name` | client + server |
| `rpc.grpc.status_code` | numeric gRPC status (0 = OK) | both, on completion |
| `error.type` | exception's runtime class | client + server, on error |

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
- The server interceptor uses the typedef form of `Interceptor`
  (the function), not the abstract `ServerInterceptor` class with
  `intercept<Q,R>`. The typedef only hooks the *start* of the
  call. The span is ended on the next microtask after the
  interceptor fires; that's accurate enough for unary calls, but
  long-lived streaming calls will see their span end before the
  stream actually completes. A future revision can swap to the
  `ServerInterceptor` class for full lifecycle wrapping.
- Streaming client calls hang completion off `ResponseStream.trailers`,
  which fires after the stream is closed (success) or errors
  (failure) — that's the correct end-of-call signal per
  `package:grpc`'s contract.

## License

Apache 2.0 — see `LICENSE`.
