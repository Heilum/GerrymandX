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
          child: ListTileTheme(
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: Watch((context) {
              final isRemote = store.isRemoteMode.value;
              if (isRemote) {
                return _buildRemoteList(context, store);
              } else {
                return _buildLocalList(context, store);
              }
            }),
          ),
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
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            collapsedShape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            title: Text(
              folder,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
              tooltip: 'Delete Election',
              onPressed: () async {
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

                if (confirm == true && context.mounted) {
                  await store.deleteLocalElection(folder);
                }
              },
            ),
            children: subItems.map((subItem) {
              final isSelected = selectedFolder == folder &&
                  selectedSub == subItem &&
                  store.selectedRemoteElection.value == null;

              return ListTile(
                contentPadding: const EdgeInsets.only(left: 32.0, right: 8.0),
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
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.grey),
                  tooltip: 'Delete ${subItem.name}',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Delete ${subItem.name}'),
                        content: Text('Are you sure you want to delete "${subItem.name}" from "$folder"?'),
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

                    if (confirm == true && context.mounted) {
                      await store.deleteLocalSubItem(folder, subItem);
                    }
                  },
                ),
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

        return ExpansionTile(
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          collapsedShape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
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
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Cancel',
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Cancel Download'),
                          content: Text('Are you sure you want to cancel downloading "${item.name}"?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('No'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('Yes'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        store.cancelElectionDownload(item.name);
                      }
                    },
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
                      'Downloaded',
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
                  child: const Text('Download All'),
                );
              },
            );
          }),
          children: item.dbs.map((dbItem) {
            final dbKey = '${item.name}/${dbItem.url}';
            return Padding(
              padding: const EdgeInsets.only(left: 16.0),
              child: ListTile(
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                title: Text(dbItem.name),
                trailing: Watch((context) {
                  final dbProgress = store.dbDownloadProgress.value[dbKey];
                  final isDownloadingDb = dbProgress != null;
                  if (isDownloadingDb) {
                    final percentText = '${(dbProgress * 100).toInt()}%';
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            value: dbProgress > 0 ? dbProgress : null,
                            strokeWidth: 2.0,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          percentText,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Cancel',
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Cancel Download'),
                                content: Text('Are you sure you want to cancel downloading "${dbItem.name}"?'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(false),
                                    child: const Text('No'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(true),
                                    child: const Text('Yes'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              store.cancelSingleDbDownload(item.name, dbItem);
                            }
                          },
                        ),
                      ],
                    );
                  }

                  return FutureBuilder<bool>(
                    future: store.isDbFileDownloaded(item.name, dbItem.url),
                    builder: (context, snapshot) {
                      final isDownloaded = snapshot.data ?? false;
                      if (isDownloaded) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8.0),
                          child: Text(
                            'Downloaded',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
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
                          store.downloadSingleDb(item.name, dbItem);
                        },
                        child: const Text('Download'),
                      );
                    },
                  );
                }),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
