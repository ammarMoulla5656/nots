import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/ink_store.dart';
import '../reader/reader_screen.dart';
import 'library_store.dart';
import 'package_import.dart';

/// The library: books kept in the app, most recently opened first.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LibraryStore? _library;
  String _filter = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final lib = await LibraryStore.open();
    await _migrateRecentList(lib);
    if (mounted) setState(() => _library = lib);
  }

  /// Older versions kept a list of opened file paths and keyed writing by
  /// path. Bring the files that still exist into the library, with their
  /// writing.
  Future<void> _migrateRecentList(LibraryStore lib) async {
    final f = File(
      p.join((await getApplicationSupportDirectory()).path, 'recent.json'),
    );
    if (!await f.exists()) return;
    try {
      final paths = (jsonDecode(await f.readAsString()) as List).cast<String>();
      for (final path in paths) {
        if (!File(path).existsSync()) continue;
        final legacy = InkStore.legacyKey(path);
        final entry = await lib.importPdf(path);
        await InkStore.adopt(legacy, entry.id);
      }
    } on FormatException {
      // Nothing to bring over.
    }
    await f.rename('${f.path}.migrated');
  }

  Future<void> _open(BookEntry b) async {
    final lib = _library!;
    await lib.touch(b);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(library: lib, book: b),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    // Any file: Android does not know the .nots extension, so a filter on it
    // would hide the packages.
    final files = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: 'اختر كتاب PDF أو ملف نوتس',
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !mounted) return;
    final ext = p.extension(files.first.name).toLowerCase();
    if (ext != '.pdf' && ext != '.nots') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر ملف PDF أو ملف نوتس (.nots).')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final BookEntry entry;
      if (ext == '.nots') {
        entry = await importPackage(
          _library!,
          await File(path).readAsBytes(),
          confirmReplace: _confirmReplace,
        );
      } else {
        entry = await _library!.importPdf(
          path,
          title: p.basenameWithoutExtension(files.first.name),
        );
      }
      if (mounted) await _open(entry);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر إضافة الملف: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('«$title» عليه كتابة في هذا الجهاز'),
        content: const Text(
          'هل تستبدل الكتابة الموجودة هنا بالكتابة التي في الملف؟ إن اخترت «إبقاء» يُضاف الكتاب وتبقى كتابتك الحالية كما هي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إبقاء كتابتي'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('استبدال'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _rename(BookEntry b) async {
    final c = TextEditingController(text: b.title);
    final t = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اسم الكتاب'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    c.dispose();
    if (t != null && t.isNotEmpty) await _library!.rename(b, t);
  }

  Future<void> _remove(BookEntry b) async {
    var deleteWriting = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('إزالة «${b.title}» من المكتبة؟'),
          content: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: deleteWriting,
            onChanged: (v) => setState(() => deleteWriting = v ?? false),
            title: const Text('احذف كتابتي عليه أيضاً'),
            subtitle: const Text(
              'إن لم تحذفها تعود الكتابة تلقائياً متى أضفت الملف نفسه مرة أخرى.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('تراجع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('إزالة'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _library!.remove(b, deleteWriting: deleteWriting);
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'الآن';
    if (d.inHours < 1) return 'قبل ${d.inMinutes} دقيقة';
    if (d.inDays < 1) return 'قبل ${d.inHours} ساعة';
    if (d.inDays < 30) return 'قبل ${d.inDays} يوم';
    return t.toLocal().toString().substring(0, 10);
  }

  @override
  Widget build(BuildContext context) {
    final lib = _library;
    return Scaffold(
      appBar: AppBar(title: const Text('نوتس')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: lib == null || _busy ? null : _add,
        icon: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: const Text('إضافة كتاب'),
      ),
      body: lib == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: lib,
              builder: (context, _) {
                final all = lib.books;
                if (all.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'مكتبتك فارغة.\n\nأضف كتاب PDF: يُحفظ داخل التطبيق، وتبقى كتابتك عليه في ملف منفصل ولا يتغيّر الكتاب الأصلي.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final q = _filter.trim();
                final books = q.isEmpty
                    ? all
                    : all.where((b) => b.title.contains(q)).toList();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  children: [
                    if (all.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: 'ابحث في كتبك',
                            prefixIcon: Icon(Icons.search),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => setState(() => _filter = v),
                        ),
                      ),
                    for (final b in books)
                      Card(
                        child: ListTile(
                          leading: const Icon(
                            Icons.menu_book_outlined,
                            size: 32,
                          ),
                          title: Text(
                            b.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${(b.size / 1048576).toStringAsFixed(1)} MB · ${_ago(b.lastOpened)}',
                          ),
                          onTap: () => _open(b),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) =>
                                v == 'rename' ? _rename(b) : _remove(b),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('إعادة التسمية'),
                              ),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('إزالة من المكتبة'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
