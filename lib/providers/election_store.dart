import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/core/database/database_helper.dart';

class ElectionStore {
  final localDatabases = ListSignal<String>([]);
  final selectedDatabase = Signal<String?>(null);
  final isRemoteMode = Signal<bool>(false);
  final isLoading = Signal<bool>(false);

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  ElectionStore() {
    _loadLocalDatabases();
  }

  Future<void> _loadLocalDatabases() async {
    isLoading.value = true;
    try {
      final dbFiles = await _dbHelper.ensureDefaultAndListDatabases();
      localDatabases.value = dbFiles;
      if (dbFiles.isNotEmpty && selectedDatabase.value == null) {
        selectedDatabase.value = dbFiles.first;
      }
    } catch (e) {
      debugPrint("Error loading databases: $e");
    } finally {
      isLoading.value = false;
    }
  }

  void selectDatabase(String dbName) {
    selectedDatabase.value = dbName;
  }

  void setRemoteMode(bool isRemote) {
    isRemoteMode.value = isRemote;
  }
}
