import 'package:flutter/material.dart';
import 'package:gerrymanderx/modules/elections/widgets/custom_layer/custom_layer_controls.dart';
import 'package:gerrymanderx/modules/elections/widgets/election_list_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/fill_mode_controls.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_view_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/inspector_panel.dart';

import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
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
                tooltip: isRemoteMode
                    ? 'Reload remote elections'
                    : 'Reload local elections and reset map view',
                onPressed: () {
                  if (isRemoteMode) {
                    electionStore.fetchRemoteElections();
                  } else {
                    electionStore.refreshLocalDatabases();
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
                    // The custom layer is picked from its own dropdown, not
                    // toggled as a chip.
                    final availableLayers = LayerType.values
                        .where((l) => l.isBuiltInStateLayer)
                        .toList();
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
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
                        ),
                        const CustomLayerControls(),
                      ],
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
                  const FillModeControls(),
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
