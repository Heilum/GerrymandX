import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/modules/elections/widgets/vote_breakdown.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// What the inspector shows while no cell is selected: the whole state's
/// result for the loaded contest.
///
/// A US House race is a set of seats, so it opens with the seat count and the
/// split by party before the statewide party vote. The single-winner offices
/// list their candidates, the same way a selected cell does.
///
/// In a comparison fill mode the election compared against gets a section of
/// its own below, laid out the same way.
class StateOverview extends StatelessWidget {
  const StateOverview({super.key});

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final electionStore = context.read<ElectionStore>();
    final mapStore = context.read<MapStateStore>();

    // Its own Watch: the signals read here (contest, votes) are not tracked
    // by the inspector's, whose builder only returns this widget.
    return Watch((context) {
      final contest = dataStore.activeElection.value;
      final summary = dataStore.stateVoteSummary();
      if (summary == null) {
        return const Center(child: Text('Select a cell on the map'));
      }

      final stateName = electionStore.selectedSubItem.value?.name ?? 'State';
      final comparing = mapStore.fillMode.value.isComparison;
      final current = _CurrentElection(
        contest: contest,
        summary: summary,
        seats: contest?.office == MapDataStore.houseOffice
            ? dataStore.houseSeatsIn(summary)
            : null,
      );

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stateName, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              comparing ? 'STATEWIDE' : 'STATEWIDE · ${contest?.label ?? ''}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 12),
            if (!comparing)
              current
            else ...[
              _SectionTitle(
                title: [
                  electionStore.selectedElectionFolder.value ?? 'This election',
                  ?contest?.label,
                ].join(' '),
                subtitle: 'this election',
              ),
              current,
              const Divider(height: 32),
              _SectionTitle(
                title: [
                  mapStore.comparisonElectionFolder.value ?? '',
                  ?dataStore.comparisonContest.value?.label,
                ].join(' '),
                subtitle: 'compared election',
              ),
              _ComparedElection(
                contest: dataStore.comparisonContest.value,
                totals: dataStore.comparisonTotalsInView(),
                isLoading: dataStore.isLoadingComparison.value,
              ),
            ],
          ],
        ),
      );
    });
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text(subtitle,
              style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
    );
  }
}

/// The loaded contest's statewide result.
class _CurrentElection extends StatelessWidget {
  const _CurrentElection({
    required this.contest,
    required this.summary,
    required this.seats,
  });

  final ElectionContest? contest;
  final PrecinctVoteSummary summary;

  /// Set for a US House race.
  final HouseSeatSummary? seats;

  @override
  Widget build(BuildContext context) {
    final dataStore = context.read<MapDataStore>();
    final partiesByName = {
      for (final p in dataStore.parties.value.values) p.name: p,
    };
    final seats = this.seats;
    final votes = dataStore.partyVotesIn(summary);
    final winner = dataStore.candidates.value
        .where((c) => c.id == summary.winnerCandidateId)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoRow('Total Votes', formatNumber(summary.totalVotes)),
        const Divider(),
        if (seats != null) ...[
          // Under "Only See" the race is one district's: one seat, so who
          // took it says more than a seat count.
          if (dataStore.focusPrecincts.value != null)
            _Winner(
              name: winner?.name,
              party: dataStore.parties.value[winner?.partyId],
              votes: summary.winnerVotes,
              totalVotes: summary.totalVotes,
            )
          else
            _SeatsByParty(seats: seats, partiesByName: partiesByName),
          const SizedBox(height: 16),
          _VotesByParty(
            votes: votes,
            totalVotes: summary.totalVotes,
            partiesByName: partiesByName,
            candidates: {
              for (final party in votes.keys)
                party: dataStore.partyCandidatesIn(summary, party),
            },
          ),
        ] else
          VotesByCandidate(summary: summary),
      ],
    );
  }
}

/// The comparison election's result over the same area, in its own parties'
/// names and colours.
class _ComparedElection extends StatelessWidget {
  const _ComparedElection({
    required this.contest,
    required this.totals,
    required this.isLoading,
  });

  final ElectionContest? contest;
  final ComparisonStateTotals? totals;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final totals = this.totals;
    if (totals == null) {
      return Text(
        isLoading ? 'Reading…' : 'Select the election to compare against.',
        style: const TextStyle(color: Colors.white54),
      );
    }

