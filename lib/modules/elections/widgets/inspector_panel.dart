import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
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
            final cellIdx = dataStore.cellIndex.value;
            final selectedCell = cellIdx[selectedId];

            if (selectedCell == null) {
              return const Center(child: Text('Cell not found'));
            }

            final cell = selectedCell.cell;
            final partyMap = dataStore.candidatePartyMap.value;
            final allCandidates = dataStore.candidates.value;
            final layer = store.interactiveLayer.value;

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
                  Text('${layer.name.toUpperCase()} #${cell.id}',
                      style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 12),
                  if (voteSummary != null && voteSummary.population > 0) ...[
                    _infoRow('Population', _formatNumber(voteSummary.population)),
                  ],
                  if (voteSummary != null) ...[
                    _infoRow('Total Votes', _formatNumber(voteSummary.totalVotes)),
                    if (voteSummary.population > 0)
                      _infoRow('Turnout',
                          '${(voteSummary.totalVotes / voteSummary.population * 100).toStringAsFixed(1)}%'),
                    const Divider(),
                    Text('Votes by Candidate',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    ...voteSummary.candidateVotes.entries.map((entry) {
                      final candidate = allCandidates
                          .where((c) => c.id == entry.key).firstOrNull;
                      final partyId = partyMap[entry.key] ?? 0;
                      final isWinner = entry.key == voteSummary.winnerCandidateId;
                      final share = voteSummary.totalVotes > 0
                          ? (entry.value / voteSummary.totalVotes * 100)
                          : 0.0;
                      return _voteRow(
                        candidateName: candidate?.name ?? 'Unknown',
                        partyId: partyId,
                        votes: entry.value,
                        sharePercent: share,
                        isWinner: isWinner,
                      );
                    }),
                  ] else ...[
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

  String _formatNumber(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _voteRow({
    required String candidateName,
    required int partyId,
    required int votes,
    required double sharePercent,
    required bool isWinner,
  }) {
    const partyNames = {1: 'D', 2: 'R', 3: 'L', 4: 'G', 5: 'I', 6: 'W', 7: 'O'};
    const partyColors = {
      1: Color(0xFF2166AC),
      2: Color(0xFFB2182B),
      3: Color(0xFFFFC107),
      4: Color(0xFF4CAF50),
      5: Color(0xFF9E9E9E),
    };

    final color = partyColors[partyId] ?? Colors.grey;
    final partyLabel = partyNames[partyId] ?? '?';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12, height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$candidateName ($partyLabel)',
                  style: TextStyle(
                    fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              Text('$votes', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          LinearProgressIndicator(
            value: sharePercent / 100,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 4,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${sharePercent.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}
