import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/modules/elections/comparison_selection.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// App-bar controls for the map fill: the mode itself plus whatever that mode
/// needs picked (a candidate, or an election and one/two parties).
class FillModeControls extends StatelessWidget {
  const FillModeControls({super.key});

  static const _labelStyle =
      TextStyle(fontWeight: FontWeight.bold, fontSize: 12);
  static const _itemStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final electionStore = context.read<ElectionStore>();
      final mapStore = context.read<MapStateStore>();

      final comparableElections = ComparisonSelection.comparableElections(
        electionStore,
        electionStore.selectedSubItem.value,
      );
      final mode = mapStore.fillMode.value;

      // The comparison modes only exist while the same state is available in
      // more than one election; a change of selection can take that away.
      if (mode.isComparison && comparableElections.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mapStore.fillMode.peek().isComparison) {
            mapStore.setFillMode(FillMode.winnerOpaque);
          }
        });
      }

      final modes = FillMode.values
          .where((m) => !m.isComparison || comparableElections.isNotEmpty)
          .toList();

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Fill: ', style: _labelStyle),
          const SizedBox(width: 4),
          DropdownButton<FillMode>(
            value: modes.contains(mode) ? mode : FillMode.winnerOpaque,
            isDense: true,
            items: modes
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(m.label, style: _itemStyle),
                    ))
                .toList(),
            onChanged: (m) {
              if (m != null) mapStore.setFillMode(m);
            },
          ),
          if (mode != FillMode.none) const _FilledLayerPicker(),
          if (mode == FillMode.singleCandidateOpacity) const _CandidatePicker(),
          if (mode.isComparison && comparableElections.isNotEmpty)
            _ComparisonPickers(comparableElections: comparableElections),
        ],
      );
    });
  }
}

/// Which visible layer gets the fill. Every other layer keeps its borders
/// only, so a choropleth of one granularity can be read under the boundaries
/// of another.
class _FilledLayerPicker extends StatelessWidget {
  const _FilledLayerPicker();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final store = context.read<MapStateStore>();
      final layers = store.visibleLayers.value;
      if (layers.length < 2) return const SizedBox.shrink();

      final filled = store.filledLayer.value;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 8),
          const Text('Filled layer: ', style: FillModeControls._labelStyle),
          const SizedBox(width: 4),
          DropdownButton<LayerType>(
            value: layers.contains(filled) ? filled : layers.first,
            isDense: true,
            items: layers
                .map((l) => DropdownMenuItem(
                      value: l,
                      child: Text(l.name, style: FillModeControls._itemStyle),
                    ))
                .toList(),
            onChanged: (l) {
              if (l != null) store.setFilledLayer(l);
            },
          ),
        ],
      );
    });
  }
}

/// Candidate to shade by, for [FillMode.singleCandidateOpacity].
class _CandidatePicker extends StatelessWidget {
  const _CandidatePicker();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final store = context.read<MapStateStore>();
      final candidates = context.read<MapDataStore>().candidates.value;
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
          const Text('Candidate: ', style: FillModeControls._labelStyle),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: store.selectedCandidateId.value ?? candidates.first.id,
            isDense: true,
            items: candidates
                .map((c) => DropdownMenuItem(
                      value: c.id,
                      child:
                          Text(c.name, style: FillModeControls._itemStyle),
                    ))
                .toList(),
            onChanged: (id) {
              if (id != null) store.selectedCandidateId.value = id;
            },
          ),
        ],
      );
    });
  }
}

/// Election and party pickers for the two comparison fill modes.
///
/// Parties missing from the comparison election stay selectable and are
/// marked: picking one is how the user finds out, and the map notice then says
/// what to change.
class _ComparisonPickers extends StatelessWidget {
  const _ComparisonPickers({required this.comparableElections});

  final List<String> comparableElections;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final electionStore = context.read<ElectionStore>();
      final mapStore = context.read<MapStateStore>();
      final dataStore = context.read<MapDataStore>();

      final mode = mapStore.fillMode.value;
      final twoParty = mode == FillMode.twoPartyComparison;
      final parties = dataStore.parties.value.values.toList();

      final folder = mapStore.comparisonElectionFolder.value;
      final validFolder =
          folder != null && comparableElections.contains(folder) ? folder : null;
      final baselineParties =
          validFolder == null ? const <String>{} : electionStore.partyNamesIn(validFolder);

