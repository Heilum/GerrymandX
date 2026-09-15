import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/db_version_record.dart';
import 'package:gerrymanderx/models/remote_election_item.dart';
import 'package:gerrymanderx/providers/election_store.dart';

/// The update check rests on a versioned manifest listing each database's
/// hash, and on remembering the hash of what was downloaded.
void main() {
  group('versioned manifest', () {
    final manifest = <String, dynamic>{
      'version': 202609150751,
      '2024': [
        {
          'stateName': 'Texas',
          'db': 'https://files.xp-oncology.cn/gerrymander/2024/TX-2024.db',
          'size': 1234,
          'sha256': 'abc',
        },
      ],
      '2022': [
        {
          'stateName': 'Iowa',
          'db': 'https://files.xp-oncology.cn/gerrymander/2022/IA-2022.db',
        },
      ],
    };

    test('reads the version, and none from an unversioned manifest', () {
      expect(RemoteElectionItem.manifestVersionOf(manifest), 202609150751);
      expect(RemoteElectionItem.manifestVersionOf({'2024': []}), isNull);
      expect(RemoteElectionItem.manifestVersionOf(const []), isNull);
    });

    test('the version key is not taken for a year', () {
      final items = RemoteElectionItem.listFromManifest(manifest);
      expect(items.map((i) => i.name), ['2024', '2022']);
    });

    test('databases carry their size and hash when listed', () {
      final items = RemoteElectionItem.listFromManifest(manifest);
      final texas = items.first.dbs.single;
      expect(texas.size, 1234);
      expect(texas.sha256, 'abc');
      expect(texas.toJson()['sha256'], 'abc');

      final iowa = items.last.dbs.single;
      expect(iowa.sha256, isNull);
      expect(iowa.toJson().containsKey('sha256'), isFalse);
    });
  });

  group('localCopyOf', () {
    const local = ['AZ-2022.db', 'CA-2022-202609151031.db', 'National.db'];

    test('the file of the published name, when downloaded', () {
      expect(ElectionStore.localCopyOf('CA-2022-202609151031.db', local),
          'CA-2022-202609151031.db');
    });

    test('else an older version of the same state, whatever its name', () {
      expect(ElectionStore.localCopyOf('AZ-2022-202609151031.db', local),
          'AZ-2022.db');
      expect(ElectionStore.localCopyOf('CA-2022-202701010000.db', local),
          'CA-2022-202609151031.db');
    });

    test('nothing for a state that is not downloaded', () {
      expect(ElectionStore.localCopyOf('TX-2022-202609151031.db', local), isNull);
      expect(ElectionStore.localCopyOf('National-2022-1.db', local), isNull);
    });
  });

  group('DbVersionRecord', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('versions'));
    tearDown(() => dir.delete(recursive: true));

    test('hashes a file and notices when it is replaced', () async {
      final file = File('${dir.path}/TX-2024.db')..writeAsStringSync('hello');
      final record = await DbVersionRecord.hash(file.path);
      expect(record.sha256,
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      expect(record.size, 5);
      expect(record.matches(await file.stat()), isTrue);

      file.writeAsStringSync('hello, world');
      expect(record.matches(await file.stat()), isFalse);
    });

    test('round-trips through versions.json', () async {
      const record = DbVersionRecord(sha256: 'abc', size: 5, modified: 42);
      await DbVersionRecord.writeAll(dir.path, {'TX-2024.db': record});
      final read = await DbVersionRecord.readAll(dir.path);
      expect(read['TX-2024.db']!.toJson(), record.toJson());
    });

    test('a missing or broken versions.json reads as empty', () async {
      expect(await DbVersionRecord.readAll(dir.path), isEmpty);
      File('${dir.path}/${DbVersionRecord.fileName}').writeAsStringSync('{oops');
      expect(await DbVersionRecord.readAll(dir.path), isEmpty);
    });
  });
}
