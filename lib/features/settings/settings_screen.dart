import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/branding/app_info.dart';
import '../../core/branding/brand_mark.dart';
import '../../core/connector/connector_platform.dart';
import '../../core/platform/distribution.dart';
import '../../core/platform/platform_features.dart';
import '../../core/widgets/app_surfaces.dart';
import '../../core/widgets/open_link.dart';
import '../../core/l10n/l10n.dart';
import '../more/settings_search_index.dart';
import 'settings_common.dart';

/// Settings' front door — a menu of modules, each its own page. Splitting it
/// this way (instead of one long scrolling list of every toggle) keeps each
/// page short enough to scan and keeps this menu itself from growing every
/// time a new setting is added.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _searchActive = false;
  String _searchQuery = '';
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final query = _searchQuery.trim().toLowerCase();

    final searchResults = _searchActive && query.isNotEmpty
        ? kSearchableSettingsIndex.where((s) => s.matches(query)).toList()
        : const <SearchableSetting>[];

    return Scaffold(
      appBar: AppTopBar(
        title: const Tr('Settings'),
        actions: [
          IconButton(
            icon: Icon(_searchActive ? Icons.close : Icons.search),
            tooltip: _searchActive ? tr('Close search') : tr('Search settings'),
            onPressed: () {
              setState(() {
                _searchActive = !_searchActive;
                if (!_searchActive) {
                  _controller.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
        ],
      ),
      body: ListView(
        // Explicit padding drops ListView's nav-bar inset; re-add it (#137).
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          32 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          if (_searchActive) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: TextField(
                controller: _controller,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: tr('Search settings & options...'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _controller.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) {
                  setState(() => _searchQuery = val);
                },
              ),
            ),
          ],
          if (_searchActive && query.isNotEmpty) ...[
            if (searchResults.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: Text(
                    tr('No matching settings found'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              AppCard(
                child: Column(
                  children: [
                    for (var i = 0; i < searchResults.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 60,
                          color: cs.outlineVariant.withValues(alpha: 0.5),
                        ),
                      AppListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        leading: AppIcon(searchResults[i].icon),
                        title: Text(searchResults[i].title),
                        subtitle: Text(
                          '${searchResults[i].category} · ${searchResults[i].subtitle}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        trailing: const AppIcon(Icons.chevron_right_rounded),
                        onTap: () => context.push(searchResults[i].route),
                      ),
                    ],
                  ],
                ),
              ),
          ] else ...[
          // First, and named in its own script, so someone who can't read
          // the language showing still finds the way back (GitHub #191).
          _ModuleGroup([
            _ModuleTile(
              icon: Icons.translate_rounded,
              title: L10n.code == 'en'
                  ? 'Language'
                  : '${tr('Language')} · Language',
              subtitle: appLanguageFor(L10n.code)?.nativeName ?? L10n.code,
              onTap: () => context.push('/more/settings/language'),
            ),
          ]),

          settingsSectionLabel(context, tr('Preferences')),
          _ModuleGroup([
            _ModuleTile(
              icon: Icons.tune_rounded,
              title: tr('General'),
              subtitle: tr('Currency, calendar week start, message capture'),
              onTap: () => context.push('/more/settings/general'),
            ),
            _ModuleTile(
              icon: Icons.palette_outlined,
              title: tr('Appearance & Layout'),
              subtitle: tr('Theme, colours, font, dashboard & navigation'),
              onTap: () => context.push('/more/settings/appearance'),
            ),
            _ModuleTile(
              icon: Icons.savings_outlined,
              title: tr('Level & Budgeting'),
              subtitle: tr('App mode (Basic/Pro), budget cycle, Ready to Assign'),
              onTap: () => context.push('/more/settings/mode-budgeting'),
            ),
          ]),

          settingsSectionLabel(context, tr('Security & Access')),
          _ModuleGroup([
            _ModuleTile(
              icon: Icons.security_outlined,
              title: tr('Security & Privacy'),
              subtitle: PlatformFeatures.screenshotBlocking
                  ? tr('PIN, recovery phrase, authenticator, screenshots')
                  : tr('PIN, recovery phrase, authenticator'),
              onTap: () => context.push('/more/settings/security'),
            ),
            if (PlatformFeatures.notifications)
              _ModuleTile(
                icon: Icons.notifications_outlined,
                title: tr('Notifications'),
                subtitle: PlatformFeatures.quickAddNotification
                    ? tr('Reminders and quick add from a notification')
                    : tr('Reminders and alerts'),
                onTap: () => context.push('/more/settings/notifications'),
              ),
            if (PlatformFeatures.permissionsScreen)
              _ModuleTile(
                icon: Icons.verified_user_outlined,
                title: tr('Permissions'),
                subtitle: tr('What XPENC can access — turn each on or off'),
                onTap: () => context.push('/more/settings/permissions'),
              ),
          ]),

          settingsSectionLabel(context, tr('Payments & Shortcuts')),
          _ModuleGroup([
            _ModuleTile(
              icon: Icons.payments_outlined,
              title: tr('Payment Methods & Repayments'),
              subtitle: tr('UPI ID, PayPal, Venmo, repayments accounting'),
              onTap: () => context.push('/more/settings/persons'),
            ),
            _ModuleTile(
              icon: Icons.flash_on_outlined,
              title: tr('Quick Actions & Widgets'),
              subtitle: PlatformFeatures.homeWidgets
                  ? tr('Hold ➕ shortcuts, home screen widgets')
                  : tr('Hold ➕ shortcuts'),
              onTap: () => context.push('/more/settings/quick-actions'),
            ),
          ]),

          if (connectorPlatform != null) ...[
            settingsSectionLabel(context, tr('Data & Storage')),
            _ModuleGroup([
              _ModuleTile(
                icon: Icons.sync_alt_rounded,
                title: tr('Connector'),
                subtitle: tr('Sync with your phones, Connector friends'),
                onTap: () => context.push('/more/settings/connector'),
              ),
            ]),
          ],
        ],
      ],
    ),
  );
  }
}

/// "More from us": the ExoSynk Labs apps, XPENC among them. One tap target
/// — the whole card opens their page, where each app has its links. CONECTR
/// isn't open source, so F-Droid's build leaves it out
/// ([Distribution.promotesConectr]).
class MoreFromUs extends StatelessWidget {
  const MoreFromUs({super.key});

  static const _apps = [
    _LabsApp(null, AppInfo.name, 'Money, tracked honestly', "You're here"),
    _LabsApp(
      Icons.cloud_sync_outlined,
      'CONECTR',
      'Backup & sync for XPENC',
      'Android',
      openSource: false,
    ),
    _LabsApp(
      Icons.fitness_center_rounded,
      'FITNS',
      'Offline fitness tracker',
      'Soon',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final apps = [
      for (final a in _apps)
        if (a.openSource || Distribution.promotesConectr) a,
    ];
    return Semantics(
      link: true,
      label: tr(
        'More from us: {0}. '
        '{1}',
        [
          AppInfo.labsName,
          [for (final a in apps) a.name].join(', '),
        ],
      ),
      excludeSemantics: true,
      child: AppCard(
        child: InkWell(
          onTap: () => openLink(context, AppInfo.labsUrl),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tr(
                        'More from us',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      AppInfo.labsName,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    AppIcon(
                      Icons.open_in_new_rounded,
                      size: 15,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < apps.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(child: _LabsAppTile(apps[i])),
                    ],
                    // Two apps keep a three-up tile's width.
                    if (apps.length < _apps.length) ...[
                      const SizedBox(width: 10),
                      const Spacer(),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LabsApp {
  const _LabsApp(
    this.icon,
    this.name,
    String blurb,
    String tag, {
    this.openSource = true,
  }) : _blurb = blurb, _tag = tag;

  /// Null: XPENC, which wears its own mark.
  final IconData? icon;
  final String name;
  final String _blurb;
  String get blurb => tr(_blurb);

  /// Where it stands: "You're here", a platform, "Soon".
  final String _tag;
  String get tag => tr(_tag);
  final bool openSource;
}

class _LabsAppTile extends StatelessWidget {
  const _LabsAppTile(this.app);

  final _LabsApp app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final icon = app.icon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon == null
            ? const BrandMark(size: 40)
            : Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.onSurface,
                  borderRadius: BorderRadius.circular(11),
                ),
                // Glass's `surface` isn't opaque: black or white ink, by
                // the tile.
                child: Icon(
                  icon,
                  size: 21,
                  color:
                      ThemeData.estimateBrightnessForColor(cs.onSurface) ==
                              Brightness.dark
                          ? Colors.white
                          : const Color(0xFF0E0E10),
                ),
              ),
        const SizedBox(height: 10),
        Text(
          app.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          app.blurb,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            app.tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// One card of related [_ModuleTile]s, split by hairlines inset past the
/// icon — the More hub's grouping.
class _ModuleGroup extends StatelessWidget {
  const _ModuleGroup(this.tiles);

  final List<_ModuleTile> tiles;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 60, color: cs.outline),
            tiles[i],
          ],
        ],
      ),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: AppIcon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: AppIcon(
        Icons.chevron_right_rounded,
        color: cs.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
