import 'package:flutter/material.dart';
import 'package:gerrymanderx/modules/elections/widgets/election_list_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_view_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/inspector_panel.dart';

import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

class ElectionsTab extends StatefulWidget {
  const ElectionsTab({super.key});

  @override
  State<ElectionsTab> createState() => _ElectionsTabState();
}

class _ElectionsTabState extends State<ElectionsTab> {
  bool _showLeftPanel = false;
  bool _showRightPanel = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0.0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset map view',
              onPressed: () {
                context.read<MapStateStore>().resetViewTrigger.value++;
              },
            ),
            const SizedBox(width: 8),
            const Text('Layers: ',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(width: 4),
            Watch((context) {
              final store = context.read<MapStateStore>();
              return Wrap(
                spacing: 4,
                runSpacing: 4,
                children: LayerType.values.map((layer) {
                  final isVisible =
                      store.visibleLayers.value.contains(layer);
                  return FilterChip(
                    label: Text(layer.name,
                        style: const TextStyle(fontSize: 11)),
                    selected: isVisible,
                    onSelected: (_) => store.toggleLayerVisibility(layer),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              );
            }),
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
        actions: [
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
          const Expanded(
            child: MapViewPanel(),
          ),
          if (_showRightPanel)
            const VerticalDivider(width: 1, thickness: 1),
          if (_showRightPanel)
            const SizedBox(
              width: 300,
              child: InspectorPanel(),
            ),
        ],
      ),
    );
  }
}
