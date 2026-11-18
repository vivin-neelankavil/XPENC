import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/l10n.dart';
import '../../core/widgets/app_surfaces.dart';
import '../../data/providers.dart';
import 'more_screen_layout_sheet.dart';
import 'settings_common.dart';
import 'theme_picker_sheet.dart';

/// Appearance & Layout — theme, colours, typography, dashboard widgets
/// and navigation layout. Everything that shapes how XPENC looks and is arranged.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final trailingStyle = settingsTrailingStyle(context);

    final themeChoice = ref.watch(themeChoiceProvider);
    final moreScreenViewMode = ref.watch(moreScreenViewModeProvider);

    return Scaffold(
      appBar: AppTopBar(title: const Tr('Appearance & Layout')),
      body: ListView(
        // Explicit padding drops ListView's nav-bar inset; re-add it (#137).
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          32 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          settingsSectionLabel(context, tr('Theme & Style')),
          AppCard(
            child: Column(
              children: [
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: AppIcon(themeChoice.style.icon),
                  title: const Tr('Theme'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(themeChoice.style.label, style: trailingStyle),
                      const SizedBox(width: 4),
                      AppIcon(
                        Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                  onTap: () => ThemePickerSheet.show(context),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const AppIcon(Icons.palette_outlined),
                  title: const Tr('Colours'),
                  subtitle: Tr(
                    'Money in, money out, transfer, people, and transaction icons',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  trailing: AppIcon(
                    Icons.chevron_right_rounded,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () => context.push('/more/settings/colours'),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const AppIcon(Icons.text_fields_rounded),
                  title: const Tr('Font & Typography'),
                  subtitle: Tr(
                    'Text size, boldness and font family',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  trailing: AppIcon(
                    Icons.chevron_right_rounded,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () => context.push('/more/settings/font'),
                ),
              ],
            ),
          ),

          settingsSectionLabel(context, tr('Dashboard & Navigation')),
          AppCard(
            child: Column(
              children: [
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const AppIcon(Icons.dashboard_customize_outlined),
                  title: const Tr('Customize dashboard'),
                  subtitle: Tr(
                    'Add, remove and reorder widgets, lay out Accounts, and pick '
                    'what counts toward Net Worth.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  trailing: const AppIcon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/more/settings/dashboard'),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const AppIcon(Icons.tab_outlined),
                  title: const Tr('Customize bottom navigation'),
                  subtitle: Tr(
                    'Choose which navigation tabs appear next to the ➕ button',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  trailing: const AppIcon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/more/bottom-nav'),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const AppIcon(Icons.grid_view_rounded),
                  title: const Tr('More screen layout'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        MoreScreenLayoutSheet.label(moreScreenViewMode),
                        style: trailingStyle,
                      ),
                      const SizedBox(width: 4),
                      AppIcon(
                        Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                  onTap: () => MoreScreenLayoutSheet.show(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
