import 'package:flutter/material.dart';
import 'package:gerrymanderx/modules/elections/widgets/election_list_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_view_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/inspector_panel.dart';

import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

class ElectionsTab extends StatefulWidget {
  const ElectionsTab({super.key});

  @override
  State<ElectionsTab> createState() => _ElectionsTabState();
}

class _ElectionsTabState extends State<ElectionsTab> {
  bool _showLeftPanel = false;
  bool _showRightPanel = false;
  
  Function? _cleanup;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<MapStateStore>();
      _cleanup = effect(() {
        if (store.selectedCellId.value != null) {
          if (mounted && !_showRightPanel) {
            setState(() {
              _showRightPanel = true;
            });
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _cleanup?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final electionStore = context.watch<ElectionStore>();
      final isRemoteMode = electionStore.isRemoteMode.value;

      return Scaffold(
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 0.0,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: isRemoteMode ? 'Reload remote elections' : 'Reset map view',
                onPressed: () {
                  if (isRemoteMode) {
                    electionStore.fetchRemoteElections();
                  } else {
                    context.read<MapStateStore>().resetViewTrigger.value++;
                  }
                },
              ),
              if (!isRemoteMode) ...[
                const SizedBox(width: 8),
                const Text('Layers: ',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(width: 4),
                Watch((context) {
                  final subItem = electionStore.selectedSubItem.value;
                  final store = context.read<MapStateStore>();

                  if (subItem?.isNational == true) {
                    return FilterChip(
                      label: const Text('state', style: TextStyle(fontSize: 11)),
                      selected: true,
                      onSelected: null,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  } else {
                    final availableLayers = LayerType.values.where((l) => l != LayerType.state).toList();
                    return Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: availableLayers.map((layer) {
                        final isVisible = store.visibleLayers.value.contains(layer);
                        return FilterChip(
                          label: Text(layer.name, style: const TextStyle(fontSize: 11)),
                          selected: isVisible,
                          onSelected: (_) => store.toggleLayerVisibility(layer),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        );
                      }).toList(),
                    );
                  }
                }),
              ],
            ],
          ),
          leading: IconButton(
            icon: Icon(_showLeftPanel ? Icons.menu_open : Icons.menu),
            onPressed: () {
              setState(() {
                _showLeftPanel = !_showLeftPanel;
              });
            },
          ),
          actions: isRemoteMode
              ? null
              : [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Fill: ',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      const SizedBox(width: 4),
                      Watch((context) {
                        final store = context.read<MapStateStore>();
                        return DropdownButton<FillMode>(
                          value: store.fillMode.value,
                          isDense: true,
                          items: FillMode.values.map((mode) {
                            return DropdownMenuItem(
                                value: mode,
                                child: Text(mode.name,
                                    style: const TextStyle(fontSize: 12)));
                          }).toList(),
                          onChanged: (mode) {
                            if (mode != null) store.setFillMode(mode);
                          },
                        );
                      }),
                      Watch((context) {
                        final store = context.read<MapStateStore>();
                        if (store.fillMode.value != FillMode.singleCandidateOpacity) {
                          return const SizedBox.shrink();
                        }

                        final dataStore = context.read<MapDataStore>();
                        final candidates = dataStore.candidates.value;
                        if (candidates.isEmpty) return const SizedBox.shrink();

                        if (store.selectedCandidateId.value == null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (store.selectedCandidateId.value == null) {
                              store.selectedCandidateId.value = candidates.first.id;
                            }
                          });
                        }

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 8),
                            const Text('Candidate: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            const SizedBox(width: 4),
                            DropdownButton<int>(
                              value: store.selectedCandidateId.value ?? candidates.first.id,
                              isDense: true,
                              items: candidates.map((c) {
                                return DropdownMenuItem(
                                    value: c.id,
                                    child: Text(c.name,
                                        style: const TextStyle(fontSize: 12)));
                              }).toList(),
                              onChanged: (id) {
                                if (id != null) store.selectedCandidateId.value = id;
                              },
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(_showRightPanel ? Icons.info_outline : Icons.info),
                    onPressed: () {
                      setState(() {
                        _showRightPanel = !_showRightPanel;
                      });
                    },
                  ),
                ],
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_showLeftPanel)
              const SizedBox(
                width: 250,
                child: ElectionListPanel(),
              ),
            if (_showLeftPanel)
              const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: isRemoteMode
                  ? const SizedBox.shrink()
                  : const MapViewPanel(),
            ),
            if (_showRightPanel && !isRemoteMode)
              const VerticalDivider(width: 1, thickness: 1),
            if (_showRightPanel && !isRemoteMode)
              const SizedBox(
                width: 300,
                child: InspectorPanel(),
              ),
          ],
        ),
      );
    });
  }
}
