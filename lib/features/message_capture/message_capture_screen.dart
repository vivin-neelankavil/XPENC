import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/widgets/app_surfaces.dart';
import '../../data/providers.dart';
import '../../core/widgets/nav_bar_inset.dart';
import 'parser/sms_rules_updater.dart';

/// Bank-SMS capture settings and definitions management.
///
/// Displays info on on-device parsing privacy, and offers a "virus definition update"
/// style mechanism to download the latest community bank patterns and parsing regexes
/// from the open-source GitHub repository.
class MessageCaptureScreen extends ConsumerStatefulWidget {
  const MessageCaptureScreen({super.key});

  @override
  ConsumerState<MessageCaptureScreen> createState() => _MessageCaptureScreenState();
}

class _MessageCaptureScreenState extends ConsumerState<MessageCaptureScreen> {
  bool _checking = false;
  String? _statusMessage;
  bool _isError = false;

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _statusMessage = null;
      _isError = false;
    });

    final updater = ref.read(smsRulesUpdaterProvider);
    final result = await updater.checkForUpdates();

    if (!mounted) return;
    setState(() {
      _checking = false;
      _statusMessage = result.message;
      _isError = result.isError;
    });

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: result.isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  Future<void> _resetToBundled() async {
    final updater = ref.read(smsRulesUpdaterProvider);
    await updater.resetToBundled();

    if (!mounted) return;
    setState(() {
      _statusMessage = 'Reset to bundled default definitions.';
      _isError = false;
    });

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Reset to bundled default definitions.')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pendingCount = ref.watch(pendingCountProvider);
    final updater = ref.watch(smsRulesUpdaterProvider);

    return Scaffold(
      appBar: AppTopBar(title: const Text('Message Capture')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40).plusNavBar(context),
        children: [
          AppCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AppIcon(Icons.sms_outlined, color: cs.onSurface),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outline),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'COMING SOON',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Auto-capture will be back',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'XPENC used to read bank SMS on this device and turn them '
                    'into review cards. Google Play Protect blocks apps '
                    'installed outside the Play Store that ask for SMS '
                    'permissions — installing XPENC meant pausing your '
                    "phone's protection first. That is the wrong trade for a "
                    'money app, so this version removes the SMS permission '
                    'entirely and installs cleanly.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Auto-capture returns in a Play-compliant form. Until '
                    'then, you can share bank SMS or payment screenshots directly '
                    'into XPENC via the system Share sheet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── SMS Definitions Update Card ─────────────────────────────────────
          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: cs.primaryContainer,
                        child: Icon(
                          Icons.security_update_good_rounded,
                          size: 20,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SMS Definitions',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Community bank patterns & parser rules',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Installed rules version',
                                style: theme.textTheme.bodySmall),
                            Text(
                              'v${updater.currentVersion} ${updater.hasCustomUpdate ? '(Updated)' : '(Bundled)'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Supported banks',
                                style: theme.textTheme.bodySmall),
                            Text(
                              '${updater.bankCount} banks',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        if (updater.lastCheckedAt != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Last checked',
                                  style: theme.textTheme.bodySmall),
                              Text(
                                DateFormat.yMMMd().add_jm().format(updater.lastCheckedAt!),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _isError
                            ? cs.errorContainer.withValues(alpha: 0.7)
                            : cs.primaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isError
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            size: 18,
                            color: _isError ? cs.error : cs.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _statusMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _isError
                                    ? cs.onErrorContainer
                                    : cs.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _checking ? null : _checkForUpdates,
                          icon: _checking
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.sync_rounded, size: 18),
                          label: Text(_checking
                              ? 'Checking GitHub…'
                              : 'Update Definitions'),
                        ),
                      ),
                      if (updater.hasCustomUpdate && !_checking) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _resetToBundled,
                          child: const Text('Reset'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcon(Icons.lock_outline, color: cs.onSurfaceVariant),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Your financial messages and transactions are processed '
                      'privately on-device and never sent to external servers. '
                      'Updating definitions downloads rule patterns only.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (pendingCount > 0) ...[
            const SizedBox(height: 14),
            AppCard(
              child: AppListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: const AppIcon(Icons.inbox_outlined),
                title: const Text('Review Inbox'),
                subtitle: Text(
                  '$pendingCount earlier detected '
                  '${pendingCount == 1 ? 'transaction' : 'transactions'} '
                  'still waiting for review',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                trailing: const AppIcon(Icons.chevron_right_rounded),
                onTap: () => context.push('/inbox'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
