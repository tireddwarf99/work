/// Точка входа: платформенная оболочка (Windows — три панели, Android —
/// нижняя навигация), тема «Как в системе» по умолчанию (§8), локаль
/// «системная украинская → украинский, остальные → английский» (§8).
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth/auth_service.dart';
import 'l10n/app_localizations.dart';
import 'sync/sync_engine.dart';
import 'ui/app_theme.dart';
import 'ui/editor/note_editor.dart';
import 'ui/lists/lists_screen.dart';
import 'ui/providers.dart';
import 'ui/share/share_handler.dart';
import 'ui/shell/android_shell.dart';
import 'ui/shell/windows_shell.dart';
import 'ui/task_details/task_details.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    developer.log(
      'Flutter error',
      name: 'app',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  // Необработанные асинхронные ошибки вне дерева виджетов.
  PlatformDispatcher.instance.onError = (error, stack) {
    developer.log(
      'Uncaught error',
      name: 'app',
      error: error,
      stackTrace: stack,
    );
    return true;
  };
  runApp(const ProviderScope(child: NotesApp()));
}

class NotesApp extends ConsumerStatefulWidget {
  const NotesApp({super.key});

  @override
  ConsumerState<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends ConsumerState<NotesApp> {
  /// Роутер создаётся один раз: пересоздание в build() сбрасывало бы
  /// навигацию при каждой смене темы или языка.
  late final GoRouter _router = _buildRouter();

  @override
  void initState() {
    super.initState();
    // Корзина (§11): записи старше 30 дней удаляются при запуске.
    ref.read(trashServiceProvider).purgeExpired().catchError((
      Object e,
      StackTrace s,
    ) {
      developer.log('Trash purge failed', name: 'app', error: e, stackTrace: s);
      return 0;
    });
    // Android «Поделиться» (§8): текст/URL → заметка либо задача во
    // «Входящих».
    registerShareHandler((text) {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      showShareTargetDialog(context, ref, text);
    });
    // Движок синхронизации: старт при входе, остановка при выходе (§10).
    ref.listenManual(authStateProvider, (previous, next) {
      final engine = ref.read(syncEngineProvider);
      final state = next.value;
      if (state is AuthSignedIn) {
        engine.start();
      } else if (state is AuthSignedOut) {
        engine.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final manualLocale = ref.watch(localeProvider);

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      routerConfig: _router,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('uk'), Locale('en')],
      localeResolutionCallback: (deviceLocale, supported) {
        // Ручной выбор имеет приоритет (§8).
        final manual = ref.read(localeProvider);
        if (manual != null) return manual;
        // Системный украинский → украинский, остальные → английский (§8).
        if (deviceLocale?.languageCode == 'uk') {
          return const Locale('uk');
        }
        return const Locale('en');
      },
      locale: manualLocale,
    );
  }

  GoRouter _buildRouter() {
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    return GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/',
      routes: [
        if (isDesktop)
          GoRoute(path: '/', builder: (context, state) => const WindowsShell())
        else ...[
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) =>
                AndroidShell(navigationShell: shell),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (context, state) => const AndroidDashboardTab(),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/notes',
                    builder: (context, state) => const AndroidNotesTab(),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/lists',
                    builder: (context, state) => const AndroidListsTab(),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/note/:id',
            builder: (context, state) => Scaffold(
              appBar: AppBar(
                leading: const BackButton(),
                title: Text(AppLocalizations.of(context)!.note),
              ),
              body: NoteEditorRoute(noteId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/list/:id',
            builder: (context, state) => ListDetailScreen(
              listId: state.pathParameters['id']!,
              onOpenTask: (task) => context.push('/task/${task.id}'),
            ),
          ),
          GoRoute(
            path: '/task/:id',
            builder: (context, state) =>
                TaskDetails(taskId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const AndroidSettingsScreen(),
          ),
        ],
      ],
    );
  }
}

/// Обёртка редактора для отдельного маршрута Android.
class NoteEditorRoute extends ConsumerWidget {
  final String noteId;

  const NoteEditorRoute({super.key, required this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NoteEditor(
      noteId: noteId,
      onOpenTask: (task) => context.push('/task/${task.id}'),
    );
  }
}
