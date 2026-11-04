import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// A reply stored by a [ResponseCache].
@immutable
class CachedResponse {
  /// Creates a cached reply.
  const CachedResponse({
    required this.text,
    required this.providerName,
    required this.model,
  });

  /// The full reply text.
  final String text;

  /// `ProviderConfig.name` of the provider that produced it.
  final String providerName;

  /// Model id that produced it.
  final String model;
}

/// Stores complete replies so an identical request is answered without a
/// provider call.
///
/// The router reads before routing and writes after a reply finishes
/// successfully. The key covers the conversation, its attachments, and the
/// generation settings, not the provider, so a reply from any provider can
/// answer. Keys can be long; a persistent implementation may hash them.
/// Errors thrown by either method are ignored, so a broken cache never
/// fails a request.
abstract class ResponseCache {
  /// Const constructor for subclasses.
  const ResponseCache();

  /// Returns the reply stored under [key], or null.
  FutureOr<CachedResponse?> read(String key);

  /// Stores [response] under [key].
  FutureOr<void> write(String key, CachedResponse response);
}

/// An in-memory [ResponseCache] that evicts the least recently used entry.
class InMemoryResponseCache extends ResponseCache {
  /// Creates a cache of at most [maxEntries] replies, each kept for [ttl].
  ///
  /// [maxEntries] must be positive. A null [ttl] keeps entries until they
  /// are evicted. [clock] replaces [DateTime.now] in tests.
  InMemoryResponseCache({
    this.maxEntries = 100,
    this.ttl,
    DateTime Function()? clock,
  }) : assert(maxEntries > 0),
       _clock = clock ?? DateTime.now;

  /// Most replies kept at once.
  final int maxEntries;

  /// How long a reply stays valid, or null for no limit.
  final Duration? ttl;

  final DateTime Function() _clock;
  final LinkedHashMap<String, (CachedResponse, DateTime)> _entries =
      LinkedHashMap<String, (CachedResponse, DateTime)>();

  /// Number of stored replies, including expired ones not yet evicted.
  int get length => _entries.length;

  @override
  CachedResponse? read(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    final ttl = this.ttl;
    if (ttl != null && _clock().difference(entry.$2) > ttl) return null;
    _entries[key] = entry;
    return entry.$1;
  }

  @override
  void write(String key, CachedResponse response) {
    _entries
      ..remove(key)
      ..[key] = (response, _clock());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Removes every stored reply.
  void clear() => _entries.clear();
}
