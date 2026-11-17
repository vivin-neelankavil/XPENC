import 'package:flutter/material.dart';

/// A searchable setting or tool entry indexed across More and Settings.
class SearchableSetting {
  const SearchableSetting({
    required this.title,
    required this.subtitle,
    required this.route,
    required this.category,
    required this.icon,
    this.keywords = const [],
  });

  final String title;
  final String subtitle;
  final String route;
  final String category;
  final IconData icon;
  final List<String> keywords;

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase().trim();
    if (title.toLowerCase().contains(q)) return true;
    if (subtitle.toLowerCase().contains(q)) return true;
    if (category.toLowerCase().contains(q)) return true;
    if (keywords.any((k) => k.toLowerCase().contains(q))) return true;
    return false;
  }
}

/// Master index of nested settings and deeper tools in XPENC.
///
/// Enables recursive search from the More screen and Settings screen so users
/// can immediately find nested items (e.g. Message Capture, Cloud Sync, PIN lock).
const kSearchableSettingsIndex = <SearchableSetting>[
  // ── Message Capture & OCR ──────────────────────────────────────────────────
  SearchableSetting(
    title: 'Bank-SMS auto-capture (Message Capture)',
    subtitle: 'Community bank patterns, SMS definitions & parser rules updater',
    category: 'Settings › General › Message Capture',
    icon: Icons.sms_outlined,
    route: '/more/capture',
    keywords: [
      'sms',
      'message capture',
      'bank sms',
      'auto capture',
      'definitions',
      'parser',
      'rules',
      'bank patterns',
      'github update',
      'virus definition',
    ],
  ),
  SearchableSetting(
    title: 'OCR corrections',
    subtitle: 'Test payment screenshots and help improve on-device OCR',
    category: 'Settings › General › Message Capture',
    icon: Icons.rate_review_outlined,
    route: '/more/capture/ocr-feedback',
    keywords: [
      'ocr',
      'screenshot',
      'scanner',
      'image',
      'payment screenshot',
      'feedback',
      'receipt',
    ],
  ),

  // ── Sync & Cloud ───────────────────────────────────────────────────────────
  SearchableSetting(
    title: 'Cloud Sync (Multi-Device)',
    subtitle: 'Multi-device sync using Google Drive or private GitHub repository',
    category: 'Data › Backup & Restore',
    icon: Icons.cloud_sync_outlined,
    route: '/more/backup',
    keywords: [
      'cloud',
      'sync',
      'google drive',
      'drive',
      'github',
      'backup',
      'restore',
      'multi-device',
      'remote backup',
    ],
  ),
  SearchableSetting(
    title: 'Automatic Backups',
    subtitle: 'Daily, monthly, or on-change automatic local device backups',
    category: 'Data › Backup & Restore',
    icon: Icons.backup_outlined,
    route: '/more/backup',
    keywords: [
      'auto backup',
      'automatic',
      'scheduled backup',
      'backup frequency',
      'local backup',
    ],
  ),

  // ── General Settings ───────────────────────────────────────────────────────
  SearchableSetting(
    title: 'Language',
    subtitle: 'App display language and regional translation packs',
    category: 'Settings › General',
    icon: Icons.translate_rounded,
    route: '/more/settings/language',
    keywords: ['language', 'locale', 'translate', 'english', 'hindi', 'regional'],
  ),
  SearchableSetting(
    title: 'Currency & Symbol',
    subtitle: 'Set primary currency and toggle currency symbol display',
    category: 'Settings › General',
    icon: Icons.currency_exchange_rounded,
    route: '/more/settings/currency',
    keywords: ['currency', 'symbol', 'rupee', 'inr', 'dollar', 'usd', 'euro', 'money format'],
  ),
  SearchableSetting(
    title: 'Theme & Appearance',
    subtitle: 'Classic, Glass, system dark mode or light mode',
    category: 'Settings › General',
    icon: Icons.palette_outlined,
    route: '/more/settings/general',
    keywords: ['theme', 'glass', 'dark mode', 'light mode', 'appearance', 'style', 'display'],
  ),
  SearchableSetting(
    title: 'Font & Typography',
    subtitle: 'Font family, boldness, and text size scaling',
    category: 'Settings › General',
    icon: Icons.font_download_outlined,
    route: '/more/settings/font',
    keywords: ['font', 'text', 'typography', 'bold', 'size', 'family'],
  ),
  SearchableSetting(
    title: 'Colours',
    subtitle: 'Custom tints for money in, money out, and people',
    category: 'Settings › General',
    icon: Icons.color_lens_outlined,
    route: '/more/settings/colours',
    keywords: ['colours', 'colors', 'tint', 'accent', 'green', 'red'],
  ),
  SearchableSetting(
    title: 'Customize Dashboard',
    subtitle: 'Add, remove, and reorder dashboard widgets and card layouts',
    category: 'Settings › General',
    icon: Icons.dashboard_customize_outlined,
    route: '/more/settings/dashboard',
    keywords: ['dashboard', 'widgets', 'layout', 'home', 'cards', 'reorder'],
  ),
  SearchableSetting(
    title: 'Customize Bottom Navigation',
    subtitle: 'Choose which navigation tabs appear next to the ➕ button',
    category: 'Settings › General',
    icon: Icons.tab_outlined,
    route: '/more/bottom-nav',
    keywords: ['bottom nav', 'navigation', 'tabs', 'bar', 'buttons', 'customize bar'],
  ),
  SearchableSetting(
    title: 'Calendar & Week Starts On',
    subtitle: 'Sunday/Monday week start, show day totals in calendar',
    category: 'Settings › General',
    icon: Icons.calendar_month_outlined,
    route: '/more/settings/general',
    keywords: ['calendar', 'week', 'sunday', 'monday', 'day totals', 'reminders'],
  ),

  // ── Security & Privacy ─────────────────────────────────────────────────────
  SearchableSetting(
    title: 'Passcode & PIN Lock',
    subtitle: 'Secure app access with 4-digit or 6-digit PIN',
    category: 'Settings › Security & Privacy',
    icon: Icons.lock_outline,
    route: '/more/settings/security',
    keywords: ['pin', 'passcode', 'lock', 'password', 'security', 'privacy'],
  ),
  SearchableSetting(
    title: 'Recovery Phrase (Master Phrase)',
    subtitle: 'Emergency 12-word mnemonic backup phrase for data recovery',
    category: 'Settings › Security & Privacy',
    icon: Icons.vpn_key_outlined,
    route: '/more/settings/security',
    keywords: ['recovery phrase', 'seed phrase', 'master phrase', 'mnemonic', 'backup phrase', 'emergency'],
  ),
  SearchableSetting(
    title: 'Authenticator App (TOTP 2FA)',
    subtitle: 'Two-factor authentication via Google Authenticator or Aegis',
    category: 'Settings › Security & Privacy',
    icon: Icons.phonelink_lock_outlined,
    route: '/more/settings/security',
    keywords: ['totp', 'authenticator', '2fa', 'two-factor', 'google authenticator', 'security code'],
  ),
  SearchableSetting(
    title: 'Biometric Unlock',
    subtitle: 'Fingerprint and Face Unlock device security',
    category: 'Settings › Security & Privacy',
    icon: Icons.fingerprint_rounded,
    route: '/more/settings/security',
    keywords: ['biometrics', 'fingerprint', 'face unlock', 'touch id', 'device unlock'],
  ),
  SearchableSetting(
    title: 'Screenshot Protection',
    subtitle: 'Block screenshots and screen recording on sensitive financial screens',
    category: 'Settings › Security & Privacy',
    icon: Icons.no_photography_outlined,
    route: '/more/settings/security',
    keywords: ['screenshot', 'screen recording', 'privacy', 'capture protection', 'block screenshot'],
  ),

  // ── Other Settings Modules ─────────────────────────────────────────────────
  SearchableSetting(
    title: 'Level & Budgeting',
    subtitle: 'App level (Basic / Medium / Pro), budget cycles, Ready to Assign',
    category: 'Settings',
    icon: Icons.savings_outlined,
    route: '/more/settings/mode-budgeting',
    keywords: ['level', 'budget', 'basic', 'medium', 'pro', 'budget cycle', 'ready to assign'],
  ),
  SearchableSetting(
    title: 'Persons & Repayments',
    subtitle: 'Repayments, payment methods, settled accounts',
    category: 'Settings',
    icon: Icons.people_outline,
    route: '/more/settings/persons',
    keywords: ['persons', 'friends', 'split', 'borrow', 'lend', 'repay', 'repayments'],
  ),
  SearchableSetting(
    title: 'Permissions',
    subtitle: 'Manage device permissions (notifications, storage, camera)',
    category: 'Settings',
    icon: Icons.verified_user_outlined,
    route: '/more/settings/permissions',
    keywords: ['permissions', 'access', 'privacy', 'camera', 'storage', 'notifications'],
  ),
  SearchableSetting(
    title: 'Notifications & Daily Reminders',
    subtitle: 'Daily expense reminders and budget alerts',
    category: 'Settings',
    icon: Icons.notifications_outlined,
    route: '/more/settings/notifications',
    keywords: ['notifications', 'reminder', 'reminders', 'daily alert', 'quick add'],
  ),
  SearchableSetting(
    title: 'Quick Actions & Home Widgets',
    subtitle: 'Long-press app icon shortcuts and Android home screen widgets',
    category: 'Settings',
    icon: Icons.flash_on_outlined,
    route: '/more/settings/quick-actions',
    keywords: ['quick actions', 'shortcuts', 'widgets', 'home screen', 'app shortcuts'],
  ),
  SearchableSetting(
    title: 'Data Management & Recalculate',
    subtitle: 'Recalculate balances to fix drift, clear cache, erase all data',
    category: 'Settings › Data',
    icon: Icons.storage_outlined,
    route: '/more/settings/data',
    keywords: ['data', 'recalculate', 'recalculate balances', 'clear data', 'reset', 'storage', 'drift'],
  ),
  SearchableSetting(
    title: 'Download Data (Export CSV / JSON)',
    subtitle: 'Export transactions to Excel CSV or full database JSON copy',
    category: 'Data',
    icon: Icons.download_outlined,
    route: '/more/export',
    keywords: ['export', 'download', 'csv', 'json', 'excel', 'sheets', 'transactions'],
  ),
  SearchableSetting(
    title: 'Import from File (JSON / CSV)',
    subtitle: 'Restore a JSON database export or import external bank CSV',
    category: 'Data',
    icon: Icons.file_upload_outlined,
    route: '/more/export',
    keywords: ['import', 'restore', 'json', 'csv', 'file', 'upload'],
  ),
  SearchableSetting(
    title: "What's new",
    subtitle: 'See what shipped in the latest release',
    category: 'About XPENC',
    icon: Icons.auto_awesome_outlined,
    route: '/more/whats-new',
    keywords: ['whats new', 'changelog', 'release notes', 'update', 'version', 'features'],
  ),
  SearchableSetting(
    title: 'Guide',
    subtitle: 'Every feature explained, plus Basic/Medium/Pro modes',
    category: 'About XPENC',
    icon: Icons.menu_book_outlined,
    route: '/more/guide',
    keywords: ['guide', 'help', 'tutorial', 'documentation', 'manual', 'explain', 'modes'],
  ),
];
