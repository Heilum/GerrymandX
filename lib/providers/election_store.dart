import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/models/remote_election_item.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

class ElectionStore {
  final localDatabases = ListSignal<String>([]);
  final localElectionSubItems = MapSignal<String, List<ElectionSubItem>>({});
  final selectedElectionFolder = Signal<String?>(null);
  final selectedSubItem = Signal<ElectionSubItem?>(null);

  /// Candidate/party metadata per local election folder, read from the
  /// `election.json` written next to the downloaded databases.
  final localElectionMeta = MapSignal<String, RemoteElectionItem>({});

  /// Office the user wants to see (`President`, `US Senate`, `US House`,
  /// `Governor`). A state that did not hold that contest in the selected year
  /// falls back to its first contest; the preference itself is kept so that
  /// the next state opens on the same office.
  final selectedOffice = Signal<String>('President');

  /// Party codes seen in each election folder's databases, filled in as the
  /// comparison modes open them. Year folders keep parties inside the
  /// databases, so — unlike the legacy manifest — they are not known up front.
  final knownPartyNames = MapSignal<String, Set<String>>({});

  final remoteElections = ListSignal<RemoteElectionItem>([]);
  final selectedRemoteElection = Signal<RemoteElectionItem?>(null);
  final downloadingElections = SetSignal<String>({});
  final downloadProgress = MapSignal<String, double>({});
  final dbDownloadProgress = MapSignal<String, double>({});
  final isRemoteMode = Signal<bool>(false);
  final isLoading = Signal<bool>(false);
  final isRemoteLoading = Signal<bool>(false);

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  ElectionStore() {
    _loadLocalDatabases();
  }

  /// Re-scans the sandbox for downloaded elections.
  ///
  /// Needed because nothing else notices files that appear while the app is
  /// running: a download in progress, or databases copied in from outside.
  Future<void> refreshLocalDatabases() => _loadLocalDatabases();

  Future<void> _loadLocalDatabases() async {
    isLoading.value = true;
    try {
      final dbFolders = await _dbHelper.ensureDefaultAndListDatabases();
      localDatabases.value = dbFolders;
      final dbDir = await _dbHelper.dbDir;

      final map = <String, List<ElectionSubItem>>{};
      final meta = <String, RemoteElectionItem>{};
      for (final folder in dbFolders) {
        final folderDir = Directory(p.join(dbDir, folder));
        final folderMeta = await _readElectionMeta(folderDir.path);
        if (folderMeta != null) meta[folder] = folderMeta;

        final items = <ElectionSubItem>[];
        final hasNational = await _dbHelper.hasNationalDb(folder);
        if (hasNational) {
          items.add(const ElectionSubItem(name: 'National', isNational: true));
        }

        // Display names come from National.db when it is present (it also
        // carries the state ids), and from meta.json otherwise.
        final labels = <String, String>{};
        final stateIds = <String, int?>{};
        if (folderMeta != null) {
          for (final db in folderMeta.dbs) {
            final fileName = p.basename(Uri.parse(db.url).path);
            labels[fileName] = db.name;
          }
        }
        if (hasNational) {
          for (final s in await _dbHelper.getStatesInfoForElection(folder)) {
            final dbName = s['db_name'];
            if (dbName == null || dbName.isEmpty) continue;
            labels[dbName] = s['name'] ?? labels[dbName] ?? dbName;
            stateIds[dbName] = int.tryParse(s['id'] ?? '');
          }
        }

        for (final dbName in await _dbHelper.getDownloadedDbNames(folder)) {
          if (dbName == 'National.db') continue;
          if (labels[dbName] == null) {
            // Year-folder databases name themselves; a legacy database copied
            // in by hand keeps its file name.
            final dbMeta = await _dbHelper.readStateDbMeta(folder, dbName);
            final stateName = dbMeta['state_name'];
            if (stateName != null && stateName.isNotEmpty) labels[dbName] = stateName;
          }
          items.add(
            ElectionSubItem(
              name: labels[dbName] ?? p.basenameWithoutExtension(dbName),
              isNational: false,
              dbName: dbName,
              stateId: stateIds[dbName],
            ),
          );
        }

        map[folder] = items;
      }
      localElectionSubItems.value = map;
      localElectionMeta.value = meta;

      if (dbFolders.isNotEmpty &&
          selectedElectionFolder.value == null &&
          !isRemoteMode.value) {
        final firstFolder = dbFolders.first;
        final items = map[firstFolder];
        batch(() {
          selectedElectionFolder.value = firstFolder;
          if (items != null && items.isNotEmpty) {
            selectedSubItem.value = items.first;
          }
        });
      }
    } catch (e) {
      debugPrint("Error loading local databases: $e");
    } finally {
      isLoading.value = false;
    }
  }

