// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Notes';

  @override
  String get create => 'Create';

  @override
  String get newNote => 'New note';

  @override
  String get newTask => 'Add task';

  @override
  String get search => 'Search';

  @override
  String get dashboard => 'Overview';

  @override
  String get notes => 'Notes';

  @override
  String get allLists => 'All lists';

  @override
  String get trash => 'Trash';

  @override
  String get folders => 'FOLDERS';

  @override
  String get tags => 'TAGS';

  @override
  String get settings => 'Settings';

  @override
  String get synced => 'Synced';

  @override
  String get notSynced => 'Not synced';

  @override
  String get today => 'Today';

  @override
  String get dueSoon => 'Due soon';

  @override
  String get thisWeek => 'This week';

  @override
  String get general => 'General';

  @override
  String get overdue => 'Overdue';

  @override
  String get inbox => 'Inbox';

  @override
  String get untitled => 'Untitled';

  @override
  String get noTime => 'No time';

  @override
  String get tomorrow => 'Tomorrow';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get noFolder => 'No folder';

  @override
  String get noList => 'No list';

  @override
  String get addTask => 'Add task';

  @override
  String completedN(int n) {
    return 'Completed · $n';
  }

  @override
  String get note => 'Note';

  @override
  String get task => 'Task';

  @override
  String get descriptionLabel => 'DESCRIPTION';

  @override
  String get dueLabel => 'Due';

  @override
  String get priorityLabel => 'Priority';

  @override
  String get remindersLabel => 'Reminders';

  @override
  String get repeatLabel => 'Repeat';

  @override
  String get tagsLabel => 'Tags';

  @override
  String get subtasksLabel => 'Subtasks';

  @override
  String get noRepeat => 'Do not repeat';

  @override
  String get priorityHigh => 'High';

  @override
  String get priorityNormal => 'Normal';

  @override
  String get priorityLow => 'Low';

  @override
  String get noDescription => 'Add description…';

  @override
  String get noDue => 'Add due date';

  @override
  String get noTags => 'Add tags';

  @override
  String get sortMode => 'Sort';

  @override
  String get sortManual => 'Manual';

  @override
  String get sortDue => 'By due';

  @override
  String get sortPriority => 'By priority';

  @override
  String get delete => 'Delete';

  @override
  String get restore => 'Restore';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get completeBranchTitle => 'Complete branch';

  @override
  String get completeBranchQuestion =>
      'This task has incomplete subtasks. Complete the whole branch?';

  @override
  String get deleteTaskConfirm => 'Move this task with its subtasks to trash?';

  @override
  String get deleteNoteConfirm => 'Move this note to trash?';

  @override
  String get deleteFolderConfirm =>
      'Move this folder with all its contents to trash?';

  @override
  String get deleteTagConfirm =>
      'Delete tag? Labels are removed, entries stay.';

  @override
  String get trashEmpty => 'Trash is empty';

  @override
  String get searchHint => 'Search notes and tasks';

  @override
  String get searchResults => 'Results';

  @override
  String get noResults => 'Nothing found';

  @override
  String get movedToNoFolderHint =>
      'The original folder was deleted — note restored without a folder.';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get themeLabel => 'Theme';

  @override
  String get languageLabel => 'Language';

  @override
  String get systemLanguage => 'System';

  @override
  String get accountSection => 'Account';

  @override
  String get accountLocalOnly =>
      'Cloud is not connected — everything is stored locally (stage 3).';

  @override
  String get notificationsSection => 'Notifications';

  @override
  String get notificationsLocalDevice =>
      'Notification settings apply to this device (stage 5).';

  @override
  String get windowsOpenApp => 'Open';

  @override
  String get pinned => 'Pinned';

  @override
  String get pin => 'Pin';

  @override
  String get unpin => 'Unpin';

  @override
  String get moveToFolder => 'Move…';

  @override
  String embeddedFrom(String source) {
    return 'embedded · $source';
  }

  @override
  String get standaloneList => 'standalone';

  @override
  String notesSuffix(int n) {
    return '$n notes';
  }

  @override
  String get emptyNotes => 'No notes';

  @override
  String get emptyNotesHint => 'Create your first note';

  @override
  String get dataLayerReady => 'Data layer ready';

  @override
  String get signIn => 'Sign in with Google';

  @override
  String get signOut => 'Sign out';

  @override
  String get signOutQuestion =>
      'Keep a local copy of your data on this device?';

  @override
  String get keepLocalCopy => 'Keep copy';

  @override
  String get removeLocalCopy => 'Delete local data';

  @override
  String get unsavedWarning =>
      'There are unsynced changes — deleting the local copy will lose them.';

  @override
  String get signedInAs => 'Signed in as';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncOff => 'Cloud is not connected';

  @override
  String get syncError => 'Sync error';

  @override
  String get syncPermission =>
      'Access denied by rules — owner UID needed in Security Rules';

  @override
  String get workspaceMismatch =>
      'Local data belongs to another account — sync stopped';

  @override
  String get conflicts => 'Conflicts';

  @override
  String get conflictKeepLocal => 'Keep local';

  @override
  String get conflictKeepRemote => 'Keep remote';

  @override
  String get conflictsNone => 'No unresolved conflicts';

  @override
  String get uidLabel => 'UID';

  @override
  String get reauthNeeded => 'Re-authentication required';

  @override
  String get debugTitle => 'Diagnostics';

  @override
  String get debugCopyLog => 'Copy log';

  @override
  String get debugCopied => 'Log copied';

  @override
  String get debugInitialMerge => 'Merge with cloud';

  @override
  String get debugLogTitle => 'Event log';

  @override
  String get debugLogEmpty => 'No events yet';

  @override
  String get debugAcceptSnapshot => 'Accept new snapshot';

  @override
  String get debugAcceptSnapshotWarning =>
      'The server switched to a newer data snapshot. Accepting will discard unsynced local changes. Accept the new snapshot?';
}
