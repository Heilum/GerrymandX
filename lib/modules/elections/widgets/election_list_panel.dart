import 'package:flutter/material.dart';
import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/models/remote_election_item.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ElectionListPanel extends StatelessWidget {
  const ElectionListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ElectionStore>();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: DropdownButtonFormField<bool>(
            value: store.isRemoteMode.value,
            decoration: const InputDecoration(
              labelText: 'Source',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            items: const [
              DropdownMenuItem(
                value: false,
                child: Text('Local'),
              ),
              DropdownMenuItem(
                value: true,
                child: Text('Remote (API)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) {
                store.setRemoteMode(val);
              }
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Watch((context) {
            final isRemote = store.isRemoteMode.value;
            if (isRemote) {
              return _buildRemoteList(context, store);
            } else {
              return _buildLocalList(context, store);
            }
          }),
        ),
      ],
    );
  }

  Widget _buildLocalList(BuildContext context, ElectionStore store) {
    final folders = store.localDatabases.value;
    if (folders.isEmpty) {
      return const Center(child: Text('No local databases found.'));
    }

    final subItemsMap = store.localElectionSubItems.value;
    final selectedFolder = store.selectedElectionFolder.value;
    final selectedSub = store.selectedSubItem.value;

    return ListView.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        final subItems = subItemsMap[folder] ?? [];

        return GestureDetector(
          onSecondaryTapDown: (details) async {
            final selected = await showMenu<String>(
              context: context,
              position: RelativeRect.fromLTRB(
                details.globalPosition.dx,
                details.globalPosition.dy,
                details.globalPosition.dx + 1,
                details.globalPosition.dy + 1,
              ),
              items: const [
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red, size: 18),
                      SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            );

            if (selected == 'delete' && context.mounted) {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete Election'),
                  content: Text('Are you sure you want to delete "$folder"?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                await store.deleteLocalElection(folder);
              }
            }
          },
          child: ExpansionTile(
            key: PageStorageKey<String>(folder),
            initiallyExpanded: true,
            title: Text(
              folder,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            children: subItems.map((subItem) {
              final isSelected = selectedFolder == folder &&
                  selectedSub == subItem &&
                  store.selectedRemoteElection.value == null;

              return ListTile(
                contentPadding: const EdgeInsets.only(left: 32.0, right: 16.0),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                title: Text(
                  subItem.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                selected: isSelected,
                onTap: () {
                  store.selectSubItem(folder, subItem);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildRemoteList(BuildContext context, ElectionStore store) {
    if (store.isRemoteLoading.value) {
      return const Center(child: CircularProgressIndicator());
    }

    final remoteItems = store.remoteElections.value;
    if (remoteItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('No remote elections found.'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => store.fetchRemoteElections(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: remoteItems.length,
      itemBuilder: (context, index) {
        final item = remoteItems[index];
        final isSelected = store.selectedRemoteElection.value?.name == item.name;

        final tile = ListTile(
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          title: Text(item.name),
          selected: isSelected,
          onTap: () {
            store.selectRemoteElection(item);
          },
          trailing: Watch((context) {
            final isDownloading = store.downloadingElections.value.contains(item.name);
            if (isDownloading) {
              final progress = store.downloadProgress.value[item.name];
              final percentText = progress != null ? '${(progress * 100).toInt()}%' : '0%';
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      value: (progress != null && progress > 0) ? progress : null,
                      strokeWidth: 2.5,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    percentText,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              );
            }

            return FutureBuilder<bool>(
              future: store.isElectionDownloaded(item),
              builder: (context, snapshot) {
                final isDownloaded = snapshot.data ?? false;
                if (isDownloaded) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(
                      '已下载',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  );
                }

                return ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    store.downloadElection(item);
                  },
                  child: const Text('下载'),
                );
              },
            );
          }),
        );

        if (item.description.isNotEmpty) {
          return Tooltip(
            message: item.description,
            child: tile,
          );
        }
        return tile;
      },
    );
  }
}
