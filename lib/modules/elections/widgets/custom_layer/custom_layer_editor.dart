import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:gerrymanderx/models/custom_layer.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/widgets/custom_layer/color_picker_popup.dart';
import 'package:gerrymanderx/modules/elections/widgets/custom_layer/editor_map_canvas.dart';
import 'package:gerrymanderx/modules/elections/widgets/vote_breakdown.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// Opens the editor for [layerId] as a modal over the main window.
Future<void> showCustomLayerEditor(BuildContext context, int layerId) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: CustomLayerEditor(layerId: layerId),
    ),
  );
}

/// Group-cell editor for one custom layer. Every change goes straight to
/// [CustomLayerStore], which persists it — there is no save button.
class CustomLayerEditor extends StatefulWidget {
  const CustomLayerEditor({super.key, required this.layerId});

  final int layerId;

  @override
  State<CustomLayerEditor> createState() => _CustomLayerEditorState();
}

class _CustomLayerEditorState extends State<CustomLayerEditor> {
  late final CustomLayerStore _store;
  late final MapDataStore _dataStore;

  int? _selectedGroupId;
  List<LayerType> _visibleLayers = [LayerType.county, LayerType.precinct];
  LayerType _interactiveLayer = LayerType.county;

  late final TextEditingController _nameController;
  Timer? _renameDebounce;

  @override
  void initState() {
    super.initState();
    _store = context.read<CustomLayerStore>();
    _dataStore = context.read<MapDataStore>();
    final layer = _store.layerById(widget.layerId);
    _nameController = TextEditingController(text: layer?.name ?? '');
    _selectedGroupId = layer?.groups.firstOrNull?.id;
  }

  @override
  void dispose() {
    _renameDebounce?.cancel();
    _flushRename();
    _nameController.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    _renameDebounce?.cancel();
    _renameDebounce = Timer(const Duration(milliseconds: 400), _flushRename);
  }

  void _flushRename() {
    final name = _nameController.text.trim();
    final layer = _store.layerById(widget.layerId);
    if (layer != null && name.isNotEmpty && name != layer.name) {
      _store.renameLayer(widget.layerId, name);
    }
  }

  // ── Layer toolbar ──

  void _toggleVisible(LayerType layer) {
    setState(() {
      final layers = List.of(_visibleLayers);
      if (layers.contains(layer)) {
        if (layers.length == 1) return; // keep something to click on
        layers.remove(layer);
      } else {
        layers.add(layer);
      }
      _visibleLayers = layers;
      if (!layers.contains(_interactiveLayer)) {
        // Finest visible layer, as the main window does.
        for (final l in const [
          LayerType.precinct,
          LayerType.county,
          LayerType.congressionalDistrict,
        ]) {
          if (layers.contains(l)) {
            _interactiveLayer = l;
            break;
          }
        }
      }
    });
  }

  // ── Group actions ──

  Future<void> _addGroup(CustomLayer layer) async {
    final title = await _promptForName(
      title: 'New group cell',
      initial: CustomLayerStore.defaultGroupTitle(layer),
    );
    if (title == null) return;
    final group = await _store.addGroup(layer.id, title: title);
    if (group != null && mounted) {
      setState(() => _selectedGroupId = group.id);
    }
  }

  Future<void> _renameGroup(GroupCell group) async {
    final title = await _promptForName(title: 'Rename group cell', initial: group.title);
    if (title == null) return;
    _store.renameGroup(group.layerId, group.id, title);
  }

  Future<void> _deleteGroup(GroupCell group) async {
    if (group.precinctIds.isNotEmpty) {
      final ok = await _confirm(
        title: 'Delete "${group.title}"?',
        message:
            'It holds ${formatNumber(group.precinctIds.length)} precincts. They will no longer belong to any group of this layer.',
      );
      if (!ok) return;
    }
    _store.deleteGroup(group.layerId, group.id);
    if (_selectedGroupId == group.id) {
      final layer = _store.layerById(group.layerId);
      setState(() => _selectedGroupId = layer?.groups.firstOrNull?.id);
    }
  }

