import 'turn_attachment.dart';

/// The attachment kinds a provider and model accept.
///
/// The router skips a provider whose capabilities do not cover every
/// attachment in the conversation, and logs why, instead of sending a
/// request that would fail or silently drop the file. [AttachmentKind.text]
/// is always accepted, because adapters send it as text. When
/// `RouterLlmProvider.tools` is set, providers without [tools] are skipped
/// the same way.
class ProviderCapabilities {
  /// Creates capabilities that accept [attachmentKinds], and tool calls
  /// unless [tools] is false.
  const ProviderCapabilities(this.attachmentKinds, {this.tools = true});

  /// Whether the model can call tools.
  final bool tools;

  /// Text only: no images, PDFs, audio, or video.
  static const ProviderCapabilities textOnly = ProviderCapabilities(
    <AttachmentKind>{},
  );

  /// Text and images.
  static const ProviderCapabilities vision = ProviderCapabilities(
    <AttachmentKind>{AttachmentKind.image},
  );

  /// Every attachment kind. The default for custom adapters.
  static const ProviderCapabilities all = ProviderCapabilities(<AttachmentKind>{
    AttachmentKind.image,
    AttachmentKind.pdf,
    AttachmentKind.audio,
    AttachmentKind.video,
    AttachmentKind.other,
  });

  /// Attachment kinds accepted in addition to text.
  final Set<AttachmentKind> attachmentKinds;

  /// Whether [kind] can be sent.
  bool accepts(AttachmentKind kind) =>
      kind == AttachmentKind.text || attachmentKinds.contains(kind);

  /// The kinds in [kinds] that cannot be sent, in iteration order.
  List<AttachmentKind> unsupported(Iterable<AttachmentKind> kinds) {
    return <AttachmentKind>[
      for (final kind in kinds)
        if (!accepts(kind)) kind,
    ];
  }
}
