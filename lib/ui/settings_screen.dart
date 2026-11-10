/// Настройки (§8, §9): тема/язык — локальны; аккаунт и синхронизация —
/// раздел этапа 3. Выход спрашивает, оставить ли локальную копию (§9).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_engine.dart';
import 'app_theme.dart';
import 'common/sync_label.dart';
import 'debug_screen.dart';
import 'conflicts_screen.dart';
import 'providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final authAsync = ref.watch(authStateProvider);
    final syncAsync = ref.watch(syncStatusProvider);

    final authState = authAsync.value ?? const AuthSignedOut();
    final sync = syncAsync.value ?? const SyncStatus();

    return Container(
      color: sidebarBackground(context),
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            l10n.settings,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          _themeTile(context, ref, l10n, themeMode),
          _languageTile(context, ref, l10n, locale),
          const Divider(height: 32),
          _accountSection(context, ref, l10n, authState, sync),
          const Divider(height: 32),
          _conflictsTile(context, ref, l10n),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(l10n.debugTitle),
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(builder: (_) => const DebugScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _themeTile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    ThemeMode themeMode,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.themeLabel, style: Theme.of(context).textTheme.titleSmall),
        Text(switch (themeMode) {
          ThemeMode.light => l10n.themeLight,
          ThemeMode.dark => l10n.themeDark,
          ThemeMode.system => l10n.themeSystem,
        }, style: mutedStyle(context)),
        const SizedBox(height: 8),
        SizedBox(
          width: 260,
          child: SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(
                value: ThemeMode.light,
                icon: const Icon(Icons.light_mode, size: 18),
                tooltip: l10n.themeLight,
              ),
              ButtonSegment(
                value: ThemeMode.system,
                icon: const Icon(Icons.settings_suggest, size: 18),
                tooltip: l10n.themeSystem,
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: const Icon(Icons.dark_mode, size: 18),
                tooltip: l10n.themeDark,
              ),
            ],
            selected: {themeMode},
            onSelectionChanged: (selection) =>
                ref.read(themeModeProvider.notifier).set(selection.first),
          ),
        ),
      ],
    );
  }

  Widget _languageTile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Locale? locale,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.languageLabel, style: Theme.of(context).textTheme.titleSmall),
        Text(
          locale == null
              ? l10n.systemLanguage
              : (locale.languageCode == 'uk' ? 'Українська' : 'English'),
          style: mutedStyle(context),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 260,
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'system',
                icon: const Icon(Icons.settings_suggest, size: 18),
                tooltip: l10n.systemLanguage,
              ),
              const ButtonSegment(value: 'uk', label: Text('UA')),
              const ButtonSegment(value: 'en', label: Text('EN')),
            ],
            selected: {locale?.languageCode ?? 'system'},
            onSelectionChanged: (selection) {
              final value = selection.first;
              ref
                  .read(localeProvider.notifier)
                  .set(value == 'system' ? null : Locale(value));
            },
          ),
        ),
      ],
    );
  }

  Widget _accountSection(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    AuthState authState,
    SyncStatus sync,
  ) {
    final auth = ref.watch(authServiceProvider);
    final engine = ref.watch(syncEngineProvider);

    // Состояние входа.
    final accountTile = switch (authState) {
      AuthSignedOut() => ListTile(
        leading: const Icon(Icons.cloud_off),
        title: Text(l10n.syncOff),
        subtitle: Text(l10n.accountLocalOnly, style: mutedStyle(context)),
      ),
      AuthNeedsReauth(:final email) => ListTile(
        leading: const Icon(Icons.refresh),
        title: Text(l10n.reauthNeeded),
        subtitle: Text(email ?? '', style: mutedStyle(context)),
      ),
      AuthSignedIn(:final session) => ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(session.email ?? l10n.signedInAs),
        subtitle: Text(
          '${l10n.uidLabel}: ${session.uid}',
          style: mutedStyle(context),
        ),
      ),
    };

    // Статус синхронизации (§10): ошибка видна, повтор с backoff.
    final syncSubtitle = syncStatusLabel(l10n, sync, withDetails: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.accountSection,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        accountTile,
        if (authState is AuthSignedIn) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (sync.running)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        sync.error != null ? Icons.sync_problem : Icons.sync,
                        size: 18,
                        color: sync.error != null
                            ? Theme.of(context).colorScheme.error
                            : mutedText(context),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        syncSubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: sync.running ? null : engine.syncNow,
                      child: Text(l10n.syncNow),
                    ),
                  ],
                ),
                Text(
                  l10n.pendingChangesN(sync.pendingOps),
                  style: mutedStyle(context),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(l10n.signOut),
            onTap: () => _signOutFlow(context, ref, auth, sync),
          ),
        ],
        if (authState is! AuthSignedIn)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: FilledButton.icon(
              icon: const Icon(Icons.login, size: 18),
              label: Text(l10n.signIn),
              onPressed: () async {
                try {
                  final session = await auth.signIn();
                  // Первый вход объединяет локальные и облачные записи (§9).
                  await engine.initialMerge();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${l10n.signedInAs} ${session.email ?? ''}',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    // Ошибка входа должна быть видима, пока её не закрыли
                    // (диагностика §9: invalid_client / network / и т.п.).
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(l10n.signInFailed),
                        content: SingleChildScrollView(
                          child: SelectableText('${l10n.errorDetails}: $e'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(l10n.ok),
                          ),
                        ],
                      ),
                    );
                  }
                }
              },
            ),
          ),
      ],
    );
  }

  /// Выход (§9): вопрос о локальной копии; предупреждение о
  /// несинхронизированных изменениях перед удалением.
  Future<void> _signOutFlow(
    BuildContext context,
    WidgetRef ref,
    AuthService auth,
    SyncStatus sync,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final keep = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.signOutQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.removeLocalCopy),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.keepLocalCopy),
          ),
        ],
      ),
    );
    if (keep == null || !context.mounted) return;
    if (!keep && sync.pendingOps > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(l10n.unsavedWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.removeLocalCopy),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await auth.signOut(keepLocalCopy: keep);
    if (!keep) {
      await auth.rebootstrapAfterWipe();
    }
    ref.read(syncEngineProvider).stop();
  }

  Widget _conflictsTile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final db = ref.watch(appDatabaseProvider);
    return ListTile(
      leading: const Icon(Icons.merge_type),
      title: Text(l10n.conflicts),
      subtitle: StreamBuilder<int>(
        stream: db.select(db.conflicts).watch().map((r) => r.length),
        builder: (context, snap) =>
            Text('${snap.data ?? 0}', style: mutedStyle(context)),
      ),
      onTap: () {
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(builder: (_) => const ConflictsScreen()),
        );
      },
    );
  }
}
