import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/branding/app_info.dart';
import '../../core/branding/brand_mark.dart';
import '../../core/widgets/app_surfaces.dart';
import '../../core/widgets/open_link.dart';
import '../../core/l10n/l10n.dart';

/// Who made this, which build you are looking at, and where the source lives.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppTopBar(title: const Tr('About')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          40 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          const SizedBox(height: 12),
          const Center(child: BrandMark(size: 80)),
          const SizedBox(height: 16),
          const Center(child: BrandWordmark(fontSize: 32)),
          const SizedBox(height: 6),
          Center(
            child: Tr(
              AppInfo.tagline,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: _VersionPill()),
          const SizedBox(height: 24),

          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Tr(
                AppInfo.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),

          _sectionLabel(context, tr('Discover')),
          AppCard(
            child: Column(
              children: [
                _LinkTile(
                  icon: Icons.auto_awesome_outlined,
                  label: tr("What's new"),
                  value: tr('See what shipped in {0}', [AppInfo.version]),
                  onTap: () => context.push('/more/whats-new'),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                _LinkTile(
                  icon: Icons.menu_book_outlined,
                  label: tr('Guide'),
                  value: tr('Every feature explained, plus Basic/Medium/Pro'),
                  onTap: () => context.push('/more/guide'),
                ),
              ],
            ),
          ),

          _sectionLabel(context, tr('Credits')),
          AppCard(
            child: Column(
              children: [
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    child: const Text(
                      'VN',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  title: Text(
                    AppInfo.maintainer,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    tr('Designer & maintainer · New features, UI redesign & cloud sync'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                AppListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: cs.surfaceContainerHighest,
                    foregroundColor: cs.onSurfaceVariant,
                    child: const Text(
                      'YP',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  title: Text(
                    AppInfo.originalAuthor,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    tr('Original author & creator'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          _sectionLabel(context, tr('Project')),
          AppCard(
            child: Column(
              children: [
                _LinkTile(
                  icon: Icons.code_rounded,
                  label: tr('Source code'),
                  value: 'PATILYASHH/XPENC',
                  url: AppInfo.repoUrl,
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                _LinkTile(
                  icon: Icons.language_rounded,
                  label: tr('Website'),
                  value: 'xpenc.in',
                  url: AppInfo.websiteUrl,
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                _LinkTile(
                  icon: Icons.bug_report_outlined,
                  label: tr('Report a bug'),
                  value: tr('Open an issue on GitHub'),
                  url: AppInfo.issuesUrl,
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                _LinkTile(
                  icon: Icons.share_rounded,
                  label: tr('Share XPENC'),
                  value: tr('Send the app link to a friend'),
                  onTap: () => _shareApp(context),
                ),
                Divider(height: 1, indent: 60, color: cs.outline),
                _LinkTile(
                  icon: Icons.gavel_rounded,
                  label: AppInfo.licenseName,
                  value: tr('Free & open source'),
                  url: AppInfo.licenseUrl,
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),
          Center(
            child: Text(
              AppInfo.copyright,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Tr(
              'Privacy-first · Built with Flutter',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

/// Tap to copy — a bug report is useless without the exact build.
class _VersionPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        await Clipboard.setData(
          const ClipboardData(text: '${AppInfo.name} ${AppInfo.versionLabel}'),
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Tr('Version copied')));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tr('Version {0}', [AppInfo.versionLabel]),
          style: theme.textTheme.labelMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The system share sheet with the Play Store link.
Future<void> _shareApp(BuildContext context) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      text: AppInfo.shareText,
      subject: AppInfo.name,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.label,
    required this.value,
    this.url,
    this.onTap,
  }) : assert(url != null || onTap != null);

  final IconData icon;
  final String label;
  final String value;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AppListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: AppIcon(icon),
      title: Text(
        label,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        value,
        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: AppIcon(
        url != null ? Icons.open_in_new_rounded : Icons.chevron_right_rounded,
        size: 18,
        color: cs.onSurfaceVariant,
      ),
      onTap: onTap ?? () => openLink(context, url!),
    );
  }
}
