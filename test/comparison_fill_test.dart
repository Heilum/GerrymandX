import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// The comparison fill modes rest on two pieces of arithmetic: reducing
/// another election's database to per-region party totals, and turning a swing
/// into a colour.
void main() {
  group('votesByRegionName', () {
    // Two counties, two precincts each. Candidate a1/a2 are one party, b1 the
    // other, and z belongs to no party in the manifest.
    const partyOf = {'a1': 'DEM', 'a2': 'DEM', 'b1': 'REP'};

    test('sums a region\'s precincts and divides by its total votes', () {
      final regions = MapDataStore.votesByRegionName(
        {1: 'Anderson', 2: 'Andrews'},
        {
          1: [10, 11],
          2: [20],
        },
        {
          10: {'a1': 30, 'b1': 20},
          11: {'a2': 10, 'b1': 40},
          20: {'a1': 25, 'b1': 75},
        },
        partyOf,
      );

      expect(regions['anderson']!.shareOf('DEM'), closeTo(40 / 100, 1e-9));
      expect(regions['anderson']!.shareOf('REP'), closeTo(60 / 100, 1e-9));
      expect(regions['andrews']!.shareOf('DEM'), closeTo(0.25, 1e-9));
    });

    test('counts unaffiliated votes in the denominator only', () {
      final regions = MapDataStore.votesByRegionName(
        {1: 'Anderson'},
        {
          1: [10],
        },
        {
          10: {'a1': 40, 'b1': 40, 'z': 20},
        },
        partyOf,
      );

      expect(regions['anderson']!.shareOf('DEM'), closeTo(0.4, 1e-9));
      expect(regions['anderson']!.votesByParty.containsKey('z'), isFalse);
    });

    test('matches region names case- and padding-insensitively', () {
      final regions = MapDataStore.votesByRegionName(
        {1: '  Anderson '},
        {
          1: [10],
        },
        {
          10: {'a1': 1},
        },
        partyOf,
      );

      expect(regions.keys, ['anderson']);
      expect(MapDataStore.normalizeRegionName(' ANDERSON '), 'anderson');
    });

    test('merges regions that share a name instead of dropping one', () {
      final regions = MapDataStore.votesByRegionName(
        {1: 'Anderson', 2: 'anderson'},
        {
          1: [10],
          2: [20],
        },
        {
          10: {'a1': 100},
          20: {'b1': 100},
        },
        partyOf,
      );

      expect(regions['anderson']!.shareOf('DEM'), closeTo(0.5, 1e-9));
      expect(regions['anderson']!.shareOf('REP'), closeTo(0.5, 1e-9));
    });

    test('skips regions with no votes rather than dividing by zero', () {
      final regions = MapDataStore.votesByRegionName(
        {1: 'Empty'},
        {
          1: [10],
        },
        const {},
        partyOf,
      );

      expect(regions, isEmpty);
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
