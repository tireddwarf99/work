# Этап 1 — слой данных: реализовано (v1)

Статус: реализовано и покрыто тестами (45 тестов, `flutter test` — зелёные;
`flutter analyze` — без замечаний; сборки `apk --debug` и `windows --debug` — ОК).

## Таблицы Drift (SQLite)

Постоянные UUID (TEXT, v4). У каждой синхронизируемой таблицы общие колонки
(`mixin SyncColumns`): `revision`, `base_revision`, `modified_at`, `device_id`,
`deleted_at` (NULL = активна). Outbox — отдельная таблица с `operation_id`.
Отличия от исходного наброска: отдельной `sync_state`-колонки у записей нет —
pending определяется по outbox; `trash_meta` не нужна — срок корзины считается
от `deleted_at` (30 дней, §11).

| Таблица | Ключевые поля |
|---|---|
| folders | id, parent_id?, name, manual_order |
| notes | id, folder_id?, title?, delta (Quill JSON), delta_format_version, pinned, pin_order, manual_order |
| task_lists | id, title?, note_id?, embed_block_id?, manual_order, sort_mode (manual/due/priority) |
| tasks | id, list_id, parent_id?, text, description, completed_at?, priority (0/1/2), due_kind (0 none / 1 date / 2 datetime), due_date (TEXT «2026-11-02»), due_minutes (int? — минуты от полуночи), manual_order, series_id?, ordinal? |
| tags | id, name, manual_order |
| entity_tags | entity_id, tag_id, entity_type (note/task) |
| recurrence_rules | id, task_id (root only), kind (calendar/interval), pattern JSON |
| task_occurrences | id = hash(series_id, ordinal), series_id, ordinal, scheduled_due, completed_at?, skipped_at? |
| reminders | id, task_id, kind (relative/absolute), offset_minutes?, local_dt (TEXT)? |
| conflicts | id, entity_id, kind, payload JSON, created_at |
| trash_meta | entity_id, entity_type, deleted_at, purge_at (30 дней) |
| outbox | operation_id, entity_id, entity_type, rev, payload, created_at |
| sync_base / sync_state | курсоры, base-ревизии |
| deletion_markers | entity_id, entity_type, deleted_at, marker revision (без контента) |
| settings_device / settings_shared | key, value JSON |

## Ключевые решения по времени (§3, §6 спеки)

1. **Дата без времени ≠ локальная дата-время.** Хранение: `due_kind` + `due_date`
   (TEXT ISO-8601 даты) + `due_minutes` (NULL, если времени нет). Ничего не кодируем
   как UTC-полночь; сортировка — по (due_date, due_minutes).
2. Просрочка даты без времени — по следующей календарной полуночи (не +24h).
3. История выполнений повторений — только `task_occurrences` (выполнено/пропущено).
4. Напоминание: `relative` (за N минут до срока; для date-only считаем от 00:00 конца дня
   и храним рассчитанный момент) или `absolute` (локальная дата-время, TEXT без оффсета).

## Правила дерева задач

- Циклы запрещены: проверка при смене parent_id в сервисе + FK.
- Повторение только на корневой задаче (series_id/ordinal NULL у подзадач).
- Выполненные корневые → сворачиваемая область «Виконані» списка; подзадачи — у родителя.

## FTS5

`notes_fts` (title, delta plain-text) и `tasks_fts` (text, description) с
unicode61-токенизатором; синхронизация триггерами от базовых таблиц, пересбор —
миграцией. Полнотекст в тяжёлых запросах — фоновый isolate (Drift `NativeDatabase.createInBackground`).

## Индексы

tasks(list_id), tasks(parent_id), tasks(due_kind, due_date, completed_at),
tasks(completed_at), tasks(priority), notes(folder_id, pinned, pin_order),
notes(modified_at), entity_tags(entity_id), entity_tags(tag_id), reminders(task_id).

## Изоляция модулей (§2)

`lib/db/` — таблицы, схема, FTS, миграции; `lib/data/` — сервисы (граница модулей);
`lib/domain/` — чистые типы и правила времени/сортировки. UI не ходит в БД напрямую:
SQL сосредоточен в db-слое и сервисах, транзакции — только в сервисах.

## Проверено тестами

- Граница просрочки даты без времени — следующая календарная полуночь (не +24ч).
- Окно 48 часов до границы; просроченные в окно не попадают.
- Неделя понедельник—воскресенье, включая воскресенье как «сегодня».
- Несуществующее число месяца: 31 янв → 28/29 фев → 31 мар.
- DST: несуществующее время (весенний скачок, Киев 29.03.2026) — сдвиг после скачка;
  повторяющееся время (откат 25.10.2026) — первое вхождение (поиск минимального
  UTC-момента с нужными локальными полями).
- 09:00 сохраняется как локальное поле при смене зоны.
- FTS5 unicode61: поиск по заметкам и задачам, обновление контента через триггеры,
  отсутствие морфологии («сервіс» ≠ «сервісу»).
- Дерево задач: запрет подзадачи из другого списка, перенос ветки целиком,
  запрет циклов, переупорядочивание соседей, подтверждение ветки (§6).
- Корзина: ветка целиком, восстановление, «Без папки» при исчезнувшей папке,
  30 дней, физическое удаление → DeletionMarkers без контента.
- Outbox: мутация + запись — одна транзакция.
- Настройки device/shared изолированы.
