import 'dart:convert';
import 'dart:typed_data';

import '../models/app_models.dart';

/// Bounded, least-recently-used photo cache for the scan/verify flow
/// (NEW_DATA_LIFECYCLE.md §Images — stable photo identifiers + client caching
/// with bounded size/eviction; no duplicate uploads/downloads). Student photos
/// are embedded in the students doc as base64, so this cache decodes each
/// student's bytes at most once per session and drops the least-recently-viewed
/// entries past [maxEntries] or [maxBytes].
class PhotoCache {
  PhotoCache({this.maxEntries = 64, this.maxBytes = 12 * 1024 * 1024});

  final int maxEntries;
  final int maxBytes;

  final _byId = <String, Uint8List>{};
  int _bytes = 0;

  int get length => _byId.length;

  /// Total decoded bytes currently held (the eviction budget meter).
  int get bytes => _bytes;

  bool get isEmpty => _byId.isEmpty;

  /// Decoded photo bytes for [student], or null when the student has no
  /// readable photo on file. Hits are LRU-touched; misses are decoded on first
  /// view and cached, so scanning the same gate queue twice never re-decodes
  /// the same student's image.
  Uint8List? bytesFor(Student student) {
    final id = student.studentId;
    if (id.isEmpty) return null;
    final existing = _byId.remove(id);
    if (existing != null) {
      _byId[id] = existing; // touch → most-recently-used
      return existing;
    }
    final base64 = student.photoBase64;
    if (base64 == null || base64.isEmpty) return null;
    try {
      final bytes = base64Decode(base64);
      _insert(id, bytes);
      return bytes;
    } on Object {
      return null; // unreadable photo — same behaviour as the verify fallback
    }
  }

  void _insert(String id, Uint8List bytes) {
    _byId[id] = bytes;
    _bytes += bytes.lengthInBytes;
    _trim();
  }

  void _trim() {
    while (_byId.length > maxEntries || _bytes > maxBytes) {
      final oldestId = _byId.keys.first;
      final removed = _byId.remove(oldestId);
      if (removed == null) break;
      _bytes -= removed.lengthInBytes;
    }
  }

  void clear() {
    _byId.clear();
    _bytes = 0;
  }
}