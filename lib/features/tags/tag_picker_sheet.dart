import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_surfaces.dart';
import '../../data/database.dart';
import '../../data/mode_providers.dart';
import '../../data/providers.dart';
import '../../core/widgets/nav_bar_inset.dart';
import '../../core/l10n/l10n.dart';

/// Preset colours for a tag. Plain ints — this is the tag's own decorative
/// colour, not a money-direction signal.
const presetTagColors = <int>[
  0xFF16A34A,
  0xFF2563EB,
  0xFFDC2626,
  0xFFA855F7,
  0xFFF97316,
  0xFF0EA5E9,
  0xFF78716C,
  0xFFEC4899,
];

/// Bottom sheet: pick any number of tags as toggleable filter chips. Users can
/// also create and select new tags directly from here.
/// Shared by [AddTransactionScreen] and [RecurringRuleSheet] (GitHub #63).
class TagPickerSheet extends ConsumerStatefulWidget {
  const TagPickerSheet({
    required this.initiallySelected,
    this.modeId,
    super.key,
  });

  final Set<int> initiallySelected;

  /// Also offers this mode's own tags (see `Tags.modeId`) — never shown
  /// outside it.
  final int? modeId;

  @override
  ConsumerState<TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends ConsumerState<TagPickerSheet> {
  final Set<int> _selected = {};
  late final TextEditingController _searchController;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initiallySelected);
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createNewTag({String? initialName}) async {
    final newTagId = await showAppDialog<int>(
      context: context,
      builder: (_) => TagEditorDialog(
        modeId: widget.modeId,
        initialName: initialName,
      ),
    );
    if (newTagId != null && mounted) {
      setState(() {
        _selected.add(newTagId);
        _searchController.clear();
        _searchQuery = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final tagsAsync = ref
        .watch(tagsProvider)
        .whenData((_) => ref.watch(pickerTagsProvider(widget.modeId)));
    final groups = ref.watch(tagGroupsProvider).valueOrNull ?? const [];
    final tagsByGroup = ref.watch(tagGroupTagsByGroupProvider);
    final usage = ref.watch(tagUsageCountsProvider);

    final trimmedQuery = _searchQuery.trim().toLowerCase();
    final hasTags = (tagsAsync.valueOrNull ?? const []).isNotEmpty;

    final filteredGroups = groups.where((group) {
      if (trimmedQuery.isEmpty) return true;
      if (group.name.toLowerCase().contains(trimmedQuery)) return true;
      final groupTags = tagsByGroup[group.id] ?? const [];
      return groupTags.any((t) => t.name.toLowerCase().contains(trimmedQuery));
    }).toList();

    final availableHeight = media.size.height - media.viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.viewInsets.bottom > 0
              ? availableHeight * 0.9
              : media.size.height * 0.7,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Tr('Tags', style: theme.textTheme.titleLarge),
                    ),
                    _DottedNewTagButton(onPressed: _createNewTag),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(_selected),
                      child: const Tr('Done'),
                    ),
                  ],
                ),
              ),
              if (hasTags)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      prefixIcon: const AppIcon(Icons.search_rounded, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const AppIcon(Icons.clear_rounded, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      hintText: tr('Search tags...'),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
              if (filteredGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final group in filteredGroups)
                        _GroupChip(
                          group: group,
                          tags: tagsByGroup[group.id] ?? const [],
                          selected: _selected,
                          onToggle: (ids) => setState(() {
                            if (ids.every(_selected.contains)) {
                              _selected.removeAll(ids);
                            } else {
                              _selected.addAll(ids);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              Flexible(
                child: tagsAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Could not load tags.\n{0}', [e]),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  data: (tags) {
                    if (tags.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon(
                              Icons.sell_outlined,
                              size: 40,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Tr(
                              'No tags yet',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              icon: const AppIcon(Icons.add_rounded),
                              label: const Tr('Add tag'),
                              onPressed: _createNewTag,
                            ),
                          ],
                        ),
                      );
                    }

                    final sortedTags = [...tags]..sort((a, b) {
                      final countA = usage[a.id] ?? 0;
                      final countB = usage[b.id] ?? 0;
                      final cmp = countB.compareTo(countA); // descending
                      if (cmp != 0) return cmp;
                      return a.name
                          .toLowerCase()
                          .compareTo(b.name.toLowerCase());
                    });

                    final filteredTags = trimmedQuery.isEmpty
                        ? sortedTags
                        : sortedTags
                            .where(
                              (t) =>
                                  t.name.toLowerCase().contains(trimmedQuery),
                            )
                            .toList();

                    if (filteredTags.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 32,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon(
                              Icons.search_off_rounded,
                              size: 40,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr(
                                'No tags matching "{0}"',
                                [_searchQuery.trim()],
                              ),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              icon: const AppIcon(Icons.add_rounded),
                              label: Text(
                                tr('Create "{0}"', [_searchQuery.trim()]),
                              ),
                              onPressed: () => _createNewTag(
                                initialName: _searchQuery.trim(),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(
                        20,
                        0,
                        20,
                        20,
                      ).plusNavBar(context),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final tag in filteredTags)
                            FilterChip(
                              label: Text(tag.name),
                              selected: _selected.contains(tag.id),
                              selectedColor: Color(
                                tag.colorValue,
                              ).withValues(alpha: 0.22),
                              checkmarkColor: Color(tag.colorValue),
                              onSelected: (v) => setState(() {
                                if (v) {
                                  _selected.add(tag.id);
                                } else {
                                  _selected.remove(tag.id);
                                }
                              }),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact button with a dotted outline border and "+ New tag" label.
class _DottedNewTagButton extends StatelessWidget {
  const _DottedNewTagButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: CustomPaint(
          painter: _DottedBorderPainter(
            color: color,
            strokeWidth: 1.4,
            radius: 18,
            dashLength: 2.5,
            dashGap: 3.5,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(Icons.add_rounded, size: 16, color: color),
                const SizedBox(width: 4),
                Tr(
                  'New tag',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DottedBorderPainter extends CustomPainter {
  const _DottedBorderPainter({
    required this.color,
    this.strokeWidth = 1.4,
    this.radius = 18,
    this.dashLength = 2.5,
    this.dashGap = 3.5,
  });

  final Color color;
  final double strokeWidth;
  final double radius;
  final double dashLength;
  final double dashGap;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= strokeWidth || size.height <= strokeWidth) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final half = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      half,
      half,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(radius > half ? radius - half : radius),
    );
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final length = (distance + dashLength < metric.length)
            ? dashLength
            : metric.length - distance;
        canvas.drawPath(metric.extractPath(distance, distance + length), paint);
        distance += dashLength + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.radius != radius ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.dashGap != dashGap;
  }
}

/// One tag group, offered as a single toggle: applies (or removes) every one
/// of its member tags at once. `selected` shows a filled state once every
/// tag it names is already picked, exactly like a group of individual
/// [FilterChip]s would if tapped together.
class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.group,
    required this.tags,
    required this.selected,
    required this.onToggle,
  });

  final TagGroupRow group;
  final List<TagRow> tags;
  final Set<int> selected;
  final ValueChanged<List<int>> onToggle;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final ids = tags.map((t) => t.id).toList();
    final allSelected = ids.every(selected.contains);
    final color = Color(group.colorValue);

    return FilterChip(
      avatar: AppIcon(Icons.workspaces_outline, size: 16, color: color),
      label: Text(group.name),
      selected: allSelected,
      selectedColor: color.withValues(alpha: 0.22),
      checkmarkColor: color,
      onSelected: (_) => onToggle(ids),
    );
  }
}

/// Dialog to quickly create a new tag right from the tag picker.
class TagEditorDialog extends ConsumerStatefulWidget {
  const TagEditorDialog({this.modeId, this.initialName, super.key});

  final int? modeId;
  final String? initialName;

  @override
  ConsumerState<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends ConsumerState<TagEditorDialog> {
  late final TextEditingController _nameController;
  late final FocusNode _focusNode;
  int _colorValue = presetTagColors.first;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    if (widget.initialName != null && widget.initialName!.isNotEmpty) {
      _nameController.selection = TextSelection.fromPosition(
        TextPosition(offset: widget.initialName!.length),
      );
    }
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('Give the tag a name.'));
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final id = await ref.read(dbProvider).addTag(
        name: name,
        colorValue: _colorValue,
        modeId: widget.modeId,
      );
      if (!mounted) return;
      _focusNode.unfocus();
      Navigator.of(context).pop(id);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = tr('Could not save the tag — that name may already be used.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Tr('New tag'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              focusNode: _focusNode,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 30,
              decoration: InputDecoration(
                labelText: tr('Name'),
                hintText: tr('e.g. Work trip, Tax deductible'),
                counterText: '',
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Text(
              'COLOUR',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in presetTagColors) _colorDot(theme, c),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Tr('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _save,
          child: _submitting
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Tr('Add'),
        ),
      ],
    );
  }

  Widget _colorDot(ThemeData theme, int value) {
    final selected = _colorValue == value;
    return GestureDetector(
      onTap: () => setState(() => _colorValue = value),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(value),
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: theme.colorScheme.onSurface, width: 2.5)
              : null,
        ),
        child: selected
            ? const AppIcon(Icons.check_rounded, color: Colors.white, size: 16)
            : null,
      ),
    );
  }
}
