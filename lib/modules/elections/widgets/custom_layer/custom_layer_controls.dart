import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:gerrymanderx/modules/elections/widgets/custom_layer/custom_layer_editor.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';

/// App-bar controls that follow the built-in layer chips: a picker for which
/// custom layer (if any) the map shows, an Edit link for it, and [+] to make
/// a new one. Only one custom layer is displayed at a time.
class CustomLayerControls extends StatelessWidget {
  const CustomLayerControls({super.key});

  static const _labelStyle =
      TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
  static const _itemStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final electionStore = context.read<ElectionStore>();
      final store = context.read<CustomLayerStore>();

      final subItem = electionStore.selectedSubItem.value;
      if (subItem == null || subItem.isNational) return const SizedBox.shrink();

      final layers = store.layers.value;
      final activeId = store.activeLayerId.value;
      final validActive =
          layers.any((l) => l.id == activeId) ? activeId : null;

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 12),
          if (layers.isNotEmpty) ...[
            const Text('Custom: ', style: _labelStyle),
            const SizedBox(width: 4),
            SizedBox(
              width: 150,
              child: DropdownButton<int?>(
                value: validActive,
                isDense: true,
                isExpanded: true,
                // A null value shows the hint, not the "none" item.
                hint: const Text('none', style: _itemStyle),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('none', style: _itemStyle),
                  ),
                  for (final l in layers)
                    DropdownMenuItem<int?>(
                      value: l.id,
                      child: Text(l.name,
                          overflow: TextOverflow.ellipsis, style: _itemStyle),
                    ),
                ],
                onChanged: store.setActiveLayer,
              ),
            ),
            if (validActive != null) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: () => showCustomLayerEditor(context, validActive),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    'Edit',
                    style: TextStyle(
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
          ],
          IconButton(
            tooltip: 'New custom layer',
            icon: const Icon(Icons.add, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              final layer = await store.createLayer();
              if (layer == null || !context.mounted) return;
              store.setActiveLayer(layer.id);
              await showCustomLayerEditor(context, layer.id);
            },
          ),
        ],
      );
    });
  }
}
