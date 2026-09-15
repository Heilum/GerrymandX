import 'package:flutter_test/flutter_test.dart';
import 'package:gerrymanderx/models/election_metadata.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';

/// Any two elections of a state can be compared — another year, another
/// office, or another contest of the election on the map.
void main() {
  const president = ElectionContest(id: 1, office: 'President', name: 'P');
  const senate = ElectionContest(id: 2, office: 'US Senate', name: 'S');
  const senateSpecial =
      ElectionContest(id: 3, office: 'US Senate', name: 'SS', special: true);
  const house = ElectionContest(id: 4, office: 'US House', name: 'H');
  const contests = [president, senate, senateSpecial, house];

  ElectionContest? resolve({
    String? wanted,
    String? office,
    ElectionContest? exclude,
    List<ElectionContest> from = contests,
  }) =>
      MapDataStore.resolveComparisonContest(from,
          wantedLabel: wanted, office: office, exclude: exclude);

  test('the picked type wins over the office on the map', () {
    expect(resolve(wanted: 'US Senate', office: 'President'), senate);
    expect(resolve(wanted: 'US Senate (Special)', office: 'President'),
        senateSpecial);
  });

  test('with nothing picked, the office on the map is compared', () {
    expect(resolve(office: 'US House'), house);
    // The regular contest, never the special one, by default.
    expect(resolve(office: 'US Senate'), senate);
  });

  test('a type the other election did not hold falls back', () {
    expect(resolve(wanted: 'Governor', office: 'US House'), house);
    expect(resolve(wanted: 'Governor', office: 'Governor'), president);
  });

  test('within one election the contest on the map is left out', () {
    expect(resolve(office: 'President', exclude: president), senate);
    expect(
        resolve(wanted: 'President', office: 'President', exclude: president),
        senate);
    expect(resolve(office: 'President', exclude: president, from: [president]),
        isNull);
  });

  test('a legacy database offers its single presidential contest', () {
    expect(
        resolve(
            wanted: 'US Senate',
            office: 'US Senate',
            from: const [ElectionContest.legacyPresident]),
        ElectionContest.legacyPresident);
  });
}
