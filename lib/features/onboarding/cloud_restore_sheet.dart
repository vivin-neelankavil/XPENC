import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../data/providers.dart';
import '../data_export/cloud_sync_models.dart';
import '../data_export/cloud_sync_service.dart';
import '../data_export/connector_sync_service.dart';
import '../data_export/gdrive_sync_service.dart';

enum _CloudView {
  selectProvider,
  gdriveList,
  githubForm,
}

String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Modal bottom sheet allowing users to restore their database from
/// Google Drive or GitHub cloud sync during onboarding.
class CloudRestoreSheet extends ConsumerStatefulWidget {
  const CloudRestoreSheet({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => const CloudRestoreSheet(),
    );
  }

  @override
  ConsumerState<CloudRestoreSheet> createState() => _CloudRestoreSheetState();
}

class _CloudRestoreSheetState extends ConsumerState<CloudRestoreSheet> {
  _CloudView _view = _CloudView.selectProvider;

  // Google Drive state
  GoogleSignInAccount? _gdriveAccount;
  List<GDriveBackupFile> _gdriveFiles = [];

  // GitHub state
  final _tokenCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  final _branchCtrl = TextEditingController(text: 'main');
  bool _obscureToken = true;

  // Common loading / error state
  bool _loading = false;
  String? _loadingMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final syncService = ref.read(cloudSyncServiceProvider);
    _tokenCtrl.text = syncService.githubToken;
    _repoCtrl.text = syncService.githubRepo;
    if (syncService.githubBranch.isNotEmpty) {
      _branchCtrl.text = syncService.githubBranch;
    }
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _repoCtrl.dispose();
    _branchCtrl.dispose();
    super.dispose();
  }

  // ── Google Drive Actions ──────────────────────────────────────────────────

  Future<void> _startGDriveFlow() async {
    setState(() {
      _loading = true;
      _loadingMessage = tr('Connecting to Google…');
      _errorMessage = null;
    });

    try {
      final account = await GDriveSyncService.signIn();
      if (!mounted) return;
      if (account == null) {
        setState(() {
          _loading = false;
          _loadingMessage = null;
        });
        return;
      }

      setState(() {
        _gdriveAccount = account;
        _loadingMessage = tr('Searching Google Drive for backups…');
      });

      final db = ref.read(dbProvider);
      final files = await GDriveSyncService(db).listBackups();
      if (!mounted) return;

      if (files.isEmpty) {
        setState(() {
          _loading = false;
          _loadingMessage = null;
          _errorMessage = tr(
            'No XPENC backups were found in your Google Drive ({0}).',
            [account.email],
          );
        });
        return;
      }

      setState(() {
        _gdriveFiles = files;
        _loading = false;
        _loadingMessage = null;
        _view = _CloudView.gdriveList;
      });
    } on GDriveSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = tr('Could not connect to Google Drive: {0}', [e]);
      });
    }
  }

  Future<void> _restoreGDriveFile(GDriveBackupFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Restore this backup?')),
        content: Text(
          tr(
            'This will download "{0}" from Google Drive and restore your XPENC data.',
            [file.name == driveSyncFileName ? tr('Cloud Sync Backup') : file.name],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Restore')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() {
      _loading = true;
      _loadingMessage = tr('Downloading and restoring data…');
      _errorMessage = null;
    });

    try {
      final db = ref.read(dbProvider);
      await GDriveSyncService(db).downloadAndRestore(file.id);

      final syncService = ref.read(cloudSyncServiceProvider);
      await syncService.setProvider(CloudSyncProvider.gdrive);
      await db.markOnboarded();

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final router = GoRouter.of(context);

      Navigator.of(context).pop(true);
      router.go('/dashboard');

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Restored successfully from Google Drive!')),
          ),
        );
    } on GDriveSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = tr("Couldn't restore from Drive: {0}", [e]);
      });
    }
  }

  // ── GitHub Actions ────────────────────────────────────────────────────────

  Future<void> _restoreFromGitHub() async {
    final repo = _repoCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    final branch = _branchCtrl.text.trim().isEmpty ? 'main' : _branchCtrl.text.trim();

    if (repo.isEmpty || token.isEmpty) {
      setState(() {
        _errorMessage = tr('Please enter both the repository and token.');
      });
      return;
    }

    setState(() {
      _loading = true;
      _loadingMessage = tr('Connecting to GitHub repository…');
      _errorMessage = null;
    });

    try {
      final ok = await GitHubSyncService.testConnection(
        token: token,
        repo: repo,
        branch: branch,
      );
      if (!ok) {
        throw const ConnectorSyncException(
          'Could not connect to GitHub. Please check your repository name and token permissions.',
        );
      }

      if (!mounted) return;
      setState(() {
        _loadingMessage = tr('Downloading and restoring data…');
      });

      final db = ref.read(dbProvider);
      final githubService = GitHubSyncService(db);
      await githubService.performSync(
        token: token,
        repo: repo,
        branch: branch,
        forcePull: true,
      );

      final syncService = ref.read(cloudSyncServiceProvider);
      await syncService.saveGithubConfig(token: token, repo: repo, branch: branch);
      await syncService.setProvider(CloudSyncProvider.connector);
      await db.markOnboarded();

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final router = GoRouter.of(context);

      Navigator.of(context).pop(true);
      router.go('/dashboard');

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Restored successfully from GitHub!')),
          ),
        );
    } on ConnectorSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMessage = null;
        _errorMessage = tr("Couldn't restore from GitHub: {0}", [e]);
      });
    }
  }

  // ── UI Views ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Error banner if any
            if (_errorMessage != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.error.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, size: 20, color: cs.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // In-flight progress indicator
            if (_loading) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Column(
                  children: [
                    const SizedBox(
                      height: 36,
                      width: 36,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _loadingMessage ?? tr('Loading…'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              switch (_view) {
                _CloudView.selectProvider => _buildSelectProviderView(theme, cs),
                _CloudView.gdriveList => _buildGDriveListView(theme, cs),
                _CloudView.githubForm => _buildGitHubFormView(theme, cs),
              },
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectProviderView(ThemeData theme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.cloud_sync_outlined, size: 20, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('Restore from Cloud'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr('Choose where your backup is saved to restore your data:'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),

        // Google Drive option
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: Colors.blue.withValues(alpha: 0.15),
              child: const Icon(Icons.add_to_drive, color: Colors.blue),
            ),
            title: Text(
              tr('Google Drive'),
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              tr('Restore from your personal Google Drive account.'),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _startGDriveFlow,
          ),
        ),
        const SizedBox(height: 12),

        // GitHub option
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: AppColors.transfer.withValues(alpha: 0.15),
              child: Icon(Icons.code_rounded, color: AppColors.transfer),
            ),
            title: Text(
              tr('GitHub'),
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              tr('Restore from a private GitHub backup repository.'),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              setState(() {
                _errorMessage = null;
                _view = _CloudView.githubForm;
              });
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGDriveListView(ThemeData theme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _view = _CloudView.selectProvider;
                });
              },
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Google Drive Backups'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (_gdriveAccount != null)
                    Text(
                      _gdriveAccount!.email,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          tr('Select a backup to restore:'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),

        ..._gdriveFiles.map((file) {
          final isSyncFile = file.name == driveSyncFileName;
          final title = isSyncFile ? tr('Cloud Sync Backup') : file.name;
          final dateStr = DateFormat.yMMMd().add_jm().format(file.createdAt);
          final sizeStr = _sizeLabel(file.sizeBytes);

          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: CircleAvatar(
                backgroundColor: isSyncFile
                    ? cs.primaryContainer
                    : Colors.teal.withValues(alpha: 0.15),
                child: Icon(
                  isSyncFile ? Icons.cloud_sync_outlined : Icons.history_rounded,
                  color: isSyncFile ? cs.primary : Colors.teal,
                  size: 20,
                ),
              ),
              title: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '$sizeStr • $dateStr',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.cloud_download_outlined, size: 20),
              onTap: () => _restoreGDriveFile(file),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildGitHubFormView(ThemeData theme, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _view = _CloudView.selectProvider;
                });
              },
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                tr('Restore from GitHub'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Help card
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    tr('GitHub Requirements'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                tr(
                  'Use a Fine-Grained Personal Access Token with "Contents: Read and write" access to your private backup repository.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _repoCtrl,
          decoration: InputDecoration(
            labelText: tr('GitHub Repository'),
            hintText: 'username/my-xpenc-backup',
            prefixIcon: const Icon(Icons.folder_outlined, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 14),

        TextField(
          controller: _tokenCtrl,
          obscureText: _obscureToken,
          decoration: InputDecoration(
            labelText: tr('Fine-Grained Personal Access Token'),
            hintText: 'github_pat_...',
            prefixIcon: const Icon(Icons.key_rounded, size: 20),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 20,
              ),
              onPressed: () => setState(() => _obscureToken = !_obscureToken),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 14),

        TextField(
          controller: _branchCtrl,
          decoration: InputDecoration(
            labelText: tr('Branch'),
            hintText: 'main',
            prefixIcon: const Icon(Icons.fork_right_rounded, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 20),

        FilledButton.icon(
          onPressed: _restoreFromGitHub,
          icon: const Icon(Icons.cloud_download_outlined),
          label: Text(tr('Restore from GitHub')),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }
}
