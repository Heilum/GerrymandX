import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;

/// What is known about a downloaded database: its SHA-256, and the size and
/// modification time it had when hashed. A file whose size or time no longer
/// match was replaced since (downloaded again, copied in) and is hashed anew.
///
/// Kept per election folder in `versions.json`, so a multi-megabyte database
/// is hashed once rather than on every update check.
class DbVersionRecord {
  final String sha256;
  final int size;
  final int modified;

  const DbVersionRecord({
    required this.sha256,
    required this.size,
    required this.modified,
  });

  static const fileName = 'versions.json';

  /// Whether this record still describes [stat]'s file.
  bool matches(FileStat stat) =>
      size == stat.size && modified == stat.modified.millisecondsSinceEpoch;

  factory DbVersionRecord.fromJson(Map<String, dynamic> json) => DbVersionRecord(
        sha256: json['sha256'] as String,
        size: (json['size'] as num).toInt(),
        modified: (json['modified'] as num).toInt(),
      );

  Map<String, dynamic> toJson() =>
      {'sha256': sha256, 'size': size, 'modified': modified};

  /// Hashes [path] off the UI isolate and records it with the file's stat.
  static Future<DbVersionRecord> hash(String path) async {
    final stat = await File(path).stat();
    return DbVersionRecord(
      sha256: await sha256Of(path),
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
    );
  }

  static Future<String> sha256Of(String path) => Isolate.run(
      () async => (await crypto.sha256.bind(File(path).openRead()).first).toString());

  /// {file name: record} from [folder]'s `versions.json`; empty when absent or
  /// unreadable, which only means files get hashed again.
  static Future<Map<String, DbVersionRecord>> readAll(String folder) async {
    final file = File('$folder/$fileName');
    if (!await file.exists()) return {};
    try {
      final decoded = json.decode(await file.readAsString()) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries)
          entry.key: DbVersionRecord.fromJson(entry.value as Map<String, dynamic>),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> writeAll(
      String folder, Map<String, DbVersionRecord> records) async {
    await File('$folder/$fileName').writeAsString(const JsonEncoder.withIndent('  ')
        .convert({for (final e in records.entries) e.key: e.value.toJson()}));
  }
}
