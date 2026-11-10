/// Маппинг payload: ключи snake_case, DateTime → ISO, content → text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/sync/sync_mapper.dart';

void main() {
  test('rowToJson: camelCase → snake_case, DateTime → ISO UTC', () {
    final json = rowToJson({
      'folderId': 'f1',
      'modifiedAt': DateTime.utc(2026, 11, 1, 12, 0),
      'pinned': true,
      'deltaFormatVersion': 1,
    });
    expect(json['folder_id'], 'f1');
    expect(json['modified_at'], '2026-11-01T12:00:00.000Z');
    expect(json['pinned'], true);
    expect(json['delta_format_version'], 1);
  });

  test('rowToJson: content задачи становится text', () {
    final json = rowToJson({'content': 'Замовити фільтр'});
    expect(json['text'], 'Замовити фільтр');
    expect(json.containsKey('content'), isFalse);
  });
}
