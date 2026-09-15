import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/models/geo_cell.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// The comparison fill modes rest on two pieces of arithmetic: re-aggregating
/// another election onto the current map, and turning a swing into a colour.
void main() {
  group('aggregateBaselineInto', () {
    // Two square current regions side by side, and baseline precincts placed
    // by their centre. Region ids are the *current* map's, which is the whole
    // point: the baseline election has its own, unrelated ones.
    RenderableCell region(int id, double left, double right) {
      final rect = Rect.fromLTRB(left, 0, right, 10);
      return RenderableCell(
        cell: GeoCell(id: id, name: 'region $id', layerType: LayerType.county),
        path: Path()..addRect(rect),
        exteriorPath: Path()..addRect(rect),
        bounds: rect,
      );
    }

    final regions = [region(1, 0, 10), region(2, 10, 20)];
    const baseline = [
      BaselinePoint(Offset(2, 5),
          RegionPartyVotes(totalVotes: 100, votesByParty: {'DEM': 40, 'REP': 60})),
      BaselinePoint(Offset(5, 5),
          RegionPartyVotes(totalVotes: 100, votesByParty: {'DEM': 20, 'REP': 80})),
      BaselinePoint(Offset(15, 5),
          RegionPartyVotes(totalVotes: 200, votesByParty: {'DEM': 150, 'REP': 50})),
    ];

    test('sums baseline precincts into the region containing them', () {
      final result =
          MapDataStore.aggregateBaselineInto(regions, baseline);

      expect(result[1]!.totalVotes, 200);
      expect(result[1]!.votesByParty, {'DEM': 60, 'REP': 140});
      expect(result[1]!.shareOf('DEM'), closeTo(0.3, 1e-9));
      expect(result[2]!.totalVotes, 200);
      expect(result[2]!.shareOf('DEM'), closeTo(0.75, 1e-9));
    });

    test('drops baseline precincts that fall outside every region', () {
      final result =
          MapDataStore.aggregateBaselineInto([region(1, 0, 10)], baseline);

      expect(result.keys, [1]);
      expect(result[1]!.totalVotes, 200, reason: 'precinct 72 is outside');
    });

    test('never counts a baseline precinct into two regions', () {
      // Groups are redrawn constantly; totals have to stay additive however
      // the boundaries are cut.
      final split = MapDataStore.aggregateBaselineInto(regions, baseline);
      final whole =
          MapDataStore.aggregateBaselineInto([region(9, 0, 20)], baseline);

      expect(split.values.fold<int>(0, (a, b) => a + b.totalVotes), 400);
      expect(whole[9]!.totalVotes, 400);
      expect(whole[9]!.votesByParty, {'DEM': 210, 'REP': 190});
    });

    test('returns nothing when either side is empty', () {
      expect(MapDataStore.aggregateBaselineInto(const [], baseline), isEmpty);
      expect(MapDataStore.aggregateBaselineInto(regions, const []), isEmpty);
    });
  });

  test('sumRegionVotes adds up parties and candidates statewide', () {
    final state = MapDataStore.sumRegionVotes(const [
      RegionPartyVotes(
        totalVotes: 100,
        votesByParty: {'DEM': 40, 'REP': 55},
        candidateVotesByParty: {
          'DEM': {'Ann': 40},
          'REP': {'Bo': 55},
        },
      ),
      RegionPartyVotes(
        totalVotes: 50,
        votesByParty: {'REP': 50},
        candidateVotesByParty: {
          'REP': {'Bo': 30, 'Cy': 20},
        },
      ),
    ]);

    // Votes for no party still count towards the total.
    expect(state.totalVotes, 150);
    expect(state.votesByParty, {'DEM': 40, 'REP': 105});
    expect(state.candidateVotesByParty, {
      'DEM': {'Ann': 40},
      'REP': {'Bo': 85, 'Cy': 20},
    });
  });

  group('votesByPrecinctId', () {
    // Precincts are matched geometrically rather than by name, so their
    // baseline totals stay keyed by id instead of going through region names.
    const partyOf = {'a1': 'DEM', 'a2': 'DEM', 'b1': 'REP'};

    test('divides each precinct by its own total', () {
      final regions = MapDataStore.votesByPrecinctId(
        {
          10: {'a1': 30, 'a2': 10, 'b1': 60},
          11: {'b1': 100},
        },
        partyOf,
      );

      expect(regions[10]!.shareOf('DEM'), closeTo(0.4, 1e-9));
      expect(regions[10]!.shareOf('REP'), closeTo(0.6, 1e-9));
      expect(regions[11]!.shareOf('REP'), closeTo(1.0, 1e-9));
      expect(regions[11]!.votesByParty.containsKey('DEM'), isFalse);
    });

    test('counts unaffiliated votes in the denominator only', () {
      final regions = MapDataStore.votesByPrecinctId(
        {
          10: {'a1': 40, 'b1': 40, 'z': 20},
        },
        partyOf,
      );

      expect(regions[10]!.shareOf('DEM'), closeTo(0.4, 1e-9));
      expect(regions[10]!.votesByParty.containsKey('z'), isFalse);
    });

    test('keeps who ran for each party, through region aggregation', () {
      final precincts = MapDataStore.votesByPrecinctId(
        {
          10: {'a1': 30, 'a2': 10, 'b1': 60},
          11: {'a1': 5, 'b1': 0},
        },
        partyOf,
        candidateNameById: const {'a1': 'Ann', 'a2': 'Al', 'b1': 'Bo'},
      );

      expect(precincts[10]!.candidateVotesByParty, {
        'DEM': {'Ann': 30, 'Al': 10},
        'REP': {'Bo': 60},
      });
      // A candidate with no votes in a precinct isn't named there.
      expect(precincts[11]!.candidateVotesByParty, {
        'DEM': {'Ann': 5},
      });

      final region = RenderableCell(
        cell: GeoCell(id: 1, name: 'R', layerType: LayerType.county),
        path: Path()..addRect(const Rect.fromLTWH(0, 0, 10, 10)),
        exteriorPath: Path(),
        bounds: const Rect.fromLTWH(0, 0, 10, 10),
      );
      final merged = MapDataStore.aggregateBaselineInto([region], [
        BaselinePoint(const Offset(2, 2), precincts[10]!),
        BaselinePoint(const Offset(3, 3), precincts[11]!),
      ]);
      expect(merged[1]!.candidateVotesByParty['DEM'], {'Ann': 35, 'Al': 10});
    });

    test('skips precincts with no votes rather than dividing by zero', () {
      final regions = MapDataStore.votesByPrecinctId(
        {
          10: {'a1': 0, 'b1': 0},
          11: <String, int>{},
        },
        partyOf,
      );

      expect(regions, isEmpty);
    });
  });

  group('comparisonSwingColor', () {
    const gain = Color(0xFF1565C0);
    const loss = Color(0xFFB71C1C);

    test('no change reads as neutral white', () {
      expect(comparisonSwingColor(0, gain, loss), Colors.white);
    });

    test('the bigger the gain, the closer to the gain colour', () {
      final small = comparisonSwingColor(0.02, gain, loss);
      final large = comparisonSwingColor(0.08, gain, loss);

      expect(_distance(small, gain), greaterThan(_distance(large, gain)));
      expect(_distance(large, gain), greaterThan(0));
    });

    test('saturates at the full-swing threshold and beyond', () {
      expect(comparisonSwingColor(comparisonFullSwing, gain, loss), gain);
      expect(comparisonSwingColor(0.9, gain, loss), gain);
    });

    test('a loss deepens towards the loss colour instead', () {
      expect(comparisonSwingColor(-0.005, gain, loss),
          isNot(comparisonSwingColor(-0.05, gain, loss)));
      expect(comparisonSwingColor(-comparisonFullSwing, gain, loss), loss);
      expect(
        _distance(comparisonSwingColor(-0.05, gain, loss), loss),
        lessThan(_distance(comparisonSwingColor(-0.05, gain, loss), gain)),
      );
    });
  });
}

double _distance(Color a, Color b) =>
    (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
