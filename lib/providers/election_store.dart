import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';
import 'package:gerrymanderx/models/remote_election_item.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';

class ElectionStore {
  final localDatabases = ListSignal<String>([]);
  final localElectionSubItems = MapSignal<String, List<ElectionSubItem>>({});
  final selectedElectionFolder = Signal<String?>(null);
  final selectedSubItem = Signal<ElectionSubItem?>(null);

  final remoteElections = ListSignal<RemoteElectionItem>([]);
  final selectedRemoteElection = Signal<RemoteElectionItem?>(null);
  final downloadingElections = SetSignal<String>({});
  final downloadProgress = MapSignal<String, double>({});
  final isRemoteMode = Signal<bool>(false);
  final isLoading = Signal<bool>(false);
  final isRemoteLoading = Signal<bool>(false);

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  ElectionStore() {
    _loadLocalDatabases();
  }

  Future<void> _loadLocalDatabases() async {
    isLoading.value = true;
    try {
      final dbFolders = await _dbHelper.ensureDefaultAndListDatabases();
      localDatabases.value = dbFolders;

      final map = <String, List<ElectionSubItem>>{};
      for (final folder in dbFolders) {
        final states = await _dbHelper.getStatesInfoForElection(folder);
        final items = <ElectionSubItem>[
          const ElectionSubItem(name: 'National', isNational: true),
        ];
        for (final s in states) {
          items.add(ElectionSubItem(
            name: s['name'] ?? '',
            isNational: false,
            dbName: s['db_name'],
            stateId: int.tryParse(s['id'] ?? ''),
          ));
        }
        map[folder] = items;
      }
      localElectionSubItems.value = map;

      if (dbFolders.isNotEmpty && selectedElectionFolder.value == null && !isRemoteMode.value) {
        final firstFolder = dbFolders.first;
        selectedElectionFolder.value = firstFolder;
        final items = map[firstFolder];
        if (items != null && items.isNotEmpty) {
          selectedSubItem.value = items.first;
        }
      }
    } catch (e) {
      debugPrint("Error loading local databases: $e");
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> fetchRemoteElections() async {
    isRemoteLoading.value = true;
    final client = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    try {
      final request = await client.getUrl(Uri.parse('https://xp-oncology.cn/gerrymander/dbs.json'));
      final response = await request.close();
      if (response.statusCode == 200) {
        final jsonString = await response.transform(utf8.decoder).join();
        final List<dynamic> list = json.decode(jsonString);
        remoteElections.value = list
            .map((e) => RemoteElectionItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } else {
        debugPrint("Remote manifest returned status code: ${response.statusCode}");
      }
    } catch (e, stack) {
      debugPrint("Error fetching remote manifest: $e\n$stack");
    } finally {
      client.close();
      isRemoteLoading.value = false;
    }
  }

  Future<bool> isElectionDownloaded(RemoteElectionItem item) async {
    final dbDir = await _dbHelper.dbDir;
    for (final dbUrl in item.dbs) {
      final fileName = p.basename(Uri.parse(dbUrl).path);
      final targetPath = p.join(dbDir, item.name, fileName);
      if (!await File(targetPath).exists()) {
        return false;
      }
    }
    return true;
  }

  Future<void> downloadElection(RemoteElectionItem item) async {
    downloadingElections.value = {...downloadingElections.value, item.name};
    downloadProgress.value = {...downloadProgress.value, item.name: 0.0};
    final dbDir = await _dbHelper.dbDir;
    final client = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;

    try {
      final totalDbs = item.dbs.length;
      for (int i = 0; i < totalDbs; i++) {
        final dbUrl = item.dbs[i];
        final fileName = p.basename(Uri.parse(dbUrl).path);
        final targetPath = p.join(dbDir, item.name, fileName);
        final file = File(targetPath);
        await file.parent.create(recursive: true);
        final tempFile = File('$targetPath.tmp');

        final request = await client.getUrl(Uri.parse(dbUrl));
        final response = await request.close();
        if (response.statusCode == 200) {
          final totalBytes = response.contentLength;
          int downloadedBytes = 0;
          final sink = tempFile.openWrite();

          await for (final chunk in response) {
            sink.add(chunk);
            downloadedBytes += chunk.length;
            if (totalBytes > 0) {
              final fileProgress = downloadedBytes / totalBytes;
              final overall = (i + fileProgress) / totalDbs;
              downloadProgress.value = {
                ...downloadProgress.value,
                item.name: overall.clamp(0.0, 1.0),
              };
            }
          }
          await sink.close();

          if (await tempFile.exists()) {
            if (await file.exists()) {
              await file.delete();
            }
            await tempFile.rename(targetPath);
          }
        }
        final completedRatio = (i + 1) / totalDbs;
        downloadProgress.value = {
          ...downloadProgress.value,
          item.name: completedRatio.clamp(0.0, 1.0),
        };
      }
    } catch (e) {
      debugPrint("Error downloading election ${item.name}: $e");
    } finally {
      client.close();
      final updatedDownloading = Set<String>.from(downloadingElections.value)..remove(item.name);
      downloadingElections.value = updatedDownloading;

      final updatedProgress = Map<String, double>.from(downloadProgress.value)..remove(item.name);
      downloadProgress.value = updatedProgress;

      await _loadLocalDatabases();
    }
  }

  void selectSubItem(String electionFolder, ElectionSubItem subItem) {
    selectedElectionFolder.value = electionFolder;
    selectedSubItem.value = subItem;
    selectedRemoteElection.value = null;
  }

  void selectRemoteElection(RemoteElectionItem item) {
    selectedRemoteElection.value = item;
  }

  Future<void> deleteLocalElection(String electionFolder) async {
    await _dbHelper.deleteElectionFolder(electionFolder);
    await _loadLocalDatabases();
    if (localDatabases.value.isEmpty) {
      selectedElectionFolder.value = null;
      selectedSubItem.value = null;
    } else if (selectedElectionFolder.value == electionFolder) {
      final firstFolder = localDatabases.value.first;
      selectedElectionFolder.value = firstFolder;
      final items = localElectionSubItems.value[firstFolder];
      selectedSubItem.value = (items != null && items.isNotEmpty) ? items.first : null;
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
      if (localDatabases.value.isNotEmpty && selectedElectionFolder.value == null) {
        final firstFolder = localDatabases.value.first;
        selectedElectionFolder.value = firstFolder;
        final items = localElectionSubItems.value[firstFolder];
        selectedSubItem.value = (items != null && items.isNotEmpty) ? items.first : null;
      }
    }
  }
}