  static const _metaFileName = DatabaseHelper.metaFileName;

  Future<RemoteElectionItem?> _readElectionMeta(String folderPath) async {
    final file = File(p.join(folderPath, _metaFileName));
    if (!await file.exists()) return null;
    try {
      final decoded = json.decode(await file.readAsString());
      return RemoteElectionItem.fromJson(decoded as Map<String, dynamic>);
    } catch (e) {
      debugPrint("Error reading $_metaFileName in $folderPath: $e");
      return null;
    }
  }

  /// Stores candidates/parties alongside the databases so a downloaded
  /// election keeps working without the remote manifest.
  Future<void> _writeElectionMeta(RemoteElectionItem item) async {
    try {
      final dbDir = await _dbHelper.dbDir;
      final dir = Directory(p.join(dbDir, item.name));
      await dir.create(recursive: true);
      await File(p.join(dir.path, _metaFileName))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(item.toJson()));
    } catch (e) {
      debugPrint("Error writing $_metaFileName for ${item.name}: $e");
    }
  }

  /// Refreshes `election.json` for elections that are already on disk, so that
  /// folders downloaded before the manifest carried candidates get updated.
  Future<void> _syncDownloadedElectionMeta() async {
    final dbDir = await _dbHelper.dbDir;
    var changed = false;
    for (final item in remoteElections.value) {
      if (item.candidates.isEmpty && item.parties.isEmpty) continue;
      final dir = Directory(p.join(dbDir, item.name));
      if (!await dir.exists()) continue;
      await _writeElectionMeta(item);
      changed = true;
    }
    if (changed) await _loadLocalDatabases();
  }

  /// Manifest of downloadable databases, keyed by year:
  /// `{"2024": [{"stateName": "Texas", "db": "…/TX-2024.db"}, …]}`.
  static const remoteManifestUrl =
      'https://files.xp-oncology.cn/gerrymander/new_elections.json';

  Future<void> fetchRemoteElections() async {
    isRemoteLoading.value = true;
    final client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    try {
      final request = await client.getUrl(Uri.parse(remoteManifestUrl));
      final response = await request.close();
      if (response.statusCode == 200) {
        final jsonString = await response.transform(utf8.decoder).join();
        remoteElections.value =
            RemoteElectionItem.listFromManifest(json.decode(jsonString));
        await _syncDownloadedElectionMeta();
        _checkAndResumeInterruptedDownloads();
      } else {
        debugPrint(
          "Remote manifest returned status code: ${response.statusCode}",
        );
      }
    } catch (e, stack) {
      debugPrint("Error fetching remote manifest: $e\n$stack");
    } finally {
      client.close();
      isRemoteLoading.value = false;
    }
  }

  Future<void> _checkAndResumeInterruptedDownloads() async {
    final dbDir = await _dbHelper.dbDir;
    for (final item in remoteElections.value) {
      if (downloadingElections.value.contains(item.name)) continue;

      final electionDir = Directory(p.join(dbDir, item.name));
      if (await electionDir.exists()) {
        final tmpFiles = await electionDir
            .list()
            .where((e) => e is File && e.path.endsWith('.tmp'))
            .toList();
        if (tmpFiles.isNotEmpty) {
          debugPrint(
            "Found interrupted download for ${item.name}, auto-resuming...",
          );
          downloadElection(item);
        }
      }
    }
  }

  Future<bool> isDbFileDownloaded(String electionName, String dbUrl) async {
    final dbDir = await _dbHelper.dbDir;
    final fileName = p.basename(Uri.parse(dbUrl).path);
    final targetPath = p.join(dbDir, electionName, fileName);
    final file = File(targetPath);
    final tempFile = File('$targetPath.tmp');

    if (await tempFile.exists()) return false;
    return file.exists();
  }

  Future<bool> isElectionDownloaded(RemoteElectionItem item) async {
    for (final dbItem in item.dbs) {
      if (!await isDbFileDownloaded(item.name, dbItem.url)) {
        return false;
      }
    }
    return true;
  }

  final activeFileDownloads = SetSignal<String>({});
  final Map<String, HttpClient> _activeClients = {};
  final Set<String> _cancelledKeys = {};

  Future<void> cancelElectionDownload(String electionName) async {
    _cancelledKeys.add(electionName);

    _activeClients.forEach((key, client) {
      if (key.startsWith('$electionName/')) {
        try {
          client.close(force: true);
        } catch (_) {}
      }
    });

    final updatedDownloading = Set<String>.from(downloadingElections.value)..remove(electionName);
    downloadingElections.value = updatedDownloading;

    final updatedProgress = Map<String, double>.from(downloadProgress.value)..remove(electionName);
    downloadProgress.value = updatedProgress;

    final updatedDbProgress = Map<String, double>.from(dbDownloadProgress.value);
    updatedDbProgress.removeWhere((k, _) => k.startsWith('$electionName/'));
    dbDownloadProgress.value = updatedDbProgress;

    try {
      final dbDir = await _dbHelper.dbDir;
      final electionDir = Directory(p.join(dbDir, electionName));
      if (await electionDir.exists()) {
        final tmpFiles = await electionDir
            .list()
            .where((e) => e is File && e.path.endsWith('.tmp'))
            .toList();
        for (final tmpFile in tmpFiles) {
          try {
            await tmpFile.delete();
          } catch (_) {}
        }
        // Nothing was downloaded: drop the folder we created for meta.json.
        final dbFiles = await electionDir
            .list()
            .where((e) => e is File && e.path.endsWith('.db'))
            .toList();
        if (dbFiles.isEmpty) {
          await electionDir.delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint("Error deleting temp files on cancel: $e");
    }

    _cancelledKeys.remove(electionName);
    await _loadLocalDatabases();
  }

  Future<void> cancelSingleDbDownload(String electionName, RemoteDbItem dbItem) async {
    final key = '$electionName/${dbItem.url}';
    _cancelledKeys.add(key);

    final client = _activeClients[key];
    if (client != null) {
      try {
        client.close(force: true);
      } catch (_) {}
    }

    final updatedDbProgress = Map<String, double>.from(dbDownloadProgress.value)..remove(key);
    dbDownloadProgress.value = updatedDbProgress;

    try {
      final dbDir = await _dbHelper.dbDir;
      final fileName = p.basename(Uri.parse(dbItem.url).path);
      final tempFile = File(p.join(dbDir, electionName, '$fileName.tmp'));
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      debugPrint("Error deleting single DB temp file on cancel: $e");
    }

    _cancelledKeys.remove(key);
  }

  Future<void> _safeMoveFile(File tempFile, File targetFile) async {
    await targetFile.parent.create(recursive: true);
    if (!await tempFile.exists()) return;

    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    try {
      await tempFile.rename(targetFile.path);
    } catch (e) {
      debugPrint("Rename failed ($e), falling back to copy & delete...");
      await tempFile.copy(targetFile.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> _downloadFileWithRange({
    required HttpClient client,
    required String dbUrl,
    required String targetPath,
    required String electionName,
    required Function(double fileProgress) onProgress,
  }) async {
    final lockKey = '$electionName/$dbUrl';
    if (activeFileDownloads.value.contains(targetPath)) {
      debugPrint("Download already active for $targetPath, skipping duplicate task.");
      return;
    }
    activeFileDownloads.value = {...activeFileDownloads.value, targetPath};
    _activeClients[lockKey] = client;

    try {
      if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
        return;
      }

      final file = File(targetPath);
      final tempFile = File('$targetPath.tmp');
      await tempFile.parent.create(recursive: true);

      // 1. Check if file is ALREADY fully downloaded
      if (await file.exists() && !await tempFile.exists()) {
        try {
          final headReq = await client.headUrl(Uri.parse(dbUrl));
          final headRes = await headReq.close();
          if (headRes.statusCode == 200 && headRes.contentLength > 0) {
            final localSize = await file.length();
            if (localSize == headRes.contentLength) {
              onProgress(1.0);
              return;
            }
          }
        } catch (e) {
          debugPrint("HEAD check error for $dbUrl: $e");
        }
      }

      if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
        return;
      }

      // 2. HTTP Range request setup
      int existingBytes = 0;
      if (await tempFile.exists()) {
        existingBytes = await tempFile.length();
        if (existingBytes > 0) {
          try {
            final headReq = await client.headUrl(Uri.parse(dbUrl));
            final headRes = await headReq.close();
            if (headRes.statusCode == 200 && headRes.contentLength > 0) {
              onProgress(
                (existingBytes / headRes.contentLength).clamp(0.0, 0.99),
              );
            }
          } catch (_) {}
        }
      }

      final request = await client.getUrl(Uri.parse(dbUrl));
      if (existingBytes > 0) {
        request.headers.add('Range', 'bytes=$existingBytes-');
      }
      final response = await request.close();

      if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
        return;
      }

      if (response.statusCode == 206) {
        // Server returned 206 Partial Content (resuming from byte offset)
        final contentRange = response.headers.value('content-range');
        int totalBytes = existingBytes + response.contentLength;
        if (contentRange != null && contentRange.contains('/')) {
          totalBytes = int.tryParse(contentRange.split('/').last) ?? totalBytes;
        }

        final sink = tempFile.openWrite(mode: FileMode.append);
        int downloadedBytes = existingBytes;
        int lastReportTime = 0;
        double lastReportProgress = -1.0;

        await for (final chunk in response) {
          if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
            await sink.close();
            if (await tempFile.exists()) await tempFile.delete();
            return;
          }
          sink.add(chunk);
          downloadedBytes += chunk.length;
          if (totalBytes > 0) {
            final currentProgress = downloadedBytes / totalBytes;
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - lastReportTime >= 100 || (currentProgress - lastReportProgress).abs() >= 0.01 || currentProgress >= 1.0) {
              lastReportTime = now;
              lastReportProgress = currentProgress;
              onProgress(currentProgress.clamp(0.0, 1.0));
            }
          }
        }
        await sink.close();

        if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
          if (await tempFile.exists()) await tempFile.delete();
          return;
        }

        if (downloadedBytes >= totalBytes) {
          await _safeMoveFile(tempFile, file);
          onProgress(1.0);
        }
      } else if (response.statusCode == 200) {
        // Server returned 200 OK (fresh download)
        final totalBytes = response.contentLength;
        final sink = tempFile.openWrite(mode: FileMode.write);
        int downloadedBytes = 0;
        int lastReportTime = 0;
        double lastReportProgress = -1.0;

        await for (final chunk in response) {
          if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
            await sink.close();
            if (await tempFile.exists()) await tempFile.delete();
            return;
          }
          sink.add(chunk);
          downloadedBytes += chunk.length;
          if (totalBytes > 0) {
            final currentProgress = downloadedBytes / totalBytes;
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - lastReportTime >= 100 || (currentProgress - lastReportProgress).abs() >= 0.01 || currentProgress >= 1.0) {
              lastReportTime = now;
              lastReportProgress = currentProgress;
              onProgress(currentProgress.clamp(0.0, 1.0));
            }
          }
        }
        await sink.close();

        if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
          if (await tempFile.exists()) await tempFile.delete();
          return;
        }

        if (totalBytes <= 0 || downloadedBytes >= totalBytes) {
          await _safeMoveFile(tempFile, file);
          onProgress(1.0);
        }
      }
    } catch (e) {
      if (_cancelledKeys.contains(electionName) || _cancelledKeys.contains(lockKey)) {
        debugPrint("Download cancelled for $lockKey.");
      } else {
        rethrow;
      }
    } finally {
      _activeClients.remove(lockKey);
      final updated = Set<String>.from(activeFileDownloads.value)
        ..remove(targetPath);
      activeFileDownloads.value = updated;
    }
  }

  Future<void> downloadSingleDb(
    String electionName,
    RemoteDbItem dbItem,
  ) async {
    final key = '$electionName/${dbItem.url}';
    dbDownloadProgress.value = {...dbDownloadProgress.value, key: 0.0};

    final item = remoteElections.value
        .where((e) => e.name == electionName)
        .firstOrNull;
    if (item != null) await _writeElectionMeta(item);

    final dbDir = await _dbHelper.dbDir;
    final client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

    try {
      final fileName = p.basename(Uri.parse(dbItem.url).path);
      final targetPath = p.join(dbDir, electionName, fileName);

      await _downloadFileWithRange(
        client: client,
        dbUrl: dbItem.url,
        targetPath: targetPath,
        electionName: electionName,
        onProgress: (p) {
          dbDownloadProgress.value = {...dbDownloadProgress.value, key: p};
        },
      );
    } catch (e) {
      debugPrint("Error downloading single DB $key: $e");
    } finally {
      client.close();
      final updatedMap = Map<String, double>.from(dbDownloadProgress.value)
        ..remove(key);
      dbDownloadProgress.value = updatedMap;

      await _loadLocalDatabases();
    }
  }

  Future<void> downloadElection(RemoteElectionItem item) async {
    downloadingElections.value = {...downloadingElections.value, item.name};
    downloadProgress.value = {...downloadProgress.value, item.name: 0.0};
    await _writeElectionMeta(item);
    final dbDir = await _dbHelper.dbDir;
    final client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

    try {
      final totalDbs = item.dbs.length;
      for (int i = 0; i < totalDbs; i++) {
        if (_cancelledKeys.contains(item.name)) break;
        final dbItem = item.dbs[i];
        final dbKey = '${item.name}/${dbItem.url}';
        final fileName = p.basename(Uri.parse(dbItem.url).path);
        final targetPath = p.join(dbDir, item.name, fileName);

        await _downloadFileWithRange(
          client: client,
          dbUrl: dbItem.url,
          targetPath: targetPath,
          electionName: item.name,
          onProgress: (fileProgress) {
            final overall = (i + fileProgress) / totalDbs;
            downloadProgress.value = {
              ...downloadProgress.value,
              item.name: overall.clamp(0.0, 1.0),
            };
            dbDownloadProgress.value = {
              ...dbDownloadProgress.value,
              dbKey: fileProgress.clamp(0.0, 1.0),
            };
          },
        );

        final updatedDbMap = Map<String, double>.from(dbDownloadProgress.value)
          ..remove(dbKey);
        dbDownloadProgress.value = updatedDbMap;

        // Publish each database as it lands.  Refreshing only after the whole
        // election finishes leaves the local list empty for the entire
        // download — a couple of gigabytes, and forever if it is interrupted.
        await _loadLocalDatabases();
      }
    } catch (e) {
      debugPrint("Error downloading election ${item.name}: $e");
    } finally {
      client.close();
      final updatedDownloading = Set<String>.from(downloadingElections.value)
        ..remove(item.name);
      downloadingElections.value = updatedDownloading;

      final updatedProgress = Map<String, double>.from(downloadProgress.value)
        ..remove(item.name);
      downloadProgress.value = updatedProgress;

      final updatedDbMap = Map<String, double>.from(dbDownloadProgress.value);
      for (final dbItem in item.dbs) {
        updatedDbMap.remove('${item.name}/${dbItem.url}');
      }
      dbDownloadProgress.value = updatedDbMap;

      await _loadLocalDatabases();
    }
  }

  /// Downloaded election folders that also carry the state database [dbName]
  /// (e.g. `TX.db`), i.e. the elections the current state can be compared with.
  ///
  /// Matched by state, not file name: the legacy folders call it `TX.db`, the
  /// year folders `TX-2024.db`.
  List<String> foldersContainingDb(String dbName, {String? excluding}) {
    final code = ElectionSubItem.stateCodeOf(dbName);
    if (code == null) return const [];
    return foldersContainingState(code, excluding: excluding);
  }

  /// Downloaded election folders that hold a database for [stateCode].
  List<String> foldersContainingState(String stateCode, {String? excluding}) {
    final result = <String>[];
    localElectionSubItems.value.forEach((folder, items) {
      if (folder == excluding) return;
      if (items.any((i) => !i.isNational && i.stateCode == stateCode)) {
        result.add(folder);
      }
    });
    result.sort();
    return result;
  }

  /// File name of [stateCode]'s database inside [electionFolder], if downloaded.
  String? dbNameFor(String electionFolder, String stateCode) {
    for (final item in localElectionSubItems.value[electionFolder] ?? const []) {
      if (!item.isNational && item.stateCode == stateCode) return item.dbName;
    }
    return null;
  }

  /// Party codes an election defines, the key the comparison fill modes match
  /// parties on (party ids are minted per election).
  ///
  /// Legacy folders list them in `meta.json`; year folders reveal them as
  /// their databases are opened (see [knownPartyNames]), so this can be empty
  /// for a year folder until its database has been read once.
  Set<String> partyNamesIn(String electionFolder) => {
        for (final p in localElectionMeta.value[electionFolder]?.parties ??
            const <Party>[])
          p.name,
        ...?knownPartyNames.value[electionFolder],
      };

  /// Records the party codes found in one of [electionFolder]'s databases.
  void rememberPartyNames(String electionFolder, Iterable<String> names) {
    final merged = {...?knownPartyNames.value[electionFolder], ...names};
    if (merged.length == (knownPartyNames.value[electionFolder]?.length ?? -1)) {
      return;
    }
    knownPartyNames.value = {...knownPartyNames.value, electionFolder: merged};
  }

  void setSelectedOffice(String office) {
    if (selectedOffice.value != office) selectedOffice.value = office;
  }

  /// batch(): folder and sub-item are one selection. Written separately, a
  /// listener sees the new folder paired with the *previous* folder's sub-item
  /// — e.g. election B with election A's `National`, which loads nothing.
  void selectSubItem(String electionFolder, ElectionSubItem subItem) {
    batch(() {
      selectedElectionFolder.value = electionFolder;
      selectedSubItem.value = subItem;
      selectedRemoteElection.value = null;
    });
  }

  void selectRemoteElection(RemoteElectionItem item) {
    selectedRemoteElection.value = item;
  }

  Future<void> deleteLocalElection(String electionFolder) async {
    await _dbHelper.deleteElectionFolder(electionFolder);
    await _loadLocalDatabases();
    if (localDatabases.value.isEmpty) {
      batch(() {
        selectedElectionFolder.value = null;
        selectedSubItem.value = null;
      });
    } else if (selectedElectionFolder.value == electionFolder) {
      final firstFolder = localDatabases.value.first;
      final items = localElectionSubItems.value[firstFolder];
      batch(() {
        selectedElectionFolder.value = firstFolder;
        selectedSubItem.value =
            (items != null && items.isNotEmpty) ? items.first : null;
      });
    }
  }

  Future<void> deleteLocalSubItem(
    String electionFolder,
    ElectionSubItem subItem,
  ) async {
    final dbDir = await _dbHelper.dbDir;
    final dir = Directory(p.join(dbDir, electionFolder));
    if (await dir.exists()) {
      if (subItem.isNational) {
        final nationalFile = File(p.join(dir.path, 'National.db'));
        if (await nationalFile.exists()) {
          await nationalFile.delete();
        }
      } else if (subItem.dbName != null && subItem.dbName!.isNotEmpty) {
        final stateFile = File(p.join(dir.path, subItem.dbName!));
        if (await stateFile.exists()) {
          await stateFile.delete();
        }
      }

      final remainingDbFiles = await dir
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.db'))
          .toList();

      if (remainingDbFiles.isEmpty) {
        await dir.delete(recursive: true);
      }
    }

    await _loadLocalDatabases();

    if (selectedElectionFolder.value == electionFolder &&
        selectedSubItem.value == subItem) {
      final items = localElectionSubItems.value[electionFolder];
      if (items != null && items.isNotEmpty) {
        selectedSubItem.value = items.first;
      } else if (localDatabases.value.isNotEmpty) {
        final firstFolder = localDatabases.value.first;
        final firstItems = localElectionSubItems.value[firstFolder];
        batch(() {
          selectedElectionFolder.value = firstFolder;
          selectedSubItem.value = (firstItems != null && firstItems.isNotEmpty)
              ? firstItems.first
              : null;
        });
      } else {
        batch(() {
          selectedElectionFolder.value = null;
          selectedSubItem.value = null;
        });
      }
    }
  }

  void setRemoteMode(bool isRemote) {
    isRemoteMode.value = isRemote;
    if (isRemote) {
      selectedRemoteElection.value = null;
      if (remoteElections.value.isEmpty) {
        fetchRemoteElections();
      }
    } else {
      selectedRemoteElection.value = null;
      // Re-scan rather than trust the list from the last visit: databases may
      // have finished downloading while the remote panel was open.
      _loadLocalDatabases();
    }
  }
}
