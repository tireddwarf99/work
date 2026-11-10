// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Ukrainian (`uk`).
class AppLocalizationsUk extends AppLocalizations {
  AppLocalizationsUk([String locale = 'uk']) : super(locale);

  @override
  String get appTitle => 'Нотатки';

  @override
  String get create => 'Створити';

  @override
  String get newNote => 'Нова нотатка';

  @override
  String get search => 'Пошук';

  @override
  String get dashboard => 'Огляд';

  @override
  String get notes => 'Нотатки';

  @override
  String get allLists => 'Усі списки';

  @override
  String get trash => 'Кошик';

  @override
  String get folders => 'ПАПКИ';

  @override
  String get tags => 'ТЕГИ';

  @override
  String get settings => 'Налаштування';

  @override
  String get synced => 'Синхронізовано';

  @override
  String get notSynced => 'Не синхронізовано';

  @override
  String get today => 'Сьогодні';

  @override
  String get dueSoon => 'Наближається термін';

  @override
  String get thisWeek => 'Цього тижня';

  @override
  String get general => 'Загальні';

  @override
  String get overdue => 'Пропущені';

  @override
  String get inbox => 'Вхідні';

  @override
  String get untitled => 'Без назви';

  @override
  String get noTime => 'Без часу';

  @override
  String get tomorrow => 'Завтра';

  @override
  String get yesterday => 'Вчора';

  @override
  String get noFolder => 'Без папки';

  @override
  String get addTask => 'Додати завдання';

  @override
  String completedN(int n) {
    return 'Виконані · $n';
  }

  @override
  String get note => 'Нотатка';

  @override
  String get task => 'Завдання';

  @override
  String get descriptionLabel => 'ОПИС';

  @override
  String get dueLabel => 'Термін';

  @override
  String get priorityLabel => 'Пріоритет';

  @override
  String get tagsLabel => 'Теги';

  @override
  String get subtasksLabel => 'Підзавдання';

  @override
  String get priorityHigh => 'Високий';

  @override
  String get priorityNormal => 'Звичайний';

  @override
  String get priorityLow => 'Низький';

  @override
  String get noDescription => 'Додати опис…';

  @override
  String get noDue => 'Додати термін';

  @override
  String get noTags => 'Додати теги';

  @override
  String get sortMode => 'Сортування';

  @override
  String get sortManual => 'Вручну';

  @override
  String get sortDue => 'За терміном';

  @override
  String get sortPriority => 'За пріоритетом';

  @override
  String get delete => 'Видалити';

  @override
  String get restore => 'Відновити';

  @override
  String get cancel => 'Скасувати';

  @override
  String get ok => 'Гаразд';

  @override
  String get completeBranchTitle => 'Виконати гілку';

  @override
  String get completeBranchQuestion =>
      'У завдання є незавершені підзавдання. Виконати всю гілку?';

  @override
  String get deleteTaskConfirm => 'Видалити завдання з підзавданнями у кошик?';

  @override
  String get deleteNoteConfirm => 'Видалити нотатку у кошик?';

  @override
  String get deleteFolderConfirm => 'Видалити папку з усім вмістом у кошик?';

  @override
  String get trashEmpty => 'Кошик порожній';

  @override
  String get searchHint => 'Пошук нотаток і завдань';

  @override
  String get noResults => 'Нічого не знайдено';

  @override
  String get movedToNoFolderHint =>
      'Початкова папка видалена — нотатку відновлено без папки.';

  @override
  String get themeLight => 'Світла';

  @override
  String get themeDark => 'Темна';

  @override
  String get themeSystem => 'Як у системі';

  @override
  String get themeLabel => 'Тема';

  @override
  String get languageLabel => 'Мова';

  @override
  String get systemLanguage => 'Системна';

  @override
  String get accountSection => 'Акаунт';

  @override
  String get accountLocalOnly =>
      'Хмара не підключена — усе зберігається локально (етап 3).';

  @override
  String get pinned => 'Закріплені';

  @override
  String get pin => 'Закріпити';

  @override
  String get unpin => 'Відкріпити';

  @override
  String get moveToFolder => 'Перемістити…';

  @override
  String embeddedFrom(String source) {
    return 'вбудований · $source';
  }

  @override
  String get emptyNotes => 'Нотаток немає';

  @override
  String get emptyNotesHint => 'Створіть першу нотатку';

  @override
  String get signIn => 'Увійти через Google';

  @override
  String get signOut => 'Вийти';

