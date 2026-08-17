import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// "Votes by Candidate" list for one aggregated region, shared by the main
/// inspector and the custom-layer editor.
class VotesByCandidate extends StatelessWidget {
  const VotesByCandidate({super.key, required this.summary, this.title = 'Votes by Candidate'});

  final PrecinctVoteSummary summary;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final partyMap = dataStore.candidatePartyMap.value;
    final allCandidates = dataStore.candidates.value;
    final allParties = dataStore.parties.value;

    final entries = summary.candidateVotes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(title!, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
        ],
        ...entries.map((entry) {
          final candidate =
              allCandidates.where((c) => c.id == entry.key).firstOrNull;
          final party = allParties[partyMap[entry.key]];
          final share = summary.totalVotes > 0
              ? (entry.value / summary.totalVotes * 100)
              : 0.0;
          return VoteRow(
            candidateName: candidate?.name ?? 'Unknown',
            party: party,
            votes: entry.value,
            sharePercent: share,
            isWinner: entry.key == summary.winnerCandidateId,
          );
        }),
      ],
    );
  }
}

class VoteRow extends StatelessWidget {
  const VoteRow({
    super.key,
    required this.candidateName,
    required this.party,
    required this.votes,
    required this.sharePercent,
    required this.isWinner,
  });

  final String candidateName;
  final Party? party;
  final int votes;
  final double sharePercent;
  final bool isWinner;

  @override
  Widget build(BuildContext context) {
    final color = party?.color ?? Colors.grey;
    final partyLabel = party?.name ?? '?';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$candidateName ($partyLabel)',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              Text(formatNumber(votes),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
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

/// Label / bold value on one line.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
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
}

String formatNumber(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
