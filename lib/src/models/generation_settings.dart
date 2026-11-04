import 'response_schema.dart';
import 'tool.dart';

/// Sampling, instruction, tool, and output settings sent with each request.
///
/// Null fields are left out of the request, so the provider's own default
/// applies. Set defaults on `RouterLlmProvider.settings` and override them
/// per provider with `ProviderConfig.settings`. The router fills [tools]
/// from `RouterLlmProvider.tools` and [responseSchema] from
/// `RouterLlmProvider.generateObject`.
class GenerationSettings {
  /// Creates settings. Every field is optional.
  ///
  /// [temperature] must be zero or positive and [topP] between zero and one
  /// when present.
  const GenerationSettings({
    this.systemPrompt,
    this.temperature,
    this.topP,
    this.stopSequences,
    this.tools,
    this.responseSchema,
  }) : assert(temperature == null || temperature >= 0),
       assert(topP == null || (topP >= 0 && topP <= 1));

  /// Instructions sent ahead of the conversation.
  ///
  /// OpenAI-compatible APIs receive a `system` message, Anthropic the
  /// `system` field, and Gemini `systemInstruction`.
  final String? systemPrompt;

  /// Sampling temperature. Some reasoning models reject it.
  final double? temperature;

  /// Nucleus sampling probability mass. Some models reject setting it
  /// together with [temperature].
  final double? topP;

  /// Strings that end the reply when generated. OpenAI accepts at most four.
  final List<String>? stopSequences;

  /// Tools the model may call.
  final List<ToolDefinition>? tools;

  /// JSON Schema the reply must match.
  final ResponseSchema? responseSchema;

  /// Returns these settings with each null field taken from [defaults].
  GenerationSettings withDefaults(GenerationSettings defaults) {
    return GenerationSettings(
      systemPrompt: systemPrompt ?? defaults.systemPrompt,
      temperature: temperature ?? defaults.temperature,
      topP: topP ?? defaults.topP,
      stopSequences: stopSequences ?? defaults.stopSequences,
      tools: tools ?? defaults.tools,
      responseSchema: responseSchema ?? defaults.responseSchema,
    );
  }

  /// Whether a system prompt with text is set.
  bool get hasSystemPrompt => systemPrompt?.isNotEmpty ?? false;

  /// Whether at least one stop sequence is set.
  bool get hasStopSequences => stopSequences?.isNotEmpty ?? false;

  /// Whether at least one tool is set.
  bool get hasTools => tools?.isNotEmpty ?? false;

  /// JSON form, used for response cache keys.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'topP': topP,
      'stopSequences': stopSequences,
      'tools': tools?.map((tool) => tool.toJson()).toList(),
      'responseSchema': responseSchema?.toJson(),
    };
  }
}