  @override
  String get signOutQuestion =>
      'Залишити локальну копію даних на цьому пристрої?';

  @override
  String get keepLocalCopy => 'Залишити копію';

  @override
  String get removeLocalCopy => 'Видалити локальні дані';

  @override
  String get unsavedWarning =>
      'Є несинхронізовані зміни — при видаленні локальної копії їх буде втрачено.';

  @override
  String get signedInAs => 'Вхід виконано';

  @override
  String get syncNow => 'Синхронізувати зараз';

  @override
  String get syncOff => 'Хмара не підключена';

  @override
  String get syncError => 'Помилка синхронізації';

  @override
  String get syncPermission =>
      'Доступ заборонено правилами — потрібен UID власника у Security Rules';

  @override
  String get workspaceMismatch =>
      'Локальні дані належать іншому акаунту — синхронізація зупинена';

  @override
  String get conflicts => 'Конфлікти';

  @override
  String get conflictKeepLocal => 'Залишити локальну';

  @override
  String get conflictKeepRemote => 'Залишити хмарну';

  @override
  String get conflictsNone => 'Нерозв\'язаних конфліктів немає';

  @override
  String get uidLabel => 'UID';

  @override
  String get reauthNeeded => 'Потрібен повторний вхід';

  @override
  String get debugTitle => 'Діагностика';

  @override
  String get debugCopyLog => 'Копіювати журнал';

  @override
  String get debugCopied => 'Журнал скопійовано';

  @override
  String get debugInitialMerge => 'Об\'єднати з хмарою';

  @override
  String get debugLogTitle => 'Журнал подій';

  @override
  String get debugLogEmpty => 'Поки що подій немає';

  @override
  String get debugAcceptSnapshot => 'Прийняти новий знімок';

  @override
  String get debugAcceptSnapshotWarning =>
      'Сервер перейшов на новий знімок даних. Прийняття затре несинхронізовані локальні зміни. Прийняти новий знімок?';

  @override
  String get newFolder => 'Нова папка';

  @override
  String get folderNameHint => 'Назва папки';

  @override
  String get rename => 'Перейменувати';

  @override
  String get newList => 'Новий список';

  @override
  String get listTitleHint => 'Назва списку';

  @override
  String get deleteListConfirm => 'Видалити список із завданнями у кошик?';

  @override
  String get taskTextHint => 'Що потрібно зробити?';

  @override
  String get subtaskHint => 'Назва підзавдання';

  @override
  String get noteTitleHint => 'Назва нотатки';

  @override
  String get noteBodyHint => 'Почніть писати…';

  @override
  String get tagNameHint => 'Назва нового тега';

  @override
  String get saveFailed =>
      'Не вдалося зберегти нотатку. Зміни залишаються в редакторі.';

  @override
  String get emptyListHint => 'У списку ще немає завдань';

  @override
  String get openList => 'Відкрити список';

  @override
  String get close => 'Закрити';

  @override
  String get settingsTooltip => 'Налаштування';

  @override
  String get changeDate => 'Змінити дату';

  @override
  String get setTime => 'Вказати час';

  @override
  String get removeTime => 'Прибрати час';

  @override
  String get clearDue => 'Прибрати термін';

  @override
  String get syncing => 'Синхронізація…';

  @override
  String pendingChangesN(int n) {
    return 'Очікують синхронізації: $n';
  }

  @override
  String get epochSwitchPending =>
      'Потрібне рішення щодо нового знімка (Діагностика)';

  @override
  String get signInFailed => 'Не вдалося увійти';

  @override
  String get errorDetails => 'Деталі';

  @override
  String get actionFailed => 'Не вдалося виконати дію';

  @override
  String get dropForbidden => 'Таке переміщення неможливе';

  @override
  String get restored => 'Відновлено';

  @override
  String get folder => 'Папка';

  @override
  String get yes => 'так';

  @override
  String get no => 'ні';

  @override
  String debugSession(String value) {
    return 'Сесія: $value';
  }

  @override
  String debugSync(String running, String last, int pending) {
    return 'Синхронізація: $running · остання: $last · у черзі: $pending';
  }

  @override
  String get debugIdle => 'очікує';

  @override
  String debugError(String error, String denied, String mismatch) {
    return 'Помилка: $error (доступ заборонено: $denied, інший акаунт: $mismatch)';
  }

  @override
  String debugCounters(int outbox, int conflicts) {
    return 'У черзі: $outbox · конфлікти: $conflicts';
  }

  @override
  String conflictEntity(String type, String id) {
    return '$type · $id';
  }
}
