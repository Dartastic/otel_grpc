// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

/// Canonical gRPC status-code names, as emitted on the
/// `rpc.response.status_code` attribute.
///
/// The OTel registry deprecated the numeric `rpc.grpc.status_code`
/// attribute in favor of the string representation of the status on
/// `rpc.response.status_code` (registry examples: `OK`,
/// `DEADLINE_EXCEEDED`). These are the canonical names from the gRPC
/// status taxonomy, indexed by their numeric code.
/// https://opentelemetry.io/docs/specs/semconv/registry/attributes/rpc/
const List<String> grpcStatusCodeNames = [
  'OK', // 0
  'CANCELLED', // 1
  'UNKNOWN', // 2
  'INVALID_ARGUMENT', // 3
  'DEADLINE_EXCEEDED', // 4
  'NOT_FOUND', // 5
  'ALREADY_EXISTS', // 6
  'PERMISSION_DENIED', // 7
  'RESOURCE_EXHAUSTED', // 8
  'FAILED_PRECONDITION', // 9
  'ABORTED', // 10
  'OUT_OF_RANGE', // 11
  'UNIMPLEMENTED', // 12
  'INTERNAL', // 13
  'UNAVAILABLE', // 14
  'DATA_LOSS', // 15
  'UNAUTHENTICATED', // 16
];

/// Returns the canonical gRPC status name for [code], or the numeric
/// code as a string when the code is outside the known taxonomy (no
/// guessed names).
String grpcStatusCodeName(int code) =>
    code >= 0 && code < grpcStatusCodeNames.length
        ? grpcStatusCodeNames[code]
        : '$code';
