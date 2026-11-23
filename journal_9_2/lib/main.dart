import 'dart:async';

import 'package:flutter/material.dart';

import 'journal_db.dart';

const moods = {
  'great': ('😄', 'Чудовий', Colors.green),
  'good': ('🙂', 'Добрий', Colors.teal),
  'neutral': ('😐', 'Спокійний', Colors.blueGrey),
  'sad': ('😔', 'Сумний', Colors.indigo),
  'angry': ('😠', 'Злий', Colors.deepOrange),
};

const tagColors = ['#246B58', '#4B63A8', '#8A4381', '#A25324', '#B0344B'];

Color tagColor(String hex) =>
    Color(0xff000000 | int.parse(hex.substring(1), radix: 16));

String dateKey(DateTime date) => date.toIso8601String().substring(0, 10);

typedef Board = ({
  List<JournalEntry> all,
  List<JournalEntry> visible,
  List<Tag> tags,
  List<DbRow> moodStats,
  List<DbRow> monthStats,
});

typedef EntryDraft = ({
  String title,
  String content,
  String mood,
  Set<int> tags,
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: JournalPage()),
  );
}

class JournalPage extends StatefulWidget {
  const JournalPage({super.key});

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  final db = DatabaseHelper.instance;
  final searchBox = TextEditingController();
  Timer? searchTimer;
  String mood = '';
  int tagId = 0;
  int tab = 0;
  bool busy = false;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  String selectedDay = dateKey(DateTime.now());

  late Future<Board> board = load();

  Future<Board> load() async {
    final search = searchBox.text;
    final currentMood = mood;
    final currentTag = tagId;
    final all = await db.entries();

    final visible =
        search.trim().isEmpty && currentMood.isEmpty && currentTag == 0
        ? all
        : await db.entries(
            search: search,
            mood: currentMood,
            tagId: currentTag,
          );

    return (
      all: all,
      visible: visible,
      tags: await db.tags(),
      moodStats: await db.moodStats(),
      monthStats: await db.monthStats(),
    );
  }

  void refresh() => setState(() => board = load());

  @override
  void dispose() {
    searchTimer?.cancel();
    searchBox.dispose();
    super.dispose();
  }

  Future<void> write(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);

