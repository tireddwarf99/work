import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_uk.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('uk'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In uk, this message translates to:
  /// **'Нотатки'**
  String get appTitle;

  /// No description provided for @create.
  ///
  /// In uk, this message translates to:
  /// **'Створити'**
  String get create;

  /// No description provided for @newNote.
  ///
  /// In uk, this message translates to:
  /// **'Нова нотатка'**
  String get newNote;

  /// No description provided for @search.
  ///
  /// In uk, this message translates to:
  /// **'Пошук'**
  String get search;

  /// No description provided for @dashboard.
  ///
  /// In uk, this message translates to:
  /// **'Огляд'**
  String get dashboard;

  /// No description provided for @notes.
  ///
  /// In uk, this message translates to:
  /// **'Нотатки'**
  String get notes;

  /// No description provided for @allLists.
  ///
  /// In uk, this message translates to:
  /// **'Усі списки'**
  String get allLists;

  /// No description provided for @trash.
  ///
  /// In uk, this message translates to:
  /// **'Кошик'**
  String get trash;

  /// No description provided for @folders.
  ///
  /// In uk, this message translates to:
  /// **'ПАПКИ'**
  String get folders;

  /// No description provided for @tags.
  ///
  /// In uk, this message translates to:
  /// **'ТЕГИ'**
  String get tags;

  /// No description provided for @settings.
  ///
  /// In uk, this message translates to:
  /// **'Налаштування'**
  String get settings;

  /// No description provided for @synced.
  ///
  /// In uk, this message translates to:
  /// **'Синхронізовано'**
  String get synced;

  /// No description provided for @notSynced.
  ///
  /// In uk, this message translates to:
  /// **'Не синхронізовано'**
  String get notSynced;

  /// No description provided for @today.
  ///
  /// In uk, this message translates to:
  /// **'Сьогодні'**
  String get today;

  /// No description provided for @dueSoon.
  ///
  /// In uk, this message translates to:
  /// **'Наближається термін'**
  String get dueSoon;

  /// No description provided for @thisWeek.
  ///
  /// In uk, this message translates to:
  /// **'Цього тижня'**
  String get thisWeek;

  /// No description provided for @general.
  ///
  /// In uk, this message translates to:
  /// **'Загальні'**
  String get general;

  /// No description provided for @overdue.
  ///
  /// In uk, this message translates to:
  /// **'Пропущені'**
  String get overdue;

  /// No description provided for @inbox.
  ///
  /// In uk, this message translates to:
  /// **'Вхідні'**
  String get inbox;

  /// No description provided for @untitled.
  ///
  /// In uk, this message translates to:
  /// **'Без назви'**
  String get untitled;

  /// No description provided for @noTime.
  ///
  /// In uk, this message translates to:
  /// **'Без часу'**
  String get noTime;

  /// No description provided for @tomorrow.
  ///
  /// In uk, this message translates to:
  /// **'Завтра'**
  String get tomorrow;

  /// No description provided for @yesterday.
  ///
  /// In uk, this message translates to:
  /// **'Вчора'**
  String get yesterday;

  /// No description provided for @noFolder.
  ///
  /// In uk, this message translates to:
  /// **'Без папки'**
  String get noFolder;

  /// No description provided for @addTask.
  ///
  /// In uk, this message translates to:
  /// **'Додати завдання'**
  String get addTask;

  /// No description provided for @completedN.
  ///
  /// In uk, this message translates to:
  /// **'Виконані · {n}'**
  String completedN(int n);

  /// No description provided for @note.
  ///
  /// In uk, this message translates to:
  /// **'Нотатка'**
  String get note;

  /// No description provided for @task.
  ///
  /// In uk, this message translates to:
  /// **'Завдання'**
  String get task;

  /// No description provided for @descriptionLabel.
  ///
  /// In uk, this message translates to:
  /// **'ОПИС'**
  String get descriptionLabel;

  /// No description provided for @dueLabel.
  ///
  /// In uk, this message translates to:
  /// **'Термін'**
  String get dueLabel;

  /// No description provided for @priorityLabel.
  ///
  /// In uk, this message translates to:
  /// **'Пріоритет'**
  String get priorityLabel;

  /// No description provided for @tagsLabel.
  ///
  /// In uk, this message translates to:
  /// **'Теги'**
  String get tagsLabel;

  /// No description provided for @subtasksLabel.
  ///
  /// In uk, this message translates to:
  /// **'Підзавдання'**
  String get subtasksLabel;

  /// No description provided for @priorityHigh.
  ///
  /// In uk, this message translates to:
  /// **'Високий'**
  String get priorityHigh;

  /// No description provided for @priorityNormal.
  ///
  /// In uk, this message translates to:
  /// **'Звичайний'**
  String get priorityNormal;

  /// No description provided for @priorityLow.
  ///
  /// In uk, this message translates to:
  /// **'Низький'**
  String get priorityLow;

  /// No description provided for @noDescription.
  ///
  /// In uk, this message translates to:
  /// **'Додати опис…'**
  String get noDescription;

  /// No description provided for @noDue.
  ///
  /// In uk, this message translates to:
  /// **'Додати термін'**
  String get noDue;

  /// No description provided for @noTags.
  ///
  /// In uk, this message translates to:
  /// **'Додати теги'**
  String get noTags;

  /// No description provided for @sortMode.
  ///
  /// In uk, this message translates to:
  /// **'Сортування'**
  String get sortMode;

  /// No description provided for @sortManual.
  ///
  /// In uk, this message translates to:
  /// **'Вручну'**
  String get sortManual;

  /// No description provided for @sortDue.
  ///
  /// In uk, this message translates to:
  /// **'За терміном'**
  String get sortDue;

  /// No description provided for @sortPriority.
  ///
  /// In uk, this message translates to:
  /// **'За пріоритетом'**
  String get sortPriority;

  /// No description provided for @delete.
  ///
  /// In uk, this message translates to:
  /// **'Видалити'**
  String get delete;

  /// No description provided for @restore.
  ///
  /// In uk, this message translates to:
  /// **'Відновити'**
  String get restore;

  /// No description provided for @cancel.
  ///
  /// In uk, this message translates to:
  /// **'Скасувати'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In uk, this message translates to:
  /// **'Гаразд'**
  String get ok;

  /// No description provided for @completeBranchTitle.
  ///
  /// In uk, this message translates to:
  /// **'Виконати гілку'**
  String get completeBranchTitle;

  /// No description provided for @completeBranchQuestion.
  ///
  /// In uk, this message translates to:
  /// **'У завдання є незавершені підзавдання. Виконати всю гілку?'**
  String get completeBranchQuestion;

  /// No description provided for @deleteTaskConfirm.
  ///
  /// In uk, this message translates to:
  /// **'Видалити завдання з підзавданнями у кошик?'**
  String get deleteTaskConfirm;

  /// No description provided for @deleteNoteConfirm.
  ///
  /// In uk, this message translates to:
  /// **'Видалити нотатку у кошик?'**
  String get deleteNoteConfirm;

  /// No description provided for @deleteFolderConfirm.
  ///
  /// In uk, this message translates to:
  /// **'Видалити папку з усім вмістом у кошик?'**
  String get deleteFolderConfirm;

  /// No description provided for @trashEmpty.
  ///
  /// In uk, this message translates to:
  /// **'Кошик порожній'**
  String get trashEmpty;

  /// No description provided for @searchHint.
  ///
  /// In uk, this message translates to:
  /// **'Пошук нотаток і завдань'**
  String get searchHint;

  /// No description provided for @noResults.
  ///
  /// In uk, this message translates to:
  /// **'Нічого не знайдено'**
  String get noResults;

  /// No description provided for @movedToNoFolderHint.
  ///
  /// In uk, this message translates to:
  /// **'Початкова папка видалена — нотатку відновлено без папки.'**
  String get movedToNoFolderHint;

  /// No description provided for @themeLight.
  ///
  /// In uk, this message translates to:
  /// **'Світла'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In uk, this message translates to:
  /// **'Темна'**
  String get themeDark;

  /// No description provided for @themeSystem.
  ///
  /// In uk, this message translates to:
  /// **'Як у системі'**
  String get themeSystem;

  /// No description provided for @themeLabel.
  ///
  /// In uk, this message translates to:
  /// **'Тема'**
  String get themeLabel;

  /// No description provided for @languageLabel.
  ///
  /// In uk, this message translates to:
  /// **'Мова'**
  String get languageLabel;

  /// No description provided for @systemLanguage.
  ///
  /// In uk, this message translates to:
  /// **'Системна'**
  String get systemLanguage;

  /// No description provided for @accountSection.
  ///
  /// In uk, this message translates to:
  /// **'Акаунт'**
  String get accountSection;

  /// No description provided for @accountLocalOnly.
  ///
  /// In uk, this message translates to:
  /// **'Хмара не підключена — усе зберігається локально (етап 3).'**
  String get accountLocalOnly;

  /// No description provided for @pinned.
  ///
  /// In uk, this message translates to:
  /// **'Закріплені'**
  String get pinned;

  /// No description provided for @pin.
  ///
  /// In uk, this message translates to:
  /// **'Закріпити'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In uk, this message translates to:
  /// **'Відкріпити'**
  String get unpin;

  /// No description provided for @moveToFolder.
  ///
  /// In uk, this message translates to:
  /// **'Перемістити…'**
  String get moveToFolder;

  /// No description provided for @embeddedFrom.
  ///
  /// In uk, this message translates to:
  /// **'вбудований · {source}'**
  String embeddedFrom(String source);

  /// No description provided for @emptyNotes.
  ///
  /// In uk, this message translates to:
  /// **'Нотаток немає'**
  String get emptyNotes;

  /// No description provided for @emptyNotesHint.
  ///
  /// In uk, this message translates to:
  /// **'Створіть першу нотатку'**
  String get emptyNotesHint;

  /// No description provided for @signIn.
  ///
  /// In uk, this message translates to:
  /// **'Увійти через Google'**
  String get signIn;

  /// No description provided for @signOut.
  ///
  /// In uk, this message translates to:
  /// **'Вийти'**
  String get signOut;

  /// No description provided for @signOutQuestion.
  ///
  /// In uk, this message translates to:
  /// **'Залишити локальну копію даних на цьому пристрої?'**
  String get signOutQuestion;

  /// No description provided for @keepLocalCopy.
  ///
  /// In uk, this message translates to:
  /// **'Залишити копію'**
  String get keepLocalCopy;

  /// No description provided for @removeLocalCopy.
  ///
  /// In uk, this message translates to:
  /// **'Видалити локальні дані'**
  String get removeLocalCopy;

  /// No description provided for @unsavedWarning.
  ///
  /// In uk, this message translates to:
  /// **'Є несинхронізовані зміни — при видаленні локальної копії їх буде втрачено.'**
  String get unsavedWarning;

  /// No description provided for @signedInAs.
  ///
  /// In uk, this message translates to:
  /// **'Вхід виконано'**
  String get signedInAs;

  /// No description provided for @syncNow.
  ///
  /// In uk, this message translates to:
  /// **'Синхронізувати зараз'**
  String get syncNow;

  /// No description provided for @syncOff.
  ///
  /// In uk, this message translates to:
  /// **'Хмара не підключена'**
  String get syncOff;

  /// No description provided for @syncError.
  ///
  /// In uk, this message translates to:
  /// **'Помилка синхронізації'**
  String get syncError;

  /// No description provided for @syncPermission.
  ///
  /// In uk, this message translates to:
  /// **'Доступ заборонено правилами — потрібен UID власника у Security Rules'**
  String get syncPermission;

  /// No description provided for @workspaceMismatch.
  ///
  /// In uk, this message translates to:
  /// **'Локальні дані належать іншому акаунту — синхронізація зупинена'**
  String get workspaceMismatch;

  /// No description provided for @conflicts.
  ///
  /// In uk, this message translates to:
  /// **'Конфлікти'**
  String get conflicts;

  /// No description provided for @conflictKeepLocal.
  ///
  /// In uk, this message translates to:
  /// **'Залишити локальну'**
  String get conflictKeepLocal;

  /// No description provided for @conflictKeepRemote.
  ///
  /// In uk, this message translates to:
  /// **'Залишити хмарну'**
  String get conflictKeepRemote;

  /// No description provided for @conflictsNone.
  ///
  /// In uk, this message translates to:
  /// **'Нерозв\'язаних конфліктів немає'**
  String get conflictsNone;

  /// No description provided for @uidLabel.
  ///
  /// In uk, this message translates to:
  /// **'UID'**
  String get uidLabel;

  /// No description provided for @reauthNeeded.
  ///
  /// In uk, this message translates to:
  /// **'Потрібен повторний вхід'**
  String get reauthNeeded;

  /// No description provided for @debugTitle.
  ///
  /// In uk, this message translates to:
  /// **'Діагностика'**
  String get debugTitle;

  /// No description provided for @debugCopyLog.
  ///
  /// In uk, this message translates to:
  /// **'Копіювати журнал'**
  String get debugCopyLog;

  /// No description provided for @debugCopied.
  ///
  /// In uk, this message translates to:
  /// **'Журнал скопійовано'**
  String get debugCopied;

  /// No description provided for @debugInitialMerge.
  ///
  /// In uk, this message translates to:
  /// **'Об\'єднати з хмарою'**
  String get debugInitialMerge;

  /// No description provided for @debugLogTitle.
  ///
  /// In uk, this message translates to:
  /// **'Журнал подій'**
  String get debugLogTitle;

  /// No description provided for @debugLogEmpty.
  ///
  /// In uk, this message translates to:
  /// **'Поки що подій немає'**
  String get debugLogEmpty;

  /// No description provided for @debugAcceptSnapshot.
  ///
  /// In uk, this message translates to:
  /// **'Прийняти новий знімок'**
  String get debugAcceptSnapshot;

  /// No description provided for @debugAcceptSnapshotWarning.
  ///
  /// In uk, this message translates to:
  /// **'Сервер перейшов на новий знімок даних. Прийняття затре несинхронізовані локальні зміни. Прийняти новий знімок?'**
  String get debugAcceptSnapshotWarning;

  /// No description provided for @newFolder.
  ///
  /// In uk, this message translates to:
  /// **'Нова папка'**
  String get newFolder;

  /// No description provided for @folderNameHint.
  ///
  /// In uk, this message translates to:
  /// **'Назва папки'**
  String get folderNameHint;

  /// No description provided for @rename.
  ///
  /// In uk, this message translates to:
  /// **'Перейменувати'**
  String get rename;

  /// No description provided for @newList.
  ///
  /// In uk, this message translates to:
  /// **'Новий список'**
  String get newList;

  /// No description provided for @listTitleHint.
  ///
  /// In uk, this message translates to:
  /// **'Назва списку'**
  String get listTitleHint;

  /// No description provided for @deleteListConfirm.
  ///
  /// In uk, this message translates to:
  /// **'Видалити список із завданнями у кошик?'**
  String get deleteListConfirm;

  /// No description provided for @taskTextHint.
  ///
  /// In uk, this message translates to:
  /// **'Що потрібно зробити?'**
  String get taskTextHint;

  /// No description provided for @subtaskHint.
  ///
  /// In uk, this message translates to:
  /// **'Назва підзавдання'**
  String get subtaskHint;

  /// No description provided for @noteTitleHint.
  ///
  /// In uk, this message translates to:
  /// **'Назва нотатки'**
  String get noteTitleHint;

  /// No description provided for @noteBodyHint.
  ///
  /// In uk, this message translates to:
  /// **'Почніть писати…'**
  String get noteBodyHint;

  /// No description provided for @tagNameHint.
  ///
  /// In uk, this message translates to:
  /// **'Назва нового тега'**
  String get tagNameHint;

  /// No description provided for @saveFailed.
  ///
  /// In uk, this message translates to:
  /// **'Не вдалося зберегти нотатку. Зміни залишаються в редакторі.'**
  String get saveFailed;

  /// No description provided for @emptyListHint.
  ///
  /// In uk, this message translates to:
  /// **'У списку ще немає завдань'**
  String get emptyListHint;

  /// No description provided for @openList.
  ///
  /// In uk, this message translates to:
  /// **'Відкрити список'**
  String get openList;

  /// No description provided for @close.
  ///
  /// In uk, this message translates to:
  /// **'Закрити'**
  String get close;

  /// No description provided for @settingsTooltip.
  ///
  /// In uk, this message translates to:
  /// **'Налаштування'**
  String get settingsTooltip;

  /// No description provided for @changeDate.
  ///
  /// In uk, this message translates to:
  /// **'Змінити дату'**
  String get changeDate;

  /// No description provided for @setTime.
  ///
  /// In uk, this message translates to:
  /// **'Вказати час'**
  String get setTime;

  /// No description provided for @removeTime.
  ///
  /// In uk, this message translates to:
  /// **'Прибрати час'**
  String get removeTime;

  /// No description provided for @clearDue.
  ///
  /// In uk, this message translates to:
  /// **'Прибрати термін'**
  String get clearDue;

  /// No description provided for @syncing.
  ///
  /// In uk, this message translates to:
  /// **'Синхронізація…'**
  String get syncing;

  /// No description provided for @pendingChangesN.
  ///
  /// In uk, this message translates to:
  /// **'Очікують синхронізації: {n}'**
  String pendingChangesN(int n);

  /// No description provided for @epochSwitchPending.
  ///
  /// In uk, this message translates to:
  /// **'Потрібне рішення щодо нового знімка (Діагностика)'**
  String get epochSwitchPending;

  /// No description provided for @signInFailed.
  ///
  /// In uk, this message translates to:
  /// **'Не вдалося увійти'**
  String get signInFailed;

  /// No description provided for @errorDetails.
  ///
  /// In uk, this message translates to:
  /// **'Деталі'**
  String get errorDetails;

  /// No description provided for @actionFailed.
  ///
  /// In uk, this message translates to:
  /// **'Не вдалося виконати дію'**
  String get actionFailed;

  /// No description provided for @dropForbidden.
  ///
  /// In uk, this message translates to:
  /// **'Таке переміщення неможливе'**
  String get dropForbidden;

  /// No description provided for @restored.
  ///
  /// In uk, this message translates to:
  /// **'Відновлено'**
  String get restored;

  /// No description provided for @folder.
  ///
  /// In uk, this message translates to:
  /// **'Папка'**
  String get folder;

  /// No description provided for @yes.
  ///
  /// In uk, this message translates to:
  /// **'так'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In uk, this message translates to:
  /// **'ні'**
  String get no;

  /// No description provided for @debugSession.
  ///
  /// In uk, this message translates to:
  /// **'Сесія: {value}'**
  String debugSession(String value);

  /// No description provided for @debugSync.
  ///
  /// In uk, this message translates to:
  /// **'Синхронізація: {running} · остання: {last} · у черзі: {pending}'**
  String debugSync(String running, String last, int pending);

  /// No description provided for @debugIdle.
  ///
  /// In uk, this message translates to:
  /// **'очікує'**
  String get debugIdle;

  /// No description provided for @debugError.
  ///
  /// In uk, this message translates to:
  /// **'Помилка: {error} (доступ заборонено: {denied}, інший акаунт: {mismatch})'**
  String debugError(String error, String denied, String mismatch);

  /// No description provided for @debugCounters.
  ///
  /// In uk, this message translates to:
  /// **'У черзі: {outbox} · конфлікти: {conflicts}'**
  String debugCounters(int outbox, int conflicts);

  /// No description provided for @conflictEntity.
  ///
  /// In uk, this message translates to:
  /// **'{type} · {id}'**
  String conflictEntity(String type, String id);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'uk'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'uk':
      return AppLocalizationsUk();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
