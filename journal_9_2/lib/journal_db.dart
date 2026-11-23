import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

typedef DbRow = Map<String, Object?>;
typedef Tag = ({int id, String name, String color, int count});

class JournalEntry {
  JournalEntry(this.row);

  final DbRow row;
  final tags = <Tag>[];

  int get id => row['id'] as int;
  String get title => row['title'] as String;
  String get content => row['content'] as String;
  String get mood => row['mood'] as String;
  String get day => (row['created_at'] as String).substring(0, 10);
  int get wordCount => row['word_count'] as int;
  bool get isFavorite => row['is_favorite'] == 1;
}

int countWords(String text) => RegExp(r'\S+').allMatches(text).length;

class DatabaseHelper {
  DatabaseHelper._();

  static final instance = DatabaseHelper._();
  Future<Database>? _opening;

  Future<Database> open() => _opening ??= _open();

  Future<Database> _open() async {
    try {
      return await databaseFactoryFfiWebNoWebWorker.openDatabase(
        'journal_9_2.db',
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: _onCreate,
        ),
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE journal_entries (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        mood TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        word_count INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tags (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        name_key TEXT NOT NULL UNIQUE,
        color TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE entry_tags (
        entry_id INTEGER NOT NULL
          REFERENCES journal_entries(id) ON DELETE CASCADE,
        tag_id INTEGER NOT NULL
          REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (entry_id, tag_id)
      )
    ''');

    await db.execute(
      'CREATE INDEX entry_date_idx ON journal_entries(created_at)',
    );
    await db.execute('CREATE INDEX entry_mood_idx ON journal_entries(mood)');
    await db.execute('CREATE INDEX tag_name_idx ON tags(name)');
    await db.execute('CREATE INDEX entry_tags_tag_idx ON entry_tags(tag_id)');
  }

  Future<List<JournalEntry>> entries({
    String search = '',
    String mood = '',
    int tagId = 0,
  }) async {
    final db = await open();
    final conditions = <String>[];
    final args = <Object?>[];
    final query = search.trim();

    if (query.isNotEmpty) {
      final escaped = query
          .replaceAll('!', '!!')
          .replaceAll('%', '!%')
          .replaceAll('_', '!_');
      conditions.add(
        "(j.title LIKE ? ESCAPE '!' OR j.content LIKE ? ESCAPE '!')",
      );
      args.addAll(['%$escaped%', '%$escaped%']);
    }

    if (mood.isNotEmpty) {
      conditions.add('j.mood = ?');
      args.add(mood);
    }

    if (tagId != 0) {
      conditions.add('''
        EXISTS (
          SELECT 1 FROM entry_tags f
          WHERE f.entry_id = j.id AND f.tag_id = ?
        )
      ''');
      args.add(tagId);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final rows = await db.rawQuery('''
      SELECT j.*, t.id AS tag_id, t.name AS tag_name, t.color AS tag_color
      FROM journal_entries j
      LEFT JOIN entry_tags et ON et.entry_id = j.id
      LEFT JOIN tags t ON t.id = et.tag_id
      $where
      ORDER BY j.created_at DESC, j.id DESC, t.name
    ''', args);

    final byId = <int, JournalEntry>{};

    for (final row in rows) {
      final entry = byId.putIfAbsent(row['id'] as int, () => JournalEntry(row));
      final tagId = row['tag_id'] as int?;

      if (tagId != null) {
        entry.tags.add((
          id: tagId,
          name: row['tag_name'] as String,
          color: row['tag_color'] as String,
          count: 0,
        ));
      }
    }

    return byId.values.toList();
  }

  Future<void> saveEntry({
    int? id,
    required String title,
    required String content,
    required String mood,
    required Set<int> tagIds,
  }) async {
    final db = await open();
    final now = DateTime.now().toIso8601String();
    final values = <String, Object?>{
      'title': title.trim(),
      'content': content.trim(),
      'mood': mood,
      'updated_at': now,
      'word_count': countWords(content),
    };

    await db.transaction((txn) async {
      final int entryId;

      if (id == null) {
        entryId = await txn.insert('journal_entries', {
          ...values,
          'created_at': now,
        });
      } else {
        entryId = id;
        final changed = await txn.update(
          'journal_entries',
          values,
          where: 'id = ?',
          whereArgs: [entryId],
        );

        if (changed != 1) throw StateError('Запис уже видалено');

        await txn.delete(
          'entry_tags',
          where: 'entry_id = ?',
          whereArgs: [entryId],
        );
      }

      for (final tagId in tagIds) {
        await txn.insert('entry_tags', {'entry_id': entryId, 'tag_id': tagId});
      }
    });
  }

  Future<void> deleteEntry(int id) async {
    final db = await open();
    await db.delete('journal_entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> toggleFavorite(JournalEntry entry) async {
    final db = await open();
    await db.update(
      'journal_entries',
      {
        'is_favorite': entry.isFavorite ? 0 : 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  Future<List<Tag>> tags() async {
    final db = await open();
    final rows = await db.rawQuery('''
      SELECT t.id, t.name, t.color, COUNT(et.entry_id) AS uses
      FROM tags t
      LEFT JOIN entry_tags et ON et.tag_id = t.id
      GROUP BY t.id, t.name, t.color
      ORDER BY uses DESC, t.name
    ''');

    return [
      for (final row in rows)
        (
          id: row['id'] as int,
          name: row['name'] as String,
          color: row['color'] as String,
          count: row['uses'] as int,
        ),
    ];
  }

  Future<void> saveTag(String name, String color, {int? id}) async {
    final db = await open();
    final values = {
      'name': name.trim(),
      'name_key': name.trim().toLowerCase(),
      'color': color,
    };

    if (id == null) {
      await db.insert('tags', {
        ...values,
        'created_at': DateTime.now().toIso8601String(),
      });
    } else {
      await db.update('tags', values, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> deleteTag(int id) async {
    final db = await open();
    await db.delete('tags', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<DbRow>> moodStats() async {
    final db = await open();
    return db.rawQuery('''
      SELECT mood AS label, COUNT(*) AS total
      FROM journal_entries
      GROUP BY mood
      ORDER BY total DESC
    ''');
  }

  Future<List<DbRow>> monthStats() async {
    final db = await open();
    return db.rawQuery('''
      SELECT substr(created_at, 1, 7) AS label, COUNT(*) AS total
      FROM journal_entries
      GROUP BY substr(created_at, 1, 7)
      ORDER BY label DESC
    ''');
  }
}