    final votes = totals.votes;
    final seats = totals.seats;
    final isHouse = contest?.office == MapDataStore.houseOffice;
    final focused = context.read<MapDataStore>().focusPrecincts.value != null;
    final names = candidateNamesByParty(votes);
    final leader = _leaderOf(votes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoRow('Total Votes', formatNumber(votes.totalVotes)),
        const Divider(),
        if (isHouse && focused) ...[
          _Winner(
            name: leader?.name,
            party: totals.partiesByName[leader?.party],
            votes: leader?.votes ?? 0,
            totalVotes: votes.totalVotes,
          ),
          const SizedBox(height: 16),
        ] else if (seats != null) ...[
          _SeatsByParty(seats: seats, partiesByName: totals.partiesByName),
          const SizedBox(height: 16),
        ],
        if (isHouse)
          _VotesByParty(
            votes: votes.votesByParty,
            totalVotes: votes.totalVotes,
            partiesByName: totals.partiesByName,
            candidates: names,
          )
        else
          _VotesByCandidateName(
            votes: votes,
            partiesByName: totals.partiesByName,
          ),
      ],
    );
  }
}

/// The candidate with the most votes in [votes], if any.
({String name, String party, int votes})? _leaderOf(RegionPartyVotes votes) {
  ({String name, String party, int votes})? best;
  votes.candidateVotesByParty.forEach((party, byName) {
    byName.forEach((name, n) {
      if (best == null || n > best!.votes) {
        best = (name: name, party: party, votes: n);
      }
    });
  });
  return best;
}

/// Who took the one seat of the district being looked at on its own.
class _Winner extends StatelessWidget {
  const _Winner({
    required this.name,
    required this.party,
    required this.votes,
    required this.totalVotes,
  });

  final String? name;
  final Party? party;
  final int votes;
  final int totalVotes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Winner', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (name == null)
          const Text('—', style: TextStyle(color: Colors.white54))
        else
          VoteRow(
            candidateName: name!,
            party: party,
            votes: votes,
            sharePercent: totalVotes > 0 ? votes / totalVotes * 100 : 0.0,
            isWinner: true,
          ),
      ],
    );
  }
}

class _SeatsByParty extends StatelessWidget {
  const _SeatsByParty({required this.seats, required this.partiesByName});

  final HouseSeatSummary seats;
  final Map<String, Party> partiesByName;

  @override
  Widget build(BuildContext context) {
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
  const _VotesByParty({
    required this.votes,
    required this.totalVotes,
    required this.partiesByName,
    this.candidates = const {},
  });

  /// {party code: votes}
  final Map<String, int> votes;
  final int totalVotes;
  final Map<String, Party> partiesByName;

  /// {party code: candidate names, strongest first}, named under each row.
  final Map<String, List<String>> candidates;

  @override
  Widget build(BuildContext context) {
    final entries = votes.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Votes by Party', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ...entries.map((entry) {
          final party = partiesByName[entry.key];
          final share = totalVotes > 0 ? entry.value / totalVotes * 100 : 0.0;
          final names = candidates[entry.key];
          return VoteRow(
            candidateName: party?.fullName ?? entry.key,
            party: party,
            votes: entry.value,
            sharePercent: share,
            isWinner: entry.key == entries.first.key,
            detail: names == null ? null : candidateListLabel(names),
          );
        }),
      ],
    );
  }
}

/// "Votes by Candidate" for the comparison election, whose candidates are
/// known by name and party only.
class _VotesByCandidateName extends StatelessWidget {
  const _VotesByCandidateName({required this.votes, required this.partiesByName});

  final RegionPartyVotes votes;
  final Map<String, Party> partiesByName;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final byParty in votes.candidateVotesByParty.entries)
        for (final candidate in byParty.value.entries)
          if (candidate.value > 0)
            (name: candidate.key, party: byParty.key, votes: candidate.value),
    ]..sort((a, b) => b.votes.compareTo(a.votes));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Votes by Candidate',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final row in rows)
          VoteRow(
            candidateName: row.name,
            party: partiesByName[row.party],
            votes: row.votes,
            sharePercent: votes.totalVotes > 0
                ? row.votes / votes.totalVotes * 100
                : 0.0,
            isWinner: identical(row, rows.first),
          ),
      ],
    );
  }
}
