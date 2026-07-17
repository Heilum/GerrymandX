import 'package:flutter/material.dart';
import 'package:gerrymanderx/modules/elections/widgets/election_list_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/map_view_panel.dart';
import 'package:gerrymanderx/modules/elections/widgets/inspector_panel.dart';

class ElectionsTab extends StatefulWidget {
  const ElectionsTab({super.key});

  @override
  State<ElectionsTab> createState() => _ElectionsTabState();
}

class _ElectionsTabState extends State<ElectionsTab> {
  bool _showLeftPanel = false;
  bool _showRightPanel = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Elections'),
        leading: IconButton(
          icon: Icon(_showLeftPanel ? Icons.menu_open : Icons.menu),
          onPressed: () {
            setState(() {
              _showLeftPanel = !_showLeftPanel;
            });
          },
        ),
        actions: [
          IconButton(
            icon: Icon(_showRightPanel ? Icons.info_outline : Icons.info),
            onPressed: () {
              setState(() {
                _showRightPanel = !_showRightPanel;
              });
            },
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showLeftPanel)
            const SizedBox(
              width: 250,
              child: ElectionListPanel(),
            ),
          if (_showLeftPanel)
            const VerticalDivider(width: 1, thickness: 1),
          const Expanded(
            child: MapViewPanel(),
          ),
          if (_showRightPanel)
            const VerticalDivider(width: 1, thickness: 1),
          if (_showRightPanel)
            const SizedBox(
              width: 300,
              child: InspectorPanel(),
            ),
        ],
      ),
    );
  }
}
