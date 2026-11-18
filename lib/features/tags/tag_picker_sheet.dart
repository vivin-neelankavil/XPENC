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

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initiallySelected);
  }

  Future<void> _createNewTag() async {
    final newTagId = await showAppDialog<int>(
      context: context,
      builder: (_) => TagEditorDialog(modeId: widget.modeId),
    );
    if (newTagId != null && mounted) {
      setState(() {
        _selected.add(newTagId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagsAsync = ref
        .watch(tagsProvider)
        .whenData((_) => ref.watch(pickerTagsProvider(widget.modeId)));
    final groups = ref.watch(tagGroupsProvider).valueOrNull ?? const [];
    final tagsByGroup = ref.watch(tagGroupTagsByGroupProvider);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Tr('Tags', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    icon: const AppIcon(Icons.add_rounded),
                    tooltip: tr('New tag'),
                    onPressed: _createNewTag,
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: const Tr('Done'),
                  ),
                ],
              ),
            ),
            if (groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final group in groups)
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
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20).plusNavBar(context),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ActionChip(
                          avatar: AppIcon(
                            Icons.add_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          label: Tr(
                            'New tag',
                            style: TextStyle(color: theme.colorScheme.primary),
                          ),
                          onPressed: _createNewTag,
                        ),
                        for (final tag in tags)
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
    );
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
  const TagEditorDialog({this.modeId, super.key});

  final int? modeId;

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
    _nameController = TextEditingController();
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
