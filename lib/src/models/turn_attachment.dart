import 'dart:convert';
import 'dart:typed_data';

/// What an attachment carries, which decides how each vendor receives it.
enum AttachmentKind {
  /// A raster image such as PNG, JPEG, GIF, or WebP.
  image,

  /// A PDF document.
  pdf,

  /// Plain text, source code, JSON, XML, CSV, or a non-image link.
  ///
  /// Every provider accepts this kind, because adapters send it as text.
  text,

  /// An audio clip.
  audio,

  /// A video clip.
  video,

  /// Any other binary file.
  other;

  /// Returns the kind for a MIME type, such as `image/png` or `text/csv`.
  static AttachmentKind fromMimeType(String mimeType) {
    final mime = mimeType.toLowerCase();
    if (mime.startsWith('image/')) return AttachmentKind.image;
    if (mime == 'application/pdf') return AttachmentKind.pdf;
    if (mime.startsWith('audio/')) return AttachmentKind.audio;
    if (mime.startsWith('video/')) return AttachmentKind.video;
    if (mime.startsWith('text/') ||
        mime.endsWith('+json') ||
        mime.endsWith('+xml') ||
        _textMimeTypes.contains(mime)) {
      return AttachmentKind.text;
    }
    return AttachmentKind.other;
  }

  static const Set<String> _textMimeTypes = <String>{
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-yaml',
    'application/yaml',
    'application/x-sh',
    'application/sql',
  };
}

/// A file or link sent with a `ChatTurn`.
///
/// The router converts Flutter AI Toolkit attachments into this type, so
/// adapters do not depend on the toolkit.
sealed class TurnAttachment {
  /// Creates an attachment named [name] with [mimeType].
  const TurnAttachment({required this.name, required this.mimeType});

  /// File name or link title shown to the user.
  final String name;

  /// MIME type of the content, for example `image/png`.
  final String mimeType;

  /// How adapters send this attachment.
  AttachmentKind get kind;
}

/// File content sent inline with the request.
final class FileTurnAttachment extends TurnAttachment {
  /// Creates an inline file attachment.
  const FileTurnAttachment({
    required super.name,
    required super.mimeType,
    required this.bytes,
  });

  /// Raw file content.
  final Uint8List bytes;

  @override
  AttachmentKind get kind => AttachmentKind.fromMimeType(mimeType);

  /// [bytes] encoded as base64.
  String get base64Data => base64Encode(bytes);

  /// [bytes] as a `data:` URL, the form OpenAI-compatible APIs accept.
  String get dataUrl => 'data:$mimeType;base64,$base64Data';

  /// [bytes] decoded as UTF-8, with malformed sequences replaced.
  ///
  /// Meaningful only when [kind] is [AttachmentKind.text].
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// A link the provider may fetch, or the model may read as text.
///
/// Image links are sent as images where the vendor accepts image URLs.
/// Every other link is sent as a text reference, so its [kind] is
/// [AttachmentKind.text].
final class LinkTurnAttachment extends TurnAttachment {
  /// Creates a link attachment.
  const LinkTurnAttachment({
    required super.name,
    required super.mimeType,
    required this.url,
  });

  /// Location of the linked content.
  final Uri url;

  @override
  AttachmentKind get kind =>
      AttachmentKind.fromMimeType(mimeType) == AttachmentKind.image
      ? AttachmentKind.image
      : AttachmentKind.text;
}
