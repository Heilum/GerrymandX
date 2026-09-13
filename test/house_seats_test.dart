import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// The statewide overview of a US House race reports seats, one per district,
/// each going to the candidate with the most votes in that district.
void main() {
  const dem = Party(id: 'p-dem', name: 'DEM', colorValue: 0xFF0000FF);
  const rep = Party(id: 'p-rep', name: 'REP', colorValue: 0xFFFF0000);
  final parties = {dem.id: dem, rep.id: rep};

  const candidates = [
    Candidate(id: 'd1', name: 'A', partyId: 'p-dem', district: '1'),
    Candidate(id: 'r1', name: 'B', partyId: 'p-rep', district: '1'),
    Candidate(id: 'd2', name: 'C', partyId: 'p-dem', district: '2'),
    Candidate(id: 'r2', name: 'D', partyId: 'p-rep', district: '2'),
    Candidate(id: 'd3', name: 'E', partyId: 'p-dem', district: '3'),
    Candidate(id: 'r3', name: 'F', partyId: 'p-rep', district: '3'),
  ];
  final partyMap = {for (final c in candidates) c.id: c.partyId!};

  test('each district seat goes to its top candidate', () {
    final seats = HouseSeatSummary.compute(
      candidates: candidates,
      candidatePartyMap: partyMap,
      parties: parties,
      candidateVotes: {
        'd1': 100, 'r1': 90, // DEM
        'd2': 40, 'r2': 60, // REP
        'd3': 10, 'r3': 70, // REP
      },
    );

    expect(seats.totalSeats, 3);
    expect(seats.seatsByParty, {'DEM': 1, 'REP': 2});
  });

  test('a district with no votes counts as a seat nobody holds', () {
    final seats = HouseSeatSummary.compute(
      candidates: candidates,
      candidatePartyMap: partyMap,
      parties: parties,
      candidateVotes: {'d1': 100, 'r1': 90},
    );

    expect(seats.totalSeats, 3);
    expect(seats.seatsByParty, {'DEM': 1});
  });

  test('candidates without a district contribute no seat', () {
    final seats = HouseSeatSummary.compute(
      candidates: const [
        Candidate(id: 'x', name: 'X', partyId: 'p-dem'),
      ],
      candidatePartyMap: const {'x': 'p-dem'},
      parties: parties,
      candidateVotes: const {'x': 5},
    );

    expect(seats.totalSeats, 0);
    expect(seats.seatsByParty, isEmpty);
  });
}
