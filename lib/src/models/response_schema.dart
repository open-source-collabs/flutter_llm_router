/// A JSON Schema the reply must match, for structured output.
///
/// `RouterLlmProvider.generateObject` sets it. Every provider is told the
/// schema in its system prompt. OpenAI-compatible APIs also receive it as
/// `response_format`, and Gemini switches to JSON mode. The router parses
/// and decodes each reply, and fails over when that fails.
class ResponseSchema {
  /// Creates a response schema.
  ///
  /// [name] identifies the schema to OpenAI and must use letters, digits,
  /// underscores, or hyphens. [strict] asks OpenAI to enforce the schema
  /// exactly, which requires `additionalProperties: false` and every
  /// property listed in `required`.
  const ResponseSchema({
    required this.name,
    required this.schema,
    this.description,
    this.strict = false,
  });

  /// Schema name.
  final String name;

  /// The JSON Schema.
  final Map<String, Object?> schema;

  /// What the output represents, sent to providers that accept it.
  final String? description;

  /// Whether OpenAI enforces the schema exactly.
  final bool strict;

  /// JSON form, used for response cache keys.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'schema': schema,
      'description': description,
      'strict': strict,
    };
  }
}
