// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

/// OpenTelemetry instrumentation for `package:grpc`.
///
/// See [OTelGrpcClientInterceptor] for outbound calls and
/// [OTelGrpcServerInterceptor] for inbound calls.
library;

export 'src/grpc_semantics.dart';
export 'src/grpc_suppression.dart';
export 'src/otel_grpc_client_interceptor.dart';
export 'src/otel_grpc_server_interceptor.dart';
