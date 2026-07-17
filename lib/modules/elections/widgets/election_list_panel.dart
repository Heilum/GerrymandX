import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/election_store.dart';

class ElectionListPanel extends StatelessWidget {
  const ElectionListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ElectionStore>();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Watch((context) {
            return DropdownButtonFormField<bool>(
              value: store.isRemoteMode.value,
              decoration: const InputDecoration(
                labelText: 'Source',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: false, child: Text('Local')),
                DropdownMenuItem(value: true, child: Text('Remote (API)')),
              ],
              onChanged: (value) {
                if (value != null) {
                  store.setRemoteMode(value);
                }
              },
            );
          }),
        ),
        const Divider(),
        Expanded(
          child: Watch((context) {
            if (store.isLoading.value) {
              return const Center(child: CircularProgressIndicator());
            }

            if (store.isRemoteMode.value) {
              return const Center(child: Text('Remote mode not implemented yet'));
            }

            final databases = store.localDatabases.value;
            if (databases.isEmpty) {
              return const Center(child: Text('No local databases found.'));
            }

            return ListView.builder(
              itemCount: databases.length,
              itemBuilder: (context, index) {
                final dbName = databases[index];
                final isSelected = store.selectedDatabase.value == dbName;
                return ListTile(
                  title: Text(dbName),
                  selected: isSelected,
                  onTap: () {
                    // Setting the signal triggers the effect in MapDataStore
                    // which opens the DB and loads all data. No manual call needed.
                    store.selectDatabase(dbName);
                  },
                );
              },
            );
          }),
        ),
      ],
    );
  }
}
