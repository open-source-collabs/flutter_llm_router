import 'dart:convert';

import '../exceptions/router_exceptions.dart';
import 'tool.dart';
import 'turn_attachment.dart';

/// One user or assistant turn sent to an upstream model.
enum ChatTurnRole {
  /// Text the user sent, or tool results sent back to the model.
  user,

  /// Text an assistant already produced, and the tools it called.
  assistant,
}

/// A single chat message in provider request order.
///
/// The `to...` methods build each vendor's message shape, including
/// [attachments], [toolCalls], and [toolResults]. Text attachments are
/// inlined as text for every vendor. They throw
/// [ProviderUnavailableLlmException] for an attachment the vendor cannot
/// take, so the router fails over.
class ChatTurn {
  /// Creates a turn with [role], [text], and optional [attachments],
  /// [toolCalls], and [toolResults].
  ///
  /// [toolCalls] belongs on an assistant turn and [toolResults] on the user
  /// turn that follows it.
  const ChatTurn({
    required this.role,
    required this.text,
    this.attachments = const <TurnAttachment>[],
    this.toolCalls = const <ToolCall>[],
    this.toolResults = const <ToolResult>[],
  });

  /// Who produced [text].
  final ChatTurnRole role;

  /// Message body sent to the provider.
  final String text;

  /// Files and links sent with [text], in the order the user added them.
  final List<TurnAttachment> attachments;

  /// Tools the assistant asked to run in this turn.
  final List<ToolCall> toolCalls;

  /// Results of the previous assistant turn's [toolCalls].
  final List<ToolResult> toolResults;

  bool get _isPlainText =>
      attachments.isEmpty && toolCalls.isEmpty && toolResults.isEmpty;

  /// OpenAI chat-completions messages for this turn.
  ///
  /// Usually one message. Each tool result is its own `tool` message, so a
  /// turn with [toolResults] yields one message per result, followed by a
  /// user message when the turn also has text or attachments.
  List<Map<String, Object?>> toOpenAiMessages() {
    if (toolResults.isEmpty) return <Map<String, Object?>>[toOpenAiMessage()];
    return <Map<String, Object?>>[
      for (final result in toolResults)
        <String, Object?>{
          'role': 'tool',
          'tool_call_id': result.callId,
          'content': result.content,
        },
      if (text.isNotEmpty || attachments.isNotEmpty)
        ChatTurn(
          role: role,
          text: text,
          attachments: attachments,
        ).toOpenAiMessage(),
    ];
  }

