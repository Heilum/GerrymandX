import 'package:flutter/material.dart';

import 'package:gerrymanderx/models/custom_layer.dart';

/// Shows a palette anchored to [anchorContext]'s widget and resolves with the
/// chosen colour, or null if dismissed.
Future<Color?> showGroupColorPicker(
  BuildContext anchorContext, {
  required Color current,
}) {
  final box = anchorContext.findRenderObject() as RenderBox;
  final overlay =
      Overlay.of(anchorContext).context.findRenderObject() as RenderBox;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final position = RelativeRect.fromRect(
    Rect.fromLTWH(origin.dx, origin.dy + box.size.height, 0, 0),
    Offset.zero & overlay.size,
  );

  return showMenu<Color>(
    context: anchorContext,
    position: position,
    items: [
      PopupMenuItem<Color>(
        enabled: false,
        padding: const EdgeInsets.all(8),
        child: _PaletteGrid(current: current),
      ),
    ],
  );
}

class _PaletteGrid extends StatelessWidget {
  const _PaletteGrid({required this.current});

  final Color current;

  @override
  Widget build(BuildContext context) {
    const columns = 8;
    const tile = 24.0;
    return SizedBox(
      width: columns * (tile + 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in GroupCell.palette)
            _ColorTile(
              color: c,
              selected: c.toARGB32() == current.toARGB32(),
              onTap: () => Navigator.of(context).pop(c),
            ),
          Tooltip(
            message: 'Random colour',
            child: InkWell(
              onTap: () => Navigator.of(context).pop(GroupCell.randomColor()),
              child: Container(
                width: tile,
                height: tile,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: const SweepGradient(colors: [
                    Colors.red,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ]),
                ),
                child: const Icon(Icons.shuffle, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorTile extends StatelessWidget {
  const _ColorTile({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}

/// The square that heads every group-cell row: shows the colour, opens the
/// picker on click.
class GroupColorSwatch extends StatelessWidget {
  const GroupColorSwatch({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 16,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (anchor) {
      return Tooltip(
        message: 'Change colour',
        child: InkWell(
          borderRadius: BorderRadius.circular(3),
          onTap: () async {
            final picked = await showGroupColorPicker(anchor, current: color);
            if (picked != null) onChanged(picked);
          },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.white38),
            ),
          ),
        ),
      );
    });
  }
}