      _scheduleDefaults(
        mapStore: mapStore,
        parties: parties,
        baselineParties: baselineParties,
        validFolder: validFolder,
        twoParty: twoParty,
      );

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 8),
          const Text('vs: ', style: FillModeControls._labelStyle),
          const SizedBox(width: 4),
          SizedBox(
            width: 170,
            child: DropdownButton<String>(
              value: validFolder,
              isDense: true,
              isExpanded: true,
              hint: const Text('election', style: FillModeControls._itemStyle),
              items: comparableElections
                  .map((f) => DropdownMenuItem(
                        value: f,
                        child: Text(f,
                            overflow: TextOverflow.ellipsis,
                            style: FillModeControls._itemStyle),
                      ))
                  .toList(),
              onChanged: (f) => mapStore.comparisonElectionFolder.value = f,
            ),
          ),
          _partyPicker(
            label: twoParty ? 'Party A: ' : 'Party: ',
            selectedId: mapStore.comparisonPartyAId.value,
            parties: parties,
            baselineParties: baselineParties,
            onChanged: (id) => mapStore.comparisonPartyAId.value = id,
          ),
          if (twoParty)
            _partyPicker(
              label: 'Party B: ',
              selectedId: mapStore.comparisonPartyBId.value,
              parties: parties,
              baselineParties: baselineParties,
              onChanged: (id) => mapStore.comparisonPartyBId.value = id,
            ),
        ],
      );
    });
  }

  Widget _partyPicker({
    required String label,
    required String? selectedId,
    required List<Party> parties,
    required Set<String> baselineParties,
    required ValueChanged<String?> onChanged,
  }) {
    final ids = parties.map((p) => p.id).toSet();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 8),
        Text(label, style: FillModeControls._labelStyle),
        const SizedBox(width: 4),
        DropdownButton<String>(
          value: ids.contains(selectedId) ? selectedId : null,
          isDense: true,
          hint: const Text('party', style: FillModeControls._itemStyle),
          items: parties.map((p) {
            final missing =
                baselineParties.isNotEmpty && !baselineParties.contains(p.name);
            return DropdownMenuItem(
              value: p.id,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: p.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    missing ? '${p.name} (n/a)' : p.name,
                    style: FillModeControls._itemStyle.copyWith(
                      color: missing ? Colors.white38 : null,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// Fills in whatever the user has not picked yet, preferring parties that
  /// exist in both elections so the mode draws something straight away.
  void _scheduleDefaults({
    required MapStateStore mapStore,
    required List<Party> parties,
    required Set<String> baselineParties,
    required String? validFolder,
    required bool twoParty,
  }) {
    final ids = parties.map((p) => p.id).toSet();
    final partyA = mapStore.comparisonPartyAId.value;
    final partyB = mapStore.comparisonPartyBId.value;
    final needed = (validFolder == null && comparableElections.isNotEmpty) ||
        (validFolder != null &&
            parties.isNotEmpty &&
            (!ids.contains(partyA) ||
                (twoParty && (!ids.contains(partyB) || partyB == partyA))));
    if (!needed) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mapStore.fillMode.peek().isComparison) return;

      if (validFolder == null) {
        if (comparableElections.isNotEmpty) {
          mapStore.comparisonElectionFolder.value = comparableElections.first;
        }
        // Party defaults wait for the next pass, once the election is known.
        return;
      }

      bool shared(Party p) =>
          baselineParties.isEmpty || baselineParties.contains(p.name);

      var partyAId = mapStore.comparisonPartyAId.peek();
      if (!ids.contains(partyAId)) {
        partyAId = (parties.where(shared).firstOrNull ?? parties.firstOrNull)?.id;
        mapStore.comparisonPartyAId.value = partyAId;
      }

      if (!twoParty) return;
      final partyBId = mapStore.comparisonPartyBId.peek();
      if (!ids.contains(partyBId) || partyBId == partyAId) {
        final candidates = parties.where((p) => p.id != partyAId);
        mapStore.comparisonPartyBId.value =
            (candidates.where(shared).firstOrNull ?? candidates.firstOrNull)?.id;
      }
    });
  }
}
