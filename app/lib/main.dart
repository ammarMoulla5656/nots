import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'reader/reader_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  runApp(const NotsApp());
}

class NotsApp extends StatelessWidget {
  const NotsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نوتس',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1F4E8C),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<File> _recentFile() async => File(
      p.join((await getApplicationSupportDirectory()).path, 'recent.json'));

  Future<void> _loadRecent() async {
    final f = await _recentFile();
    if (!await f.exists()) return;
    try {
      final list = (jsonDecode(await f.readAsString()) as List).cast<String>();
      if (mounted) {
        setState(() => _recent = list.where((e) => File(e).existsSync()).toList());
      }
    } on FormatException {
      // Ignore a damaged recent list; it is rebuilt on next open.
    }
  }

  Future<void> _open(String path) async {
    final next = [path, ..._recent.where((e) => e != path)].take(12).toList();
    setState(() => _recent = next);
    await (await _recentFile()).writeAsString(jsonEncode(next));
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderScreen(pdfPath: path)),
    );
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      dialogTitle: 'اختر ملف PDF',
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path != null) await _open(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نوتس')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.upload_file),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('فتح ملف PDF'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'ملفك يبقى على جهازك ولا يُرفع إلى أي مكان. الكتابة تُحفظ في ملف منفصل ولا يتغيّر الـPDF الأصلي.',
          ),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('آخر الملفات', style: Theme.of(context).textTheme.titleMedium),
            for (final path in _recent)
              ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: Text(p.basenameWithoutExtension(path)),
                subtitle: Text(path, overflow: TextOverflow.ellipsis),
                onTap: () => _open(path),
              ),
          ],
        ],
      ),
    );
  }
}
