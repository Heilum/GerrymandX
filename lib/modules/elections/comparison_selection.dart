import 'package:gerrymanderx/models/election_sub_item.dart';
import 'package:gerrymanderx/modules/elections/widgets/map/map_painters.dart';
import 'package:gerrymanderx/providers/election_store.dart';
import 'package:gerrymanderx/providers/map_data_store.dart';
import 'package:gerrymanderx/providers/map_state_store.dart';

/// The comparison fill modes need three things picked before they can colour
/// anything: another election that has the same state, and one or two parties
/// that ran in *both* elections.
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

    final otherFolders = comparableElections(electionStore, subItem);
    if (otherFolders.isEmpty) {
      return ComparisonSelection(
        issue: 'No other downloaded election contains $dbName. '
            'Download the same state from another election to compare.',
      );
    }

    final compareFolder = mapStore.comparisonElectionFolder.value;
    if (compareFolder == null || !otherFolders.contains(compareFolder)) {
      return const ComparisonSelection(
        issue: 'Select the election to compare against.',
      );
    }

    final loading = dataStore.isLoadingComparison.value;
    final baselineParties = electionStore.partyNamesIn(compareFolder);
    if (baselineParties.isEmpty) {
      // A year folder's parties are only known once its database has been
      // read, which the comparison load is about to do.
      return ComparisonSelection(
        issue: loading
            ? 'Reading $compareFolder…'
            : '$compareFolder lists no parties. Select another election.',
        isLoading: loading,
      );
    }

    final parties = dataStore.parties.value;
    final partyA = parties[mapStore.comparisonPartyAId.value];
    if (partyA == null) {
      return const ComparisonSelection(issue: 'Select a party to compare.');
    }
    if (!baselineParties.contains(partyA.name)) {
      return ComparisonSelection(
        issue: '${partyA.name} did not run in $compareFolder. '
            'Select another party or another election.',
      );
    }

    final version = dataStore.comparisonVersion.value;
    final loadingIssue = loading ? 'Reading $compareFolder…' : null;

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
        issue: '${partyB.name} did not run in $compareFolder. '
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

  /// Downloaded elections that also hold [subItem]'s state database, i.e. the
  /// ones this state can be compared with. Empty unless a state is selected.
  static List<String> comparableElections(
    ElectionStore electionStore,
    ElectionSubItem? subItem,
  ) {
    final dbName = subItem?.dbName;
    if (subItem == null || subItem.isNational || dbName == null || dbName.isEmpty) {
      return const [];
    }
    return electionStore.foldersContainingDb(
      dbName,
      excluding: electionStore.selectedElectionFolder.value,
    );
  }
}
