import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gerrymanderx/app.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
// Note: If you copied core/theme, import it here if needed

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        Provider(create: (_) => ElectionStore()),
        Provider(create: (_) => MapStateStore()),
        ProxyProvider2<ElectionStore, MapStateStore, MapDataStore>(
          update: (context, electionStore, mapStateStore, previous) =>
              previous ?? MapDataStore(electionStore, mapStateStore),
        ),
      ],
      child: const GerrymanderXApp(),
    ),
  );
}
