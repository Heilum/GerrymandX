import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/modules/elections/widgets/vote_breakdown.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// What the inspector shows while no cell is selected: the whole state's
/// result for the loaded contest.
///
/// A US House race is a set of seats, so it opens with the seat count and the
/// split by party before the statewide party vote. The single-winner offices
/// list their candidates, the same way a selected cell does.
class StateOverview extends StatelessWidget {
  const StateOverview({super.key});

  static const houseOffice = 'US House';

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final electionStore = context.read<ElectionStore>();

    // Its own Watch: the signals read here (contest, votes) are not tracked
    // by the inspector's, whose builder only returns this widget.
    return Watch((context) {
      final contest = dataStore.activeElection.value;
      final summary = dataStore.stateVoteSummary();
      if (summary == null) {
        return const Center(child: Text('Select a cell on the map'));
      }

      final stateName = electionStore.selectedSubItem.value?.name ?? 'State';
      final isHouse = contest?.office == houseOffice;

      return _body(context, dataStore, contest, summary, stateName, isHouse);
    });
  }

  Widget _body(
    BuildContext context,
    MapDataStore dataStore,
    ElectionContest? contest,
    PrecinctVoteSummary summary,
    String stateName,
    bool isHouse,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stateName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'STATEWIDE · ${contest?.label ?? ''}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 12),
          if (summary.population > 0)
            InfoRow('Population', formatNumber(summary.population)),
          InfoRow('Total Votes', formatNumber(summary.totalVotes)),
          if (summary.population > 0)
            InfoRow('Turnout',
                '${(summary.totalVotes / summary.population * 100).toStringAsFixed(1)}%'),
          const Divider(),
          if (isHouse) ...[
            _SeatsByParty(seats: dataStore.houseSeatsIn(summary)),
            const SizedBox(height: 16),
            _VotesByParty(summary: summary),
          ] else
            VotesByCandidate(summary: summary),
        ],
      ),
    );
  }
}

class _SeatsByParty extends StatelessWidget {
  const _SeatsByParty({required this.seats});

  final HouseSeatSummary seats;

  @override
  Widget build(BuildContext context) {
    final partiesByName = _partiesByName(context);
    final entries = seats.seatsByParty.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Seats', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        InfoRow('Total Seats', formatNumber(seats.totalSeats)),
        const SizedBox(height: 4),
        ...entries.map((entry) {
          final party = partiesByName[entry.key];
          final share =
              seats.totalSeats > 0 ? entry.value / seats.totalSeats * 100 : 0.0;
          return VoteRow(
            candidateName: party?.fullName ?? entry.key,
            party: party,
            votes: entry.value,
            sharePercent: share,
            isWinner: entry.key == entries.first.key,
          );
        }),
      ],
    );
  }
}

class _VotesByParty extends StatelessWidget {
  const _VotesByParty({required this.summary});

  final PrecinctVoteSummary summary;

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final partiesByName = _partiesByName(context);
    final entries = dataStore.partyVotesIn(summary).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Votes by Party', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ...entries.map((entry) {
          final party = partiesByName[entry.key];
          final share = summary.totalVotes > 0
              ? entry.value / summary.totalVotes * 100
              : 0.0;
          return VoteRow(
            candidateName: party?.fullName ?? entry.key,
            party: party,
            votes: entry.value,
            sharePercent: share,
            isWinner: entry.key == entries.first.key,
          );
        }),
      ],
    );
  }
}

/// Parties keyed by their short code, which is what seat and vote totals are
/// keyed by.
Map<String, Party> _partiesByName(BuildContext context) => {
      for (final p in context.read<MapDataStore>().parties.value.values)
        p.name: p,
    };
