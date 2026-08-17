import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gerrymanderx/app.dart';
import 'package:gerrymanderx/providers/app_settings_store.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
// Note: If you copied core/theme, import it here if needed

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettingsStore();
  await settings.load();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider(create: (_) => ElectionStore()),
        Provider(create: (_) => MapStateStore()),
        ProxyProvider2<ElectionStore, MapStateStore, CustomLayerStore>(
          update: (context, electionStore, mapStateStore, previous) =>
              previous ?? CustomLayerStore(electionStore, mapStateStore),
        ),
        ProxyProvider3<ElectionStore, MapStateStore, CustomLayerStore,
            MapDataStore>(
          update: (context, electionStore, mapStateStore, customLayerStore,
                  previous) =>
              previous ??
              MapDataStore(
                electionStore,
                mapStateStore,
                customLayerStore: customLayerStore,
              ),
        ),
      ],
      child: const GerrymanderXApp(),
    ),
  );
}