  Future<void> _deleteLayer(CustomLayer layer) async {
    final ok = await _confirm(
      title: 'Delete layer "${layer.name}"?',
      message: 'All ${layer.groups.length} group cells will be removed. This cannot be undone.',
    );
    if (!ok) return;
    _store.deleteLayer(layer.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _onCellTap(LayerType layer, int cellId) {
    final groupId = _selectedGroupId;
    if (groupId == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Add or select a group cell first.'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    _store.toggleCellInGroup(
      widget.layerId,
      groupId,
      _dataStore.precinctIdsOfCell(layer, cellId),
    );
  }

  Future<String?> _promptForName({
    required String title,
    required String initial,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _NamePromptDialog(title: title, initial: initial),
    );
  }

  Future<bool> _confirm({required String title, required String message}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final layer = _store.layerById(widget.layerId);
      if (layer == null) {
        // Deleted underneath us (e.g. its election was removed).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
        return const SizedBox(width: 400, height: 200);
      }
      final selectedGroup =
          _selectedGroupId == null ? null : layer.groupById(_selectedGroupId!);

      return Column(
        children: [
          _Header(
            nameController: _nameController,
            onNameChanged: _onNameChanged,
            onDelete: () => _deleteLayer(layer),
            onClose: () => Navigator.of(context).pop(),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 240,
                  child: _GroupList(
                    layer: layer,
                    selectedGroupId: _selectedGroupId,
                    onSelect: (id) => setState(() => _selectedGroupId = id),
                    onAdd: () => _addGroup(layer),
                    onRename: _renameGroup,
                    onDelete: _deleteGroup,
                    onColor: (g, c) => _store.setGroupColor(layer.id, g.id, c),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      _MapToolbar(
                        visibleLayers: _visibleLayers,
                        interactiveLayer: _interactiveLayer,
                        onToggleVisible: _toggleVisible,
                        onInteractive: (l) =>
                            setState(() => _interactiveLayer = l),
                        hint: selectedGroup == null
                            ? 'Add a group cell, then click the map to fill it'
                            : 'Click to add/remove ${_interactiveLayer == LayerType.precinct ? 'precincts' : _interactiveLayer == LayerType.county ? 'counties' : 'districts'} in "${selectedGroup.title}"',
                      ),
                      Expanded(
                        child: EditorMapCanvas(
                          layer: layer,
                          selectedGroupId: _selectedGroupId,
                          visibleLayers: _visibleLayers,
                          interactiveLayer: _interactiveLayer,
                          onCellTap: _onCellTap,
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 280,
                  child: _GroupInspector(group: selectedGroup),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.nameController,
    required this.onNameChanged,
    required this.onDelete,
    required this.onClose,
  });

  final TextEditingController nameController;
  final ValueChanged<String> onNameChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.layers_outlined, size: 20),
          const SizedBox(width: 10),
          SizedBox(
            width: 340,
            child: TextField(
              controller: nameController,
              onChanged: onNameChanged,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Custom layer name',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text('Changes are saved as you make them',
              style: TextStyle(fontSize: 11, color: Colors.white38)),
          const Spacer(),
          IconButton(
            tooltip: 'Delete this layer',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

// ── Left: group cells ──

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.layer,
    required this.selectedGroupId,
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
    required this.onColor,
  });

  final CustomLayer layer;
  final int? selectedGroupId;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<GroupCell> onRename;
  final ValueChanged<GroupCell> onDelete;
  final void Function(GroupCell, Color) onColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(
            children: [
              Text('Group cells (${layer.groups.length})',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: 'Add group cell',
                icon: const Icon(Icons.add, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: onAdd,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: layer.groups.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No group cells yet.\nClick + to add one, then click counties, districts or precincts on the map to fill it.',
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
                  ),
                )
              : ListView.builder(
                  itemCount: layer.groups.length,
                  itemBuilder: (context, i) {
                    final g = layer.groups[i];
                    return _GroupRow(
                      group: g,
                      selected: g.id == selectedGroupId,
                      onTap: () => onSelect(g.id),
                      onRename: () => onRename(g),
                      onDelete: () => onDelete(g),
                      onColor: (c) => onColor(g, c),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onColor,
  });

  final GroupCell group;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<Color> onColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.secondaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              GroupColorSwatch(color: group.color, onChanged: onColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        )),
                    Text(
                      '${formatNumber(group.precinctIds.length)} precincts',
                      style: const TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: onRename,
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Centre: map toolbar ──

class _MapToolbar extends StatelessWidget {
  const _MapToolbar({
    required this.visibleLayers,
    required this.interactiveLayer,
    required this.onToggleVisible,
    required this.onInteractive,
    required this.hint,
  });

  final List<LayerType> visibleLayers;
  final LayerType interactiveLayer;
  final ValueChanged<LayerType> onToggleVisible;
  final ValueChanged<LayerType> onInteractive;
  final String hint;

  @override
  Widget build(BuildContext context) {
    const layers = [
      LayerType.county,
      LayerType.congressionalDistrict,
      LayerType.precinct,
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          const Text('Layers: ',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(width: 4),
          Wrap(
            spacing: 4,
            children: [
              for (final l in layers)
                FilterChip(
                  label: Text(l.name, style: const TextStyle(fontSize: 11)),
                  selected: visibleLayers.contains(l),
                  onSelected: (_) => onToggleVisible(l),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
          const SizedBox(width: 16),
          const Text('Interactive: ',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(width: 4),
          DropdownButton<LayerType>(
            value: visibleLayers.contains(interactiveLayer)
                ? interactiveLayer
                : visibleLayers.first,
            isDense: true,
            items: [
              for (final l in layers.where(visibleLayers.contains))
                DropdownMenuItem(
                  value: l,
                  child: Text(l.name, style: const TextStyle(fontSize: 12)),
                ),
            ],
            onChanged: (l) {
              if (l != null) onInteractive(l);
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              hint,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Right: inspector ──

class _GroupInspector extends StatelessWidget {
  const _GroupInspector({required this.group});

  final GroupCell? group;

  @override
  Widget build(BuildContext context) {
    final g = group;
    if (g == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Select a group cell', style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    return Watch((context) {
      final dataStore = context.read<MapDataStore>();
      final composition = dataStore.compositionOf(g.precinctIds);
      final votes = dataStore.aggregateVotesForPrecincts(g.precinctIds);
      final theme = Theme.of(context);

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: g.color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(g.title,
                      style: theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Composition', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            _CompositionSection(
              label: 'Whole counties',
              cells: composition.wholeCounties,
            ),
            _CompositionSection(
              label: 'Whole districts',
              cells: composition.wholeDistricts,
            ),
            InfoRow('Remaining precincts', formatNumber(composition.remainingPrecincts)),
            InfoRow('Total precincts', formatNumber(composition.totalPrecincts)),
            const Divider(),
            if (votes != null) ...[
              if (votes.population > 0)
                InfoRow('Population', formatNumber(votes.population)),
              InfoRow('Total Votes', formatNumber(votes.totalVotes)),
              if (votes.population > 0)
                InfoRow('Turnout',
                    '${(votes.totalVotes / votes.population * 100).toStringAsFixed(1)}%'),
              const Divider(),
              VotesByCandidate(summary: votes),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No precincts yet — click the map to add some.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ],
        ),
      );
    });
  }
}

/// "Whole counties · 3" with the names underneath, collapsed past a handful.
class _CompositionSection extends StatelessWidget {
  const _CompositionSection({required this.label, required this.cells});

  final String label;
  final List<GeoCell> cells;

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) return InfoRow(label, '0');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(formatNumber(cells.length),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        childrenPadding: const EdgeInsets.only(left: 8, bottom: 6),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cells.map((c) => c.name).join(', '),
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

/// Owns its controller so it outlives the dialog's exit animation.
class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  )..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    Navigator.of(context).pop(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
