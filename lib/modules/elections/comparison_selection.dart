import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// The comparison fill modes need three things picked before they can colour
/// anything: another election of the same state — any year, any office — and
/// one or two parties that ran in *both* elections.
///
/// [resolve] is the single place those rules live. It hands the map a [spec]
/// when the selection is complete, and the UI an [issue] to show the user
/// when it is not — the two must never disagree, hence one resolver.
class ComparisonSelection {
  /// Non-null once the selection is complete and the map can be filled.
  final ComparisonSpec? spec;

  /// User-facing reason the comparison cannot be drawn yet, if any.
  final String? issue;

  /// The other election's data is still being read.
  final bool isLoading;

  const ComparisonSelection({this.spec, this.issue, this.isLoading = false});

  static const _inactive = ComparisonSelection();

  /// Reads the stores' signals directly, so calling this inside a `Watch`
  /// subscribes that widget to every input the comparison depends on.
  static ComparisonSelection resolve({
    required ElectionStore electionStore,
    required MapStateStore mapStore,
    required MapDataStore dataStore,
  }) {
    final mode = mapStore.fillMode.value;
    if (!mode.isComparison) return _inactive;

    final subItem = electionStore.selectedSubItem.value;
    final dbName = subItem?.dbName;
    if (subItem == null || subItem.isNational || dbName == null || dbName.isEmpty) {
      return const ComparisonSelection(
        issue: 'Select a state in the sidebar to compare elections.',
      );
    }

    final folders = comparableElections(electionStore, dataStore, subItem);
    if (folders.isEmpty) {
      return ComparisonSelection(
        issue: 'No other election of $dbName is downloaded. '
            'Download the same state from another election to compare.',
      );
    }

    final compareFolder = mapStore.comparisonElectionFolder.value;
    if (compareFolder == null || !folders.contains(compareFolder)) {
      return const ComparisonSelection(
        issue: 'Select the election to compare against.',
      );
    }

    final loading = dataStore.isLoadingComparison.value;
    final contest = dataStore.comparisonContest.value;
    final baselineParties = dataStore.comparisonPartyNames.value;
    if (contest == null || baselineParties.isEmpty) {
      // The contest and its parties are only known once the other database
      // has been read, which the comparison load is about to do.
      return ComparisonSelection(
        issue: loading
            ? 'Reading $compareFolder…'
            : contest == null
                ? '$compareFolder holds no other election for this state. '
                    'Select another election.'
                : '$compareFolder ${contest.label} lists no parties. '
                    'Select another election.',
        isLoading: loading,
      );
    }
    final target = '$compareFolder ${contest.label}';

    final parties = dataStore.parties.value;
    final partyA = parties[mapStore.comparisonPartyAId.value];
    if (partyA == null) {
      return const ComparisonSelection(issue: 'Select a party to compare.');
    }
    if (!baselineParties.contains(partyA.name)) {
      return ComparisonSelection(
        issue: '${partyA.name} did not run in $target. '
            'Select another party or another election.',
      );
    }

    final version = dataStore.comparisonVersion.value;
    final loadingIssue = loading ? 'Reading $target…' : null;

    if (mode == FillMode.singlePartyComparison) {
      return ComparisonSelection(
        spec: ComparisonSpec(
          partyAName: partyA.name,
          partyAColor: partyA.color,
          dataVersion: version,
        ),
        issue: loadingIssue,
        isLoading: loading,
      );
    }

    final partyB = parties[mapStore.comparisonPartyBId.value];
    if (partyB == null) {
      return const ComparisonSelection(issue: 'Select a second party.');
    }
    if (partyB.id == partyA.id) {
      return const ComparisonSelection(issue: 'Select two different parties.');
    }
    if (!baselineParties.contains(partyB.name)) {
      return ComparisonSelection(
        issue: '${partyB.name} did not run in $target. '
            'Select another party or another election.',
      );
    }

    return ComparisonSelection(
      spec: ComparisonSpec(
        partyAName: partyA.name,
        partyAColor: partyA.color,
        partyBName: partyB.name,
        partyBColor: partyB.color,
        dataVersion: version,
      ),
      issue: loadingIssue,
      isLoading: loading,
    );
  }

  /// Downloaded elections that hold [subItem]'s state database, i.e. the ones
  /// this state can be compared with. The election on the map counts too when
  /// its database holds another contest to compare with. Empty unless a state
  /// is selected.
  static List<String> comparableElections(
    ElectionStore electionStore,
    MapDataStore dataStore,
    ElectionSubItem? subItem,
  ) {
    final dbName = subItem?.dbName;
    if (subItem == null || subItem.isNational || dbName == null || dbName.isEmpty) {
      return const [];
    }
    final current = electionStore.selectedElectionFolder.value;
    return [
      for (final folder in electionStore.foldersContainingDb(dbName))
        if (folder != current || dataStore.availableElections.value.length > 1)
          folder,
    ];
  }
}
