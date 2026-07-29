/// A pre-evaluated flag value returned by the server.
class FlagValue {
  final dynamic value;
  final String variation;
  final String reason;

  /// Key of the prerequisite flag that caused this flag to serve its off
  /// variation. Populated by the server only when `reason ==
  /// "prerequisite-failed"`; null for all other reasons.
  final String? prerequisiteKey;

  const FlagValue({
    required this.value,
    required this.variation,
    required this.reason,
    this.prerequisiteKey,
  });

  factory FlagValue.fromJson(Map<String, dynamic> json) {
    return FlagValue(
      value: json['value'],
      variation: json['variation'] as String,
      reason: json['reason'] as String,
      prerequisiteKey: json['prerequisiteKey'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'value': value,
      'variation': variation,
      'reason': reason,
    };
    if (prerequisiteKey != null) json['prerequisiteKey'] = prerequisiteKey;
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlagValue &&
          runtimeType == other.runtimeType &&
          value == other.value &&
          variation == other.variation &&
          reason == other.reason &&
          prerequisiteKey == other.prerequisiteKey;

  @override
  int get hashCode =>
      Object.hash(value, variation, reason, prerequisiteKey);
}

/// Server response from /v1/client/evaluate and /v1/client/identify.
class EvaluateResponse {
  final Map<String, FlagValue> flags;

  const EvaluateResponse({required this.flags});

  factory EvaluateResponse.fromJson(Map<String, dynamic> json) {
    final flagsJson = json['flags'] as Map<String, dynamic>;
    return EvaluateResponse(
      flags: flagsJson.map(
        (key, value) => MapEntry(key, FlagValue.fromJson(value as Map<String, dynamic>)),
      ),
    );
  }
}

/// An analytics event sent to /v1/sdk/events.
class SdkEvent {
  final String type;
  final String? flagKey;
  final String? userId;
  final String? variation;
  final String timestamp;
  final Map<String, dynamic>? metadata;

  const SdkEvent({
    required this.type,
    this.flagKey,
    this.userId,
    this.variation,
    required this.timestamp,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': type,
      'timestamp': timestamp,
    };
    if (flagKey != null) json['flagKey'] = flagKey;
    if (userId != null) json['userId'] = userId;
    if (variation != null) json['variation'] = variation;
    if (metadata != null) json['metadata'] = metadata;
    return json;
  }
}

/// Emitted once per variation call. [reason] is the server's kebab-case string
/// forwarded verbatim — client SDKs have no local evaluator, so the engine is
/// their evaluator. The one synthesized value is `flag-not-found`, used when the
/// flag is absent from the snapshot.
class EvaluationEvent {
  final String flagKey;
  final Map<String, dynamic> context;
  final dynamic value;

  /// The served arm. Null when the flag is absent from the snapshot.
  final String? variationKey;
  final String reason;

  /// Parsed from a `rule-match:{id}` reason; null for every other reason.
  final String? ruleId;

  /// Set by the server only when `reason == "prerequisite-failed"`.
  final String? prerequisiteKey;

  /// ISO-8601.
  final String timestamp;

  const EvaluationEvent({
    required this.flagKey,
    required this.context,
    required this.value,
    required this.reason,
    required this.timestamp,
    this.variationKey,
    this.ruleId,
    this.prerequisiteKey,
  });
}

/// An in-process observer invoked on every variation call. Return value ignored.
typedef EvaluationInspector = void Function(EvaluationEvent event);