  /// OpenAI chat-completions message object for this turn, without
  /// [toolResults]; use [toOpenAiMessages] when there may be some.
  ///
  /// Without attachments, `content` is a string. With attachments, it is a
  /// list of parts: images as `image_url`, PDFs as `file`, and text as
  /// `text`. [toolCalls] are sent as `tool_calls`.
  Map<String, Object?> toOpenAiMessage() {
    final role = this.role == ChatTurnRole.user ? 'user' : 'assistant';
    if (toolCalls.isNotEmpty) {
      return <String, Object?>{
        'role': role,
        'content': text.isEmpty ? null : text,
        'tool_calls': <Object?>[
          for (final call in toolCalls)
            <String, Object?>{
              'id': call.id,
              'type': 'function',
              'function': <String, Object?>{
                'name': call.name,
                'arguments': jsonEncode(call.arguments),
              },
            },
        ],
      };
    }
    if (attachments.isEmpty) {
      return <String, Object?>{'role': role, 'content': text};
    }
    return <String, Object?>{
      'role': role,
      'content': <Object?>[
        if (text.isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
        for (final attachment in attachments) _openAiPart(attachment),
      ],
    };
  }

  /// Anthropic Messages object for this turn.
  ///
  /// With attachments or tools, `content` is a list of blocks: tool results
  /// as `tool_result`, images as `image`, PDFs as `document`, text as
  /// `text`, and tool calls as `tool_use`. Attachments come before the
  /// prompt, as Anthropic recommends.
  Map<String, Object?> toAnthropicMessage() {
    final role = this.role == ChatTurnRole.user ? 'user' : 'assistant';
    if (_isPlainText) {
      return <String, Object?>{'role': role, 'content': text};
    }
    return <String, Object?>{
      'role': role,
      'content': <Object?>[
        for (final result in toolResults)
          <String, Object?>{
            'type': 'tool_result',
            'tool_use_id': result.callId,
            'content': result.content,
            if (result.isError) 'is_error': true,
          },
        for (final attachment in attachments) _anthropicBlock(attachment),
        if (text.isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
        for (final call in toolCalls)
          <String, Object?>{
            'type': 'tool_use',
            'id': call.id,
            'name': call.name,
            'input': call.arguments,
          },
      ],
    };
  }

  /// Gemini `contents` entry for this turn.
  ///
  /// Gemini names the assistant role `model`. Images, PDFs, audio, and video
  /// are sent as `inlineData`. Links are sent as text. Tool calls are sent
  /// as `functionCall` parts with their `thoughtSignature`, and results as
  /// `functionResponse` parts.
  Map<String, Object?> toGeminiContent() {
    return <String, Object?>{
      'role': role == ChatTurnRole.user ? 'user' : 'model',
      'parts': <Object?>[
        for (final result in toolResults) _geminiResponse(result),
        if (text.isNotEmpty || _isPlainText) <String, Object?>{'text': text},
        for (final attachment in attachments) _geminiPart(attachment),
        for (final call in toolCalls) _geminiCall(call),
      ],
    };
  }
}

Map<String, Object?> _geminiCall(ToolCall call) {
  final id = call.providerData['geminiCallId'];
  final signature = call.providerData['thoughtSignature'];
  return <String, Object?>{
    'functionCall': <String, Object?>{
      'name': call.name,
      'args': call.arguments,
      if (id is String) 'id': id,
    },
    if (signature is String) 'thoughtSignature': signature,
  };
}

Map<String, Object?> _geminiResponse(ToolResult result) {
  Object? decoded;
  try {
    decoded = jsonDecode(result.content);
  } on FormatException {
    decoded = result.content;
  }
  return <String, Object?>{
    'functionResponse': <String, Object?>{
      'name': result.name,
      'response': result.isError
          ? <String, Object?>{'error': result.content}
          : decoded is Map<String, Object?>
          ? decoded
          : <String, Object?>{'result': decoded},
    },
  };
}

Map<String, Object?> _openAiPart(TurnAttachment attachment) {
  return switch (attachment) {
    FileTurnAttachment(kind: AttachmentKind.image) => <String, Object?>{
      'type': 'image_url',
      'image_url': <String, Object?>{'url': attachment.dataUrl},
    },
    FileTurnAttachment(kind: AttachmentKind.pdf) => <String, Object?>{
      'type': 'file',
      'file': <String, Object?>{
        'filename': attachment.name,
        'file_data': attachment.dataUrl,
      },
    },
    FileTurnAttachment(kind: AttachmentKind.text) => <String, Object?>{
      'type': 'text',
      'text': _inlineText(attachment),
    },
    FileTurnAttachment() => _unsupported('OpenAI', attachment),
    LinkTurnAttachment(kind: AttachmentKind.image) => <String, Object?>{
      'type': 'image_url',
      'image_url': <String, Object?>{'url': attachment.url.toString()},
    },
    LinkTurnAttachment() => <String, Object?>{
      'type': 'text',
      'text': _linkText(attachment),
    },
  };
}

Map<String, Object?> _anthropicBlock(TurnAttachment attachment) {
  return switch (attachment) {
    FileTurnAttachment(kind: AttachmentKind.image) => <String, Object?>{
      'type': 'image',
      'source': <String, Object?>{
        'type': 'base64',
        'media_type': attachment.mimeType,
        'data': attachment.base64Data,
      },
    },
    FileTurnAttachment(kind: AttachmentKind.pdf) => <String, Object?>{
      'type': 'document',
      'source': <String, Object?>{
        'type': 'base64',
        'media_type': 'application/pdf',
        'data': attachment.base64Data,
      },
    },
    FileTurnAttachment(kind: AttachmentKind.text) => <String, Object?>{
      'type': 'text',
      'text': _inlineText(attachment),
    },
    FileTurnAttachment() => _unsupported('Anthropic', attachment),
    LinkTurnAttachment(kind: AttachmentKind.image) => <String, Object?>{
      'type': 'image',
      'source': <String, Object?>{
        'type': 'url',
        'url': attachment.url.toString(),
      },
    },
    LinkTurnAttachment() => <String, Object?>{
      'type': 'text',
      'text': _linkText(attachment),
    },
  };
}

Map<String, Object?> _geminiPart(TurnAttachment attachment) {
  return switch (attachment) {
    FileTurnAttachment(kind: AttachmentKind.text) => <String, Object?>{
      'text': _inlineText(attachment),
    },
    FileTurnAttachment(kind: AttachmentKind.other) => _unsupported(
      'Gemini',
      attachment,
    ),
    FileTurnAttachment() => <String, Object?>{
      'inlineData': <String, Object?>{
        'mimeType': attachment.mimeType,
        'data': attachment.base64Data,
      },
    },
    LinkTurnAttachment() => <String, Object?>{'text': _linkText(attachment)},
  };
}

String _inlineText(FileTurnAttachment attachment) {
  return 'Attached file "${attachment.name}" (${attachment.mimeType}):\n'
      '${attachment.text}';
}

String _linkText(LinkTurnAttachment attachment) {
  return 'Attached link "${attachment.name}": ${attachment.url}';
}

Never _unsupported(String vendor, TurnAttachment attachment) {
  throw ProviderUnavailableLlmException(
    '$vendor cannot receive ${attachment.mimeType} attachments '
    '("${attachment.name}")',
  );
}
