import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_painter.dart';

class MapViewPanel extends StatelessWidget {
  const MapViewPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<MapStateStore>();

    return Column(
      children: [
        // Header Config Area
        Container(
          color: Theme.of(context).cardColor,
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              const Text('Visible Layers: ', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Watch((context) {
                return Wrap(
                  spacing: 4,
                  children: LayerType.values.map((layer) {
                    final isVisible = store.visibleLayers.value.contains(layer);
                    return FilterChip(
                      label: Text(layer.name),
                      selected: isVisible,
                      onSelected: (_) => store.toggleLayerVisibility(layer),
                    );
                  }).toList(),
                );
              }),
              const Spacer(),
              const Text('Fill Mode: ', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Watch((context) {
                return DropdownButton<FillMode>(
                  value: store.fillMode.value,
                  items: FillMode.values.map((mode) {
                    return DropdownMenuItem(
                      value: mode,
                      child: Text(mode.name),
                    );
                  }).toList(),
                  onChanged: (mode) {
                    if (mode != null) store.setFillMode(mode);
                  },
                );
              })
            ],
          ),
        ),
        const Divider(height: 1),
        // Map Canvas
        Expanded(
          child: Container(
            color: const Color(0xFF1A1A2E),
            child: Watch((context) {
              final dataStore = context.read<MapDataStore>();

              return LayoutBuilder(
                builder: (context, constraints) {
                  final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

                  if (dataStore.isLoadingData.value) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (dataStore.overallBounds.value == null) {
                    return const Center(
                      child: Text(
                        'Select an election to view the map',
                        style: TextStyle(color: Colors.white54, fontSize: 16),
                      ),
                    );
                  }

                  return MouseRegion(
                    onHover: (event) {
                      final hitId = dataStore.hitTest(
                        event.localPosition, canvasSize, store.interactiveLayer.value,
                      );
                      store.hoveredCellId.value = hitId;
                    },
                    onExit: (_) {
                      store.hoveredCellId.value = null;
                    },
                    child: GestureDetector(
                      onTapUp: (details) {
                        final hitId = dataStore.hitTest(
                          details.localPosition, canvasSize, store.interactiveLayer.value,
                        );
                        store.selectedCellId.value = hitId;
                      },
                      child: CustomPaint(
                        painter: MapPainter(
                          dataStore: dataStore,
                          visibleLayers: store.visibleLayers.value,
                          interactiveLayer: store.interactiveLayer.value,
                          fillMode: store.fillMode.value,
                          selectedCellId: store.selectedCellId.value,
                          hoveredCellId: store.hoveredCellId.value,
                          singleCandidateId: store.selectedCandidateId.value,
                        ),
                        size: canvasSize,
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ),
      ],
    );
  }
}
