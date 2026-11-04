import 'dart:async';

/// A function the model may call, described by a JSON Schema.
///
/// Adapters send it as an OpenAI `function` tool, an Anthropic tool with
/// `input_schema`, or a Gemini `functionDeclarations` entry.
class ToolDefinition {
  /// Creates a tool definition.
  ///
  /// [name] must be unique within a request and use letters, digits,
  /// underscores, or hyphens. [parameters] is a JSON Schema object, for
  /// example `{'type': 'object', 'properties': {...}, 'required': [...]}`.
  /// Gemini accepts only an OpenAPI-style subset of JSON Schema, so keep
  /// schemas to `type`, `properties`, `required`, `items`, `enum`, and
  /// `description` when Gemini is in the chain.
  const ToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{},
    },
  });

  /// Name the model uses to call the tool.
  final String name;

  /// What the tool does and when to call it. The model reads this.
  final String description;

  /// JSON Schema for the arguments object.
  final Map<String, Object?> parameters;

  /// JSON form, used for response cache keys.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'description': description,
      'parameters': parameters,
    };
  }
}

/// Runs a tool with the arguments the model chose.
///
/// The returned value is sent back to the model: a [String] as is, anything
/// else encoded as JSON. Throwing an [Exception] sends its message back as
/// an error result, so the model can recover.
typedef ToolHandler =
    FutureOr<Object?> Function(Map<String, Object?> arguments);

/// A [ToolDefinition] the router can run.
///
/// Pass tools to `RouterLlmProvider.tools`. When a model calls one, the
/// router runs [handler], sends the result back to the same provider, and
/// streams the model's final reply.
class RouterTool extends ToolDefinition {
  /// Creates a runnable tool.
  const RouterTool({
    required super.name,
    required super.description,
    super.parameters,
    required this.handler,
  });

  /// Runs the tool.
  final ToolHandler handler;
}

/// A model's request to run a tool.
class ToolCall {
  /// Creates a tool call.
  ///
  /// [providerData] holds vendor fields that must be sent back unchanged
  /// with the call on the next request, such as Gemini's
  /// `thoughtSignature`.
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.providerData = const <String, Object?>{},
  });

  /// Identifier that links the call to its [ToolResult]. Generated when the
  /// vendor does not supply one.
  final String id;

  /// [ToolDefinition.name] of the tool to run.
  final String name;

  /// Decoded arguments object.
  final Map<String, Object?> arguments;

  /// Vendor fields to echo back with this call.
  final Map<String, Object?> providerData;
}

/// The outcome of running a [ToolCall], sent back to the model.
class ToolResult {
  /// Creates a tool result for the call with [callId].
  const ToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  /// [ToolCall.id] of the call this answers.
  final String callId;

  /// [ToolCall.name] of the call this answers.
  final String name;

  /// Result text, often JSON.
  final String content;

  /// Whether the tool failed. The model sees [content] as the error.
  final bool isError;
}