    try {
      await action();
      if (mounted) refresh();
    } catch (error) {
      if (!mounted) return;
      final duplicate = error.toString().contains('UNIQUE constraint failed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            duplicate ? 'Тег із такою назвою вже існує' : 'Помилка: $error',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Скасувати'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Видалити'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> editEntry(List<Tag> tags, [JournalEntry? entry]) async {
    final draft = await showDialog<EntryDraft>(
      context: context,
      builder: (_) => EntryEditor(entry: entry, tags: tags),
    );

    if (!mounted || draft == null) return;

    await write(
      () => db.saveEntry(
        id: entry?.id,
        title: draft.title,
        content: draft.content,
        mood: draft.mood,
        tagIds: draft.tags,
      ),
    );
  }

  Future<void> editTag([Tag? tag]) async {
    var name = tag?.name ?? '';
    var color = tag?.color ?? tagColors.first;
    final form = GlobalKey<FormState>();

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: Text(tag == null ? 'Новий тег' : 'Редагування тегу'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: name,
                  maxLength: 30,
                  decoration: const InputDecoration(labelText: 'Назва'),
                  onChanged: (value) => name = value.trim(),
                  validator: (_) => name.isEmpty ? 'Введи назву тегу' : null,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in tagColors)
                      ChoiceChip(
                        label: Icon(Icons.circle, color: tagColor(option)),
                        selected: color == option,
                        onSelected: (_) => update(() => color = option),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Скасувати'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate())
                  Navigator.pop(dialogContext, true);
              },
              child: const Text('Зберегти'),
            ),
          ],
        ),
      ),
    );

    if (mounted && accepted == true) {
      await write(() => db.saveTag(name, color, id: tag?.id));
    }
  }

  Widget entryCard(JournalEntry entry, List<Tag> tags) {
    final moodInfo = moods[entry.mood]!;

    return Card(
      child: ListTile(
        onTap: busy ? null : () => editEntry(tags, entry),
        leading: Text(moodInfo.$1, style: const TextStyle(fontSize: 28)),
        title: Text(entry.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.content, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text('${moodInfo.$2} · Слів: ${entry.wordCount}'),
            Wrap(
              spacing: 5,
              children: [
                for (final tag in entry.tags)
                  Chip(
                    label: Text(tag.name),
                    avatar: Icon(
                      Icons.circle,
                      size: 12,
                      color: tagColor(tag.color),
                    ),
                  ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Обране',
              onPressed: busy
                  ? null
                  : () => write(() => db.toggleFavorite(entry)),
              icon: Icon(entry.isFavorite ? Icons.star : Icons.star_border),
            ),
            IconButton(
              tooltip: 'Видалити запис',
              onPressed: busy
                  ? null
                  : () async {
                      if (await confirm('Видалити запис?') && mounted) {
                        await write(() => db.deleteEntry(entry.id));
                      }
                    },
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> timeline(Board data) {
    final byDay = <String, List<JournalEntry>>{};
    for (final entry in data.visible) {
      byDay.putIfAbsent(entry.day, () => []).add(entry);
    }

    return [
      TextField(
        controller: searchBox,
        decoration: const InputDecoration(
          labelText: 'Пошук за назвою або текстом',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (_) {
          searchTimer?.cancel();
          searchTimer = Timer(const Duration(milliseconds: 250), refresh);
        },
      ),
      Wrap(
        spacing: 20,
        children: [
          DropdownButton<String>(
            value: mood,
            items: [
              const DropdownMenuItem(value: '', child: Text('Усі настрої')),
              for (final item in moods.entries)
                DropdownMenuItem(value: item.key, child: Text(item.value.$2)),
            ],
            onChanged: (value) {
              mood = value ?? '';
              refresh();
            },
          ),
          DropdownButton<int>(
            value: data.tags.any((tag) => tag.id == tagId) ? tagId : 0,
            items: [
              const DropdownMenuItem(value: 0, child: Text('Усі теги')),
              for (final tag in data.tags)
                DropdownMenuItem(value: tag.id, child: Text(tag.name)),
            ],
            onChanged: (value) {
              tagId = value ?? 0;
              refresh();
            },
          ),
        ],
      ),
      if (byDay.isEmpty) const ListTile(title: Text('Записів немає')),
      for (final group in byDay.entries) ...[
        ListTile(title: Text(group.key)),
        for (final entry in group.value) entryCard(entry, data.tags),
      ],
    ];
  }

  List<Widget> calendar(Board data) {
    final byDay = <String, List<JournalEntry>>{};
    for (final entry in data.all) {
      byDay.putIfAbsent(entry.day, () => []).add(entry);
    }

    final offset = month.weekday - 1;
    final days = DateUtils.getDaysInMonth(month.year, month.month);

    void move(int direction) {
      setState(() {
        month = DateTime(month.year, month.month + direction);
        selectedDay = dateKey(month);
      });
    }

    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: () => move(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Text(dateKey(month).substring(0, 7)),
          IconButton(
            onPressed: () => move(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      Row(
        children: [
          for (final label in ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'])
            Expanded(child: Center(child: Text(label))),
        ],
      ),
      GridView.count(
        crossAxisCount: 7,
        childAspectRatio: 1.4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < offset; i++) const SizedBox(),
          for (var day = 1; day <= days; day++)
            calendarCell(
              day,
              byDay[dateKey(DateTime(month.year, month.month, day))] ?? [],
            ),
        ],
      ),
      ListTile(title: Text('Записи за $selectedDay')),
      if (byDay[selectedDay] == null)
        const ListTile(title: Text('Записів немає')),
      for (final entry in byDay[selectedDay] ?? <JournalEntry>[])
        entryCard(entry, data.tags),
    ];
  }

  Widget calendarCell(int day, List<JournalEntry> entries) {
    final key = dateKey(DateTime(month.year, month.month, day));
    final colors = entries.map((entry) => moods[entry.mood]!.$3).toSet();

    return InkWell(
      onTap: () => setState(() => selectedDay = key),
      child: ColoredBox(
        color: key == selectedDay
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$day'),
              Wrap(
                spacing: 2,
                children: [
                  for (final color in colors.take(3))
                    Icon(Icons.circle, size: 6, color: color),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  int writingStreak(List<JournalEntry> entries) {
    final days = entries.map((entry) => entry.day).toSet();
    final now = DateTime.now();
    var day = DateTime.utc(now.year, now.month, now.day);
    const oneDay = Duration(days: 1);

    if (!days.contains(dateKey(day))) day = day.subtract(oneDay);
    var streak = 0;

    while (days.contains(dateKey(day))) {
      streak++;
      day = day.subtract(oneDay);
    }

    return streak;
  }

  List<Widget> statistics(Board data) => [
    ListTile(
      title: const Text('Усього записів'),
      trailing: Text('${data.all.length}'),
    ),
    ListTile(
      title: const Text('Серія днів'),
      trailing: Text('${writingStreak(data.all)}'),
    ),
    const Divider(),
    const ListTile(title: Text('Настрої')),
    for (final row in data.moodStats)
      ListTile(
        title: Text(moods[row['label']]!.$2),
        trailing: Text('${row['total']}'),
      ),
    const Divider(),
    const ListTile(title: Text('Записи за місяцями')),
    for (final row in data.monthStats)
      ListTile(
        title: Text('${row['label']}'),
        trailing: Text('${row['total']}'),
      ),
    const Divider(),
    const ListTile(title: Text('Найуживаніші теги')),
    for (final tag in data.tags.where((tag) => tag.count > 0).take(5))
      ListTile(title: Text(tag.name), trailing: Text('${tag.count}')),
  ];

  List<Widget> tagsPage(Board data) => [
    if (data.tags.isEmpty) const ListTile(title: Text('Тегів ще немає')),
    for (final tag in data.tags)
      ListTile(
        leading: Icon(Icons.circle, color: tagColor(tag.color)),
        title: Text(tag.name),
        subtitle: Text('Записів: ${tag.count}'),
        onTap: busy ? null : () => editTag(tag),
        trailing: IconButton(
          tooltip: 'Видалити тег',
          icon: const Icon(Icons.delete_outline),
          onPressed: busy
              ? null
              : () async {
                  if (await confirm('Видалити тег «${tag.name}»?') && mounted) {
                    await write(() async {
                      await db.deleteTag(tag.id);
                      if (tagId == tag.id) tagId = 0;
                    });
                  }
                },
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Board>(
      future: board,
      builder: (context, snapshot) {
        final data = snapshot.data;

        return Scaffold(
          appBar: AppBar(title: const Text('Особистий щоденник')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: snapshot.hasError
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Не вдалося завантажити базу: ${snapshot.error}',
                          ),
                          TextButton(
                            onPressed: refresh,
                            child: const Text('Повторити'),
                          ),
                        ],
                      )
                    : data == null
                    ? const CircularProgressIndicator()
                    : ListView(
                        key: ValueKey(tab),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                        children: switch (tab) {
                          1 => calendar(data),
                          2 => statistics(data),
                          3 => tagsPage(data),
                          _ => timeline(data),
                        },
                      ),
              ),
            ),
          ),
          floatingActionButton: data == null || busy || (tab != 0 && tab != 3)
              ? null
              : FloatingActionButton.extended(
                  onPressed: tab == 3
                      ? () => editTag()
                      : () => editEntry(data.tags),
                  icon: const Icon(Icons.add),
                  label: Text(tab == 3 ? 'Новий тег' : 'Новий запис'),
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.notes), label: 'Записи'),
              NavigationDestination(
                icon: Icon(Icons.calendar_month),
                label: 'Календар',
              ),
              NavigationDestination(
                icon: Icon(Icons.bar_chart),
                label: 'Статистика',
              ),
              NavigationDestination(
                icon: Icon(Icons.label_outline),
                label: 'Теги',
              ),
            ],
          ),
        );
      },
    );
  }
}

class EntryEditor extends StatefulWidget {
  const EntryEditor({super.key, required this.entry, required this.tags});

  final JournalEntry? entry;
  final List<Tag> tags;

  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  final form = GlobalKey<FormState>();
  late String title = widget.entry?.title ?? '';
  late String content = widget.entry?.content ?? '';
  late String mood = widget.entry?.mood ?? 'neutral';
  late final selectedTags =
      widget.entry?.tags.map((tag) => tag.id).toSet() ?? <int>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? 'Новий запис' : 'Редагування запису'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: title,
                  decoration: const InputDecoration(labelText: 'Назва'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Введи назву' : null,
                  onChanged: (value) => title = value,
                ),
                TextFormField(
                  initialValue: content,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Текст'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Введи текст' : null,
                  onChanged: (value) => setState(() => content = value),
                ),
                Text('Слів: ${countWords(content)}'),
                DropdownButton<String>(
                  value: mood,
                  items: [
                    for (final item in moods.entries)
                      DropdownMenuItem(
                        value: item.key,
                        child: Text('${item.value.$1} ${item.value.$2}'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => mood = value);
                  },
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final tag in widget.tags)
                      FilterChip(
                        label: Text(tag.name),
                        selected: selectedTags.contains(tag.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            selectedTags.add(tag.id);
                          } else {
                            selectedTags.remove(tag.id);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Скасувати'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop<EntryDraft>(context, (
              title: title,
              content: content,
              mood: mood,
              tags: selectedTags,
            ));
          },
          child: const Text('Зберегти'),
        ),
      ],
    );
  }
}
