import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/modules/elections/comparison_selection.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/modules/elections/widgets/vote_breakdown.dart';
import 'package:gerrymanderx/providers/custom_layer_store.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/models/geo_cell.dart';

class InspectorPanel extends StatelessWidget {
  const InspectorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<MapStateStore>();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Watch((context) {
            return DropdownButtonFormField<LayerType>(
              value: store.interactiveLayer.value,
              decoration: const InputDecoration(
                labelText: 'Interactive Layer',
                border: OutlineInputBorder(),
              ),
              items: store.visibleLayers.value.map((layer) {
                return DropdownMenuItem(
                  value: layer,
                  child: Text(layer.name.toUpperCase()),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  store.setInteractiveLayer(value);
                }
              },
            );
          }),
        ),
        const Divider(),
        Expanded(
          child: Watch((context) {
            final selectedId = store.selectedCellId.value;
            if (selectedId == null) {
              return const Center(child: Text('Select a cell on the map'));
            }

            final dataStore = context.read<MapDataStore>();
            final electionStore = context.read<ElectionStore>();
            final layer = store.interactiveLayer.value;
            final selectedCell = dataStore.cellAt(layer, selectedId);

            if (selectedCell == null) {
              return const Center(child: Text('Cell not found'));
            }

            final cell = selectedCell.cell;
            final comparisonSpec = ComparisonSelection.resolve(
              electionStore: electionStore,
              mapStore: store,
              dataStore: dataStore,
            ).spec;

            // Aggregate votes: for precincts it's direct lookup,
            // for counties/CDs/states it sums child precincts.
            final voteSummary = dataStore.aggregateVotesForRegion(layer, cell.id);

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cell.name, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    layer == LayerType.custom
                        ? 'GROUP CELL · ${context.read<CustomLayerStore>().activeLayer.value?.name ?? ''}'
                        : '${layer.name.toUpperCase()} #${cell.id}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 12),
                  if (voteSummary != null && voteSummary.population > 0) ...[
                    InfoRow('Population', formatNumber(voteSummary.population)),
                  ],
                  if (voteSummary != null) ...[
                    InfoRow('Total Votes', formatNumber(voteSummary.totalVotes)),
                    if (voteSummary.population > 0)
                      InfoRow('Turnout',
                          '${(voteSummary.totalVotes / voteSummary.population * 100).toStringAsFixed(1)}%'),
                    const Divider(),
                  ],
                  // The comparison fills replace the candidate list: the other
                  // election ran different candidates, so only party totals
                  // can be put side by side.
                  if (voteSummary != null && comparisonSpec != null)
                    _ComparisonBreakdown(
                      spec: comparisonSpec,
                      layer: layer,
                      cell: cell,
                      summary: voteSummary,
                      currentElection:
                          electionStore.selectedElectionFolder.value ?? 'This election',
                      comparisonElection:
                          store.comparisonElectionFolder.value ?? '',
                    )
                  else if (voteSummary != null)
                    VotesByCandidate(summary: voteSummary)
                  else ...[
                    const SizedBox(height: 8),
                    const Text(
                      'No vote data available',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ],
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// Side-by-side party totals for the two elections a comparison fill spans,
/// headed by the swing the map is coloured with.
class _ComparisonBreakdown extends StatelessWidget {
  const _ComparisonBreakdown({
    required this.spec,
    required this.layer,
    required this.cell,
    required this.summary,
    required this.currentElection,
    required this.comparisonElection,
  });

  final ComparisonSpec spec;
  final LayerType layer;
  final GeoCell cell;
  final PrecinctVoteSummary summary;
  final String currentElection;
  final String comparisonElection;

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final baseline = dataStore.comparisonVotesFor(layer, cell);
    final currentVotes = dataStore.partyVotesIn(summary);
    final partyColors = {
      for (final p in dataStore.parties.value.values) p.name: p.color,
    };

    // One row order for both elections, so the same party lines up.
    final partyNames = {...currentVotes.keys, ...?baseline?.votesByParty.keys}
        .toList()
      ..sort((a, b) {
        final byCurrent =
            (currentVotes[b] ?? 0).compareTo(currentVotes[a] ?? 0);
        if (byCurrent != 0) return byCurrent;
        final base = baseline?.votesByParty;
        return ((base?[b] ?? 0)).compareTo(base?[a] ?? 0);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _swingHeadline(context, dataStore, baseline),
        const SizedBox(height: 16),
        _electionGroup(
          context,
          title: currentElection,
          subtitle: 'this election',
          totalVotes: summary.totalVotes,
          votes: currentVotes,
          partyNames: partyNames,
          partyColors: partyColors,
        ),
        const SizedBox(height: 16),
        if (baseline != null)
          _electionGroup(
            context,
            title: comparisonElection,
            subtitle: 'compared with',
            totalVotes: baseline.totalVotes,
            votes: baseline.votesByParty,
            partyNames: partyNames,
            partyColors: partyColors,
          )
        else
          Text(
            'No counterpart for this ${layer.name} in $comparisonElection.',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
      ],
    );
  }

  /// One party, one number: how much its share moved, in the colour that
  /// movement paints with.
  ///
  /// Single-party mode reports the selected party. Two-party mode reports
  /// whichever of the two advanced further — the same party the map colours a
  /// cell with, since the margin can only move towards the party that gained
  /// more.
  Widget _swingHeadline(
    BuildContext context,
    MapDataStore dataStore,
    RegionPartyVotes? baseline,
  ) {
    final partyB = spec.partyBName;

    if (baseline == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            partyB == null
                ? '${spec.partyAName} share change'
                : 'Advancing party',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          const Text('—',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
        ],
      );
    }

    final deltaA = dataStore.partyShareIn(summary, spec.partyAName) -
        baseline.shareOf(spec.partyAName);

    final String label;
    final double delta;
    final Color partyColor;
    String? caption;

    if (partyB == null) {
      label = '${spec.partyAName} share change';
      delta = deltaA;
      partyColor = spec.partyAColor;
    } else {
      final deltaB =
          dataStore.partyShareIn(summary, partyB) - baseline.shareOf(partyB);
      final advancingIsA = deltaA >= deltaB;
      label = 'Advancing party: ${advancingIsA ? spec.partyAName : partyB}';
      delta = advancingIsA ? deltaA : deltaB;
      partyColor = (advancingIsA ? spec.partyAColor : spec.partyBColor) ??
          spec.partyAColor;
      // The map shades by the margin, which moves by both parties at once;
      // spelling it out keeps the fill and this number from looking at odds.
      caption = '${spec.partyAName} − $partyB margin '
          '${_formatDelta(deltaA - deltaB)}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          _formatDelta(delta),
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            height: 1.1,
            color: comparisonSwingColor(delta, partyColor, comparisonFadeColor),
          ),
        ),
        if (caption != null)
          Text(caption,
              style: const TextStyle(fontSize: 11, color: Colors.white54)),
        Text(
          'vs $comparisonElection',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
      ],
    );
  }

  Widget _electionGroup(
    BuildContext context, {
    required String title,
    required String subtitle,
    required int totalVotes,
    required Map<String, int> votes,
    required List<String> partyNames,
    required Map<String, Color> partyColors,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text('$subtitle · ${formatNumber(totalVotes)} votes',
            style: const TextStyle(fontSize: 11, color: Colors.white54)),
        const SizedBox(height: 6),
        ...partyNames.map((name) {
          final partyVotes = votes[name] ?? 0;
          final share = totalVotes > 0 ? partyVotes / totalVotes : 0.0;
          final color = partyColors[name] ?? Colors.grey;
          final inComparison =
              name == spec.partyAName || name == spec.partyBName;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontWeight: inComparison
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: inComparison ? null : Colors.white70,
                        ),
                      ),
                    ),
                    Text(formatNumber(partyVotes),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${(share * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: share,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  minHeight: 3,
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// Share movements are reported in percentage points, the same unit the fill
/// modes scale their colour by.
String _formatDelta(double delta) =>
    '${delta >= 0 ? '+' : '−'}${(delta * 100).abs().toStringAsFixed(1)}%';
