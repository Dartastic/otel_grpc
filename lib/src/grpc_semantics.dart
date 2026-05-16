// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

/// gRPC-specific attribute keys that aren't in the upstream API's
/// `RPC` enum yet.
///
/// Use the API's [RPC] enum for `rpc.system` / `rpc.service` /
/// `rpc.method` (those exist already). This enum covers the gRPC
/// sub-spec keys per the OTel RPC semconv:
/// https://opentelemetry.io/docs/specs/semconv/rpc/grpc/
enum GrpcSemantics implements OTelSemantic {
  /// The numeric gRPC status code on the response. `0` is OK; any
  /// other value is an error per gRPC's status taxonomy.
  grpcStatusCode('rpc.grpc.status_code');

  const GrpcSemantics(this.key);

  @override
  final String key;

  @override
  String toString() => key;
}
