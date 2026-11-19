import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/app_icons.dart';
import '../../core/budget_cycle.dart';
import '../../core/layout/desktop.dart';
import '../../core/money.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/glass.dart';
import '../../core/widgets/app_surfaces.dart';
import '../../core/widgets/module_shortcuts.dart';
import '../../core/widgets/custom_icon_badge.dart';
import '../../core/widgets/error_view.dart';
import '../../core/widgets/icon_picker_sheet.dart';
import '../../core/widgets/money_text.dart';
import '../../data/database.dart';
import '../../data/providers.dart';
import '../../data/tables.dart';
import '../../core/widgets/nav_bar_inset.dart';
import '../../core/l10n/l10n.dart';

/// Preset colours for a category. Plain ints — this is the category's own
/// decorative colour, not a money-direction signal.
const _presetColors = <int>[
  0xFF16A34A,
  0xFF2563EB,
  0xFFDC2626,
  0xFFA855F7,
  0xFFF97316,
  0xFF0EA5E9,
  0xFF78716C,
  0xFFEC4899,
];

/// Interval presets for the Categories overview screen.
enum CategoryTimeIntervalKind {
  allTime,
  today,
  week,
  month,
  year,
  day,
  customRange,
}

/// Manage expense and income categories. Categories are archived rather than
/// deleted — every past transaction keeps its category so reports stay
/// intact. Archived ones live behind the top bar's archive button, where
/// they can be restored (or, if never used, deleted).
class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({this.embedded = false, super.key});

  final bool embedded;

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _isManageMode = false;
  CategoryKind _selectedKind = CategoryKind.expense;
  CategoryTimeIntervalKind _intervalKind = CategoryTimeIntervalKind.allTime;
  DateTime _anchorDate = DateTime.now();
  DateTimeRange? _customRange;
  bool _dismissedPaydayTip = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  ({DateTime? start, DateTime? end, String label}) _resolveInterval(
    int budgetStartDay,
  ) {
    final now = DateTime.now();
    switch (_intervalKind) {
      case CategoryTimeIntervalKind.allTime:
        return (start: null, end: null, label: tr('All time'));
      case CategoryTimeIntervalKind.today:
        final start = DateTime(now.year, now.month, now.day);
        final end = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
        return (
          start: start,
          end: end,
          label: tr('Today, {0}', [DateFormat('d MMMM').format(now)]),
        );
      case CategoryTimeIntervalKind.day:
        final start = DateTime(
          _anchorDate.year,
          _anchorDate.month,
          _anchorDate.day,
        );
        final end = DateTime(
          _anchorDate.year,
          _anchorDate.month,
          _anchorDate.day,
          23,
          59,
          59,
          999,
        );
        final isToday =
            start.year == now.year &&
            start.month == now.month &&
            start.day == now.day;
        return (
          start: start,
          end: end,
          label: isToday
              ? tr('Today, {0}', [DateFormat('d MMMM').format(start)])
              : DateFormat('d MMMM yyyy').format(start),
        );
      case CategoryTimeIntervalKind.week:
        final weekDay = _anchorDate.weekday; // 1 = Mon, 7 = Sun
        final start = DateTime(
          _anchorDate.year,
          _anchorDate.month,
          _anchorDate.day,
        ).subtract(Duration(days: weekDay - 1));
        final end = start.add(
          const Duration(
            days: 6,
            hours: 23,
            minutes: 59,
            seconds: 59,
            milliseconds: 999,
          ),
        );
        final sameMonth = start.month == end.month && start.year == end.year;
        final rangeStr = sameMonth
            ? '${DateFormat('d').format(start)} - ${DateFormat('d MMMM').format(end)}'
            : '${DateFormat('d MMM').format(start)} - ${DateFormat('d MMM').format(end)}';
        return (
          start: start,
          end: end,
          label: tr('Week, {0}', [rangeStr]),
        );
      case CategoryTimeIntervalKind.month:
        final period = budgetPeriodFor(_anchorDate, budgetStartDay);
        return (
          start: period.start,
          end: period.end,
          label: DateFormat('MMMM yyyy').format(_anchorDate),
        );
      case CategoryTimeIntervalKind.year:
        final start = DateTime(_anchorDate.year, 1, 1);
        final end = DateTime(_anchorDate.year, 12, 31, 23, 59, 59, 999);
        return (start: start, end: end, label: '${_anchorDate.year} year');
      case CategoryTimeIntervalKind.customRange:
        if (_customRange != null) {
          final s = _customRange!.start;
          final e = DateTime(
            _customRange!.end.year,
            _customRange!.end.month,
            _customRange!.end.day,
            23,
            59,
            59,
            999,
          );
          return (
            start: s,
            end: e,
            label:
                '${DateFormat('d MMM').format(s)} – ${DateFormat('d MMM yyyy').format(e)}',
          );
        }
        return (start: null, end: null, label: tr('Custom range'));
    }
  }

  void _navigateInterval(int delta) {
    setState(() {
      switch (_intervalKind) {
        case CategoryTimeIntervalKind.allTime:
          break;
        case CategoryTimeIntervalKind.today:
          _intervalKind = CategoryTimeIntervalKind.day;
          _anchorDate = DateTime.now().add(Duration(days: delta));
        case CategoryTimeIntervalKind.day:
          _anchorDate = _anchorDate.add(Duration(days: delta));
        case CategoryTimeIntervalKind.week:
          _anchorDate = _anchorDate.add(Duration(days: delta * 7));
        case CategoryTimeIntervalKind.month:
          _anchorDate = DateTime(_anchorDate.year, _anchorDate.month + delta, 1);
        case CategoryTimeIntervalKind.year:
          _anchorDate = DateTime(_anchorDate.year + delta, 1, 1);
        case CategoryTimeIntervalKind.customRange:
          if (_customRange != null) {
            final diff =
                _customRange!.end.difference(_customRange!.start) +
                const Duration(days: 1);
            final s = _customRange!.start.add(diff * delta);
            final e = _customRange!.end.add(diff * delta);
            _customRange = DateTimeRange(start: s, end: e);
          }
      }
    });
  }

  Future<void> _showTimeIntervalSheet(BuildContext context) async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final now = DateTime.now();

    final weekDay = now.weekday;
    final weekStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: weekDay - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));
    final weekSubtitle =
        '${DateFormat('d').format(weekStart)} - ${DateFormat('d MMMM').format(weekEnd)}';
    final todaySubtitle = DateFormat('d MMMM').format(now);
    final yearSubtitle = '${now.year} year';
    final monthSubtitle = DateFormat('MMMM yyyy').format(now);

    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SingleChildScrollView(
              padding:
                  const EdgeInsets.fromLTRB(20, 4, 20, 24).plusNavBar(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Text(
                      tr('Time interval'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!_dismissedPaydayTip)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          AppIcon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                context.push('/more/settings/general');
                              },
                              child: Text(
                                tr(
                                  'Your month can start on payday instead of the 1st. Tap to set it up.',
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const AppIcon(Icons.close_rounded, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              setSheetState(() => _dismissedPaydayTip = true);
                              setState(() => _dismissedPaydayTip = true);
                            },
                          ),
                        ],
                      ),
                    ),
                  // Full width Select date range button
                  _intervalPresetTile(
                    theme: theme,
                    icon: Icons.calendar_month_rounded,
                    title: tr('Select date range'),
                    isSelected:
                        _intervalKind == CategoryTimeIntervalKind.customRange,
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDateRange:
                            _customRange ??
                            DateTimeRange(
                              start: now.subtract(const Duration(days: 30)),
                              end: now,
                            ),
                      );
                      if (picked != null) {
                        setState(() {
                          _intervalKind = CategoryTimeIntervalKind.customRange;
                          _customRange = picked;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  // 2-column grid of options
                  Row(
                    children: [
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.all_inclusive_rounded,
                          title: tr('All time'),
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.allTime,
                          onTap: () {
                            setState(
                              () =>
                                  _intervalKind =
                                      CategoryTimeIntervalKind.allTime,
                            );
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.event_available_rounded,
                          title: tr('Choose a day'),
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.day,
                          onTap: () async {
                            Navigator.of(sheetContext).pop();
                            final picked = await showDatePicker(
                              context: context,
                              initialDate:
                                  _intervalKind == CategoryTimeIntervalKind.day
                                  ? _anchorDate
                                  : now,
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              setState(() {
                                _intervalKind = CategoryTimeIntervalKind.day;
                                _anchorDate = picked;
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.calendar_view_week_rounded,
                          title: tr('Week'),
                          subtitle: weekSubtitle,
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.week,
                          onTap: () {
                            setState(() {
                              _intervalKind = CategoryTimeIntervalKind.week;
                              _anchorDate = now;
                            });
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.today_rounded,
                          title: tr('Today'),
                          subtitle: todaySubtitle,
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.today,
                          onTap: () {
                            setState(() {
                              _intervalKind = CategoryTimeIntervalKind.today;
                              _anchorDate = now;
                            });
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.calendar_today_rounded,
                          title: tr('Year'),
                          subtitle: yearSubtitle,
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.year,
                          onTap: () {
                            setState(() {
                              _intervalKind = CategoryTimeIntervalKind.year;
                              _anchorDate = now;
                            });
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _intervalPresetTile(
                          theme: theme,
                          icon: Icons.calendar_month_rounded,
                          title: tr('Month'),
                          subtitle: monthSubtitle,
                          isSelected:
                              _intervalKind == CategoryTimeIntervalKind.month,
                          onTap: () {
                            setState(() {
                              _intervalKind = CategoryTimeIntervalKind.month;
                              _anchorDate = now;
                            });
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: Text(tr('Cancel')),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _intervalPresetTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    String? subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? cs.primaryContainer : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? cs.primary
                : cs.outlineVariant.withValues(alpha: 0.35),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              icon,
              size: 26,
              color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected
                      ? cs.onPrimaryContainer.withValues(alpha: 0.8)
                      : cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(categoryAddSignalProvider, (prev, next) {
      if (next > 0) {
        _openCategoryEditor(context, kind: _selectedKind);
      }
    });

    final theme = Theme.of(context);

    if (_isManageMode) {
      return Scaffold(
        appBar: widget.embedded
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Container(
                  color: theme.colorScheme.surface,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const AppIcon(Icons.arrow_back),
                        tooltip: tr('Overview'),
                        onPressed: () => setState(() => _isManageMode = false),
                      ),
                      Expanded(
                        child: TabBar(
                          controller: _tabController,
                          tabs: [
                            Tab(text: tr('Money out')),
                            Tab(text: tr('Money in')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : AppTopBar(
                automaticallyImplyLeading: impliesBackArrow(context),
                title: const Tr('Categories'),
                actions: [
                  IconButton(
                    icon: const AppIcon(Icons.dashboard_outlined),
                    tooltip: tr('Overview'),
                    onPressed: () => setState(() => _isManageMode = false),
                  ),
                  IconButton(
                    icon: const AppIcon(Icons.inventory_2_outlined),
                    tooltip: tr('Archived categories'),
                    onPressed: () => context.push('/more/categories/archived'),
                  ),
                  IconButton(
                    icon: const AppIcon(Icons.dashboard_customize_outlined),
                    tooltip: tr('Templates'),
                    onPressed: () => context.push('/more/categories/templates'),
                  ),
                ],
                bottom: TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: tr('Money out')),
                    Tab(text: tr('Money in')),
                  ],
                ),
              ),
        body: TabBarView(
          controller: _tabController,
          children: const [
            _CategoryList(kind: CategoryKind.expense),
            _CategoryList(kind: CategoryKind.income),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: tr('New category'),
          onPressed: () {
            final kind = _tabController.index == 0
                ? CategoryKind.expense
                : CategoryKind.income;
            _openCategoryEditor(context, kind: kind);
          },
          child: const AppIcon(Icons.add),
        ),
      );
    }

    final startDay = ref.watch(budgetStartDayProvider);
    final interval = _resolveInterval(startDay);
    final netWorth = ref.watch(netWorthProvider).valueOrNull ?? const Money.zero();
    final txs = ref.watch(allTransactionsProvider).valueOrNull ?? const [];
    final splitsByTx = ref.watch(transactionSplitsByTxProvider);
    final categoryMap = ref.watch(categoryMapProvider);

    Money totalExpenses = const Money.zero();
    Money totalIncome = const Money.zero();
    final categorySpendMap = <int, Money>{};
    final categoryIncomeMap = <int, Money>{};

    for (final t in txs) {
      if (interval.start != null && t.date.isBefore(interval.start!)) continue;
      if (interval.end != null && t.date.isAfter(interval.end!)) continue;

      if (t.type == TxType.expense) {
        totalExpenses += t.amount;
        final splits = splitsByTx[t.id];
        if (splits != null && splits.isNotEmpty) {
          for (final s in splits) {
            categorySpendMap[s.categoryId] =
                (categorySpendMap[s.categoryId] ?? const Money.zero()) +
                s.amount;
          }
        } else if (t.categoryId != null) {
          categorySpendMap[t.categoryId!] =
              (categorySpendMap[t.categoryId!] ?? const Money.zero()) +
              t.amount;
        }
      } else if (t.type == TxType.income) {
        totalIncome += t.amount;
        if (t.categoryId != null) {
          categoryIncomeMap[t.categoryId!] =
              (categoryIncomeMap[t.categoryId!] ?? const Money.zero()) +
              t.amount;
        }
      }
    }

    Money totalForCategory(int catId, bool isExpense) {
      final map = isExpense ? categorySpendMap : categoryIncomeMap;
      var total = map[catId] ?? const Money.zero();
      for (final child in categoryMap.values) {
        if (child.parentId == catId) {
          total += map[child.id] ?? const Money.zero();
        }
      }
      return total;
    }

    final isExpense = _selectedKind == CategoryKind.expense;
    final topCategories = categoryMap.values
        .where(
          (c) =>
              c.kind == _selectedKind &&
              c.parentId == null &&
              !c.isArchived,
        )
        .toList();

    topCategories.sort((a, b) {
      final aAmount = totalForCategory(a.id, isExpense).paise;
      final bAmount = totalForCategory(b.id, isExpense).paise;
      if (aAmount != bAmount) return bAmount.compareTo(aAmount);
      return a.name.compareTo(b.name);
    });

    final isGlass = AppSurface.of(context).isGlass;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          if (widget.embedded && isGlass) const TopBarInsetSliver(),
          if (!widget.embedded)
            SliverAppBar(
              pinned: true,
              flexibleSpace: const GlassScrollEdge(),
              automaticallyImplyLeading: impliesBackArrow(context),
              title: const Tr('Categories'),
              actions: [
                IconButton(
                  icon: const AppIcon(Icons.edit_outlined),
                  tooltip: tr('Manage categories'),
                  onPressed: () => setState(() => _isManageMode = true),
                ),
                IconButton(
                  icon: const AppIcon(Icons.inventory_2_outlined),
                  tooltip: tr('Archived categories'),
                  onPressed: () => context.push('/more/categories/archived'),
                ),
                IconButton(
                  icon: const AppIcon(Icons.dashboard_customize_outlined),
                  tooltip: tr('Templates'),
                  onPressed: () => context.push('/more/categories/templates'),
                ),
              ],
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                children: [
                  // Overall balance header inspired by reference screenshot
                  SizedBox(
                    width: double.infinity,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  tr('Overall balance'),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const AmountVisibilityToggle(),
                              ],
                            ),
                            const SizedBox(height: 4),
                            AnimatedBalanceText(
                              netWorth,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                        if (widget.embedded)
                          Positioned(
                            right: 0,
                            child: IconButton(
                              icon: const AppIcon(Icons.edit_outlined),
                              tooltip: tr('Manage categories'),
                              onPressed: () =>
                                  setState(() => _isManageMode = true),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Time interval selector: < Selected Interval ∨ >
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const AppIcon(Icons.chevron_left_rounded),
                        tooltip: tr('Previous period'),
                        onPressed:
                            _intervalKind == CategoryTimeIntervalKind.allTime
                            ? null
                            : () => _navigateInterval(-1),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _showTimeIntervalSheet(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                interval.label,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const AppIcon(Icons.arrow_drop_down_rounded),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const AppIcon(Icons.chevron_right_rounded),
                        tooltip: tr('Next period'),
                        onPressed:
                            _intervalKind == CategoryTimeIntervalKind.allTime
                            ? null
                            : () => _navigateInterval(1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Side-by-side Summary Cards: Expenses & Incomes
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => setState(
                            () => _selectedKind = CategoryKind.expense,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 14,
                            ),
                            decoration: BoxDecoration(
                              color: isExpense
                                  ? theme.colorScheme.surfaceContainerHigh
                                  : theme.colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isExpense
                                    ? AppColors.expense.withValues(alpha: 0.6)
                                    : theme.colorScheme.outlineVariant
                                          .withValues(alpha: 0.3),
                                width: isExpense ? 1.5 : 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  tr('Expenses'),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AnimatedBalanceText(
                                    totalExpenses,
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                          color: AppColors.expense,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => setState(
                            () => _selectedKind = CategoryKind.income,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 14,
                            ),
                            decoration: BoxDecoration(
                              color: !isExpense
                                  ? theme.colorScheme.surfaceContainerHigh
                                  : theme.colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: !isExpense
                                    ? AppColors.income.withValues(alpha: 0.6)
                                    : theme.colorScheme.outlineVariant
                                          .withValues(alpha: 0.3),
                                width: !isExpense ? 1.5 : 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  tr('Incomes'),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AnimatedBalanceText(
                                    totalIncome,
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                          color: AppColors.income,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (topCategories.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyCategories(kind: _selectedKind),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96).plusNavBar(
                context,
              ),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 2.1,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final cat = topCategories[index];
                  final color = Color(cat.colorValue);
                  final amount = totalForCategory(cat.id, isExpense);
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => context.push('/more/categories/${cat.id}'),
                    onLongPress: () => _openCategoryEditor(
                      context,
                      kind: cat.kind,
                      existing: cat,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: AppIcon(
                                AppIcons.resolve(cat.iconKey),
                                color: color,
                                size: 22,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  cat.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  MoneyFormat.symbol(amount),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: amount.isZero
                                        ? theme.colorScheme.onSurfaceVariant
                                        : color,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }, childCount: topCategories.length),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: tr('New category'),
        onPressed: () => _openCategoryEditor(context, kind: _selectedKind),
        child: const AppIcon(Icons.add),
      ),
    );
  }
}

/// One tab's worth of categories, grouped in a single Card.
class _CategoryList extends ConsumerWidget {
  const _CategoryList({required this.kind});

  final CategoryKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final categoriesAsync = ref.watch(categoriesProvider(kind));

    return categoriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: InlineErrorView(message: tr("Couldn't load categories")),
        ),
      ),
      data: (categories) {
        final rows = _flatten(categories);
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 96).plusNavBar(context),
          children: [
            ModuleShortcuts([
              // Basic mode has no budgets.
              if (ref.watch(appModeProvider) != AppMode.basic)
                ModuleShortcut(
                  Icons.donut_large_outlined,
                  tr('Budgets'),
                  '/more/budgets',
                ),
              ModuleShortcut(Icons.sell_outlined, tr('Tags'), '/more/tags'),
              ModuleShortcut(
                Icons.receipt_long_outlined,
                tr('Transactions'),
                '/more/transactions',
              ),
            ], padding: const EdgeInsets.fromLTRB(0, 0, 0, 12)),
            if (categories.isEmpty)
              _EmptyCategories(kind: kind)
            else
              AppCard(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          indent: rows[i].isChild ? 72 : 60,
                          color: theme.colorScheme.outline,
                        ),
                      _CategoryTile(
                        category: rows[i].category,
                        isChild: rows[i].isChild,
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Tr(
              'Group related categories under a parent — a subcategory rolls its '
              'spending up into its parent. Categories are archived, not '
              'deleted, so past reports stay intact — restore them from the '
              'archive button above.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A row in the rendered list: a category plus whether it sits under a parent.
typedef _CategoryEntry = ({CategoryRow category, bool isChild});

/// Order a flat category list into `parent, its children…, next parent…`.
/// A child whose parent isn't in the list (an old backup, a mid-archive state)
/// falls back to rendering as top-level rather than vanishing.
List<_CategoryEntry> _flatten(List<CategoryRow> categories) {
  final parents = categories.where((c) => c.parentId == null).toList();
  final parentIds = {for (final p in parents) p.id};
  final childrenByParent = <int, List<CategoryRow>>{};
  final orphans = <CategoryRow>[];
  for (final c in categories) {
    if (c.parentId == null) continue;
    if (parentIds.contains(c.parentId)) {
      (childrenByParent[c.parentId!] ??= []).add(c);
    } else {
      orphans.add(c);
    }
  }

  final out = <_CategoryEntry>[];
  for (final p in parents) {
    out.add((category: p, isChild: false));
    for (final child in childrenByParent[p.id] ?? const []) {
      out.add((category: child, isChild: true));
    }
  }
  for (final o in orphans) {
    out.add((category: o, isChild: false));
  }
  return out;
}

/// A single category row: coloured icon badge, name, and its actions. A parent
/// also offers "add subcategory"; a child is indented and wears a smaller badge
/// so the hierarchy reads at a glance.
class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category, this.isChild = false});

  final CategoryRow category;
  final bool isChild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = Color(category.colorValue);
    final badge = isChild ? 30.0 : 40.0;

    return AppListTile(
      contentPadding: EdgeInsets.only(left: isChild ? 32 : 16, right: 4),
      // Its own page: totals and every transaction (GitHub #169).
      onTap: () => context.push('/more/categories/${category.id}'),
      leading: Container(
        width: badge,
        height: badge,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: IconWell.forKey(
          category.iconKey,
          color: color,
          size: isChild ? 17 : 22,
        ),
      ),
      title: Text(
        category.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isChild)
            IconButton(
              icon: const AppIcon(Icons.add),
              tooltip: tr('Add subcategory'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _openCategoryEditor(
                context,
                kind: category.kind,
                initialParentId: category.id,
              ),
            ),
          IconButton(
            icon: const AppIcon(Icons.edit_outlined),
            tooltip: tr('Edit'),
            visualDensity: VisualDensity.compact,
            onPressed: () => _openCategoryEditor(
              context,
              kind: category.kind,
              existing: category,
            ),
          ),
          IconButton(
            icon: const AppIcon(Icons.archive_outlined),
            tooltip: tr('Archive'),
            visualDensity: VisualDensity.compact,
            onPressed: () => _confirmArchive(context, ref, category),
          ),
        ],
      ),
    );
  }
}

/// Empty state for a tab with no categories yet.
class _EmptyCategories extends StatelessWidget {
  const _EmptyCategories({required this.kind});

  final CategoryKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = kind == CategoryKind.expense ? 'money-out' : 'money-in';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          AppIcon(
            Icons.category_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            tr('No {0} categories yet — tap + to add one.', [label]),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the create/edit editor sheet. [initialParentId] preselects a parent
/// when adding a subcategory from a parent row.
Future<void> _openCategoryEditor(
  BuildContext context, {
  required CategoryKind kind,
  CategoryRow? existing,
  int? initialParentId,
}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => _CategoryEditorSheet(
      kind: kind,
      existing: existing,
      initialParentId: initialParentId,
    ),
  );
}

/// Confirms and archives a category. Archiving only hides it from new entries —
/// past transactions keep it and nothing is deleted.
Future<void> _confirmArchive(
  BuildContext context,
  WidgetRef ref,
  CategoryRow category,
) async {
  final db = ref.read(dbProvider);
  final messenger = ScaffoldMessenger.of(context);

  final count = await db.countTransactionsForCategory(category.id);
  final childCount = await db.countChildCategories(category.id);
  if (!context.mounted) return;

  final usage = count > 0
      ? tr('{0} transactions use this category. They keep it — '
            'archiving only hides the category from new entries. '
            'Nothing is deleted.', [count])
      : tr("This category isn't used yet. It will be hidden from new "
            'entries.');
  final cascade = childCount > 0
      ? tr('\n\nIts {0} will be archived too.', [
          plural(childCount, '1 subcategory', '{0} subcategories'),
        ])
      : '';

  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr('Archive "{0}"?', [category.name])),
      content: Text('$usage$cascade'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Tr('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Tr('Archive'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  await db.archiveCategory(category.id);
  messenger.showSnackBar(
    SnackBar(
      content: const Tr('Category archived'),
      action: SnackBarAction(
        label: tr('Undo'),
        onPressed: () => db.unarchiveCategory(category.id),
      ),
    ),
  );
}

/// Create or edit a category: name, parent, colour, icon.
class _CategoryEditorSheet extends ConsumerStatefulWidget {
  const _CategoryEditorSheet({
    required this.kind,
    this.existing,
    this.initialParentId,
  });

  final CategoryKind kind;
  final CategoryRow? existing;

  /// Preselected parent when adding a subcategory from a parent row.
  final int? initialParentId;

  @override
  ConsumerState<_CategoryEditorSheet> createState() =>
      _CategoryEditorSheetState();
}

class _CategoryEditorSheetState extends ConsumerState<_CategoryEditorSheet> {
  late final TextEditingController _nameController;
  late int _colorValue;
  late String _iconKey;
  late int? _parentId;
  bool _submitting = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _colorValue = existing?.colorValue ?? _presetColors.first;
    _iconKey = existing?.iconKey ?? AppIcons.allKeys.first;
    _parentId = existing?.parentId ?? widget.initialParentId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError(tr('Give the category a name.'));
      return;
    }

    setState(() => _submitting = true);
    final db = ref.read(dbProvider);
    try {
      if (_isEdit) {
        await db.updateCategory(
          id: widget.existing!.id,
          name: name,
          colorValue: _colorValue,
          iconKey: _iconKey,
          parentId: Value(_parentId),
        );
      } else {
        await db.addCategory(
          name: name,
          kind: widget.kind,
          colorValue: _colorValue,
          iconKey: _iconKey,
          parentId: _parentId,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError(e.message?.toString() ?? tr('Could not save the category.'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError(tr('Could not save the category.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom:
            MediaQuery.of(context).padding.bottom +
            MediaQuery.of(context).viewInsets.bottom +
            20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEdit ? tr('Edit category') : tr('New category'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              autofocus: !_isEdit,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: tr('Name'),
                hintText: tr('e.g. Groceries, Salary'),
                counterText: '',
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 20),
            _buildParentField(theme),
            _fieldLabel(theme, tr('Colour')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [for (final c in _presetColors) _colorDot(theme, c)],
            ),
            const SizedBox(height: 24),
            _fieldLabel(theme, tr('Icon')),
            const SizedBox(height: 12),
            _iconField(theme),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _submitting ? null : _save,
              child: _submitting
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Tr('Save'),
            ),
          ],
        ),
      ),
    );
  }

  /// A dropdown to nest this category under a top-level one. A category that
  /// already has subcategories can't itself become a child (the tree is only
  /// two deep), so it shows a fixed note instead.
  Widget _buildParentField(ThemeData theme) {
    final all = ref.watch(categoriesProvider(widget.kind)).valueOrNull ?? [];
    final editingId = widget.existing?.id;
    final hasChildren =
        editingId != null && all.any((c) => c.parentId == editingId);

    Widget wrap(Widget child) =>
        Padding(padding: const EdgeInsets.only(bottom: 20), child: child);

    if (hasChildren) {
      return wrap(
        InputDecorator(
          decoration: InputDecoration(labelText: tr('Parent category')),
          child: Tr(
            'Top-level — it has subcategories',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    // Candidate parents: every live top-level category of this kind, minus the
    // category being edited (nothing parents itself).
    final parents = all
        .where((c) => c.parentId == null && c.id != editingId)
        .toList();
    final ids = {for (final p in parents) p.id};
    // Guard the dropdown's contract that its value matches one of its items.
    final value = _parentId != null && ids.contains(_parentId)
        ? _parentId
        : null;

    return wrap(
      DropdownButtonFormField<int?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: tr('Parent category'),
          helperText: tr('Optional — nest this under another category'),
        ),
        items: [
          const DropdownMenuItem<int?>(
            value: null,
            child: Tr('None (top-level)'),
          ),
          for (final p in parents)
            DropdownMenuItem<int?>(
              value: p.id,
              child: Row(
                children: [
                  KeyIcon(p.iconKey, size: 18, color: Color(p.colorValue)),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
        onChanged: (v) => setState(() => _parentId = v),
      ),
    );
  }

  Widget _fieldLabel(ThemeData theme, String text) {
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    );
  }

  Widget _colorDot(ThemeData theme, int value) {
    final selected = _colorValue == value;
    return GestureDetector(
      onTap: () => setState(() => _colorValue = value),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(value),
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: theme.colorScheme.onSurface, width: 2.5)
              : null,
        ),
        child: selected
            ? const AppIcon(Icons.check_rounded, color: Colors.white, size: 20)
            : null,
      ),
    );
  }

  /// A single tile showing the chosen icon; tapping it opens the searchable
  /// icon sheet (GitHub #102) instead of laying every icon out inline.
  Widget _iconField(ThemeData theme) {
    final color = Color(_colorValue);
    return GestureDetector(
      onTap: () async {
        final picked = await showIconPickerSheet(
          context,
          selected: _iconKey,
          accentColor: color,
          allowEmoji: true,
        );
        if (picked != null) setState(() => _iconKey = picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: KeyIcon(_iconKey, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Tr(
                'Tap to change',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            AppIcon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
