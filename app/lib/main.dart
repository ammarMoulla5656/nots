import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pdfrx/pdfrx.dart';

import 'library/home_screen.dart';
import 'ui/app_settings.dart';
import 'ui/speed_log.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  await AppSettings.instance.load();
  await SpeedLog.instance.load();
  SpeedLog.instance.note('app started');
  Brand.dark = false;
  runApp(const NotsApp());
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => SpeedLog.instance.note('first frame'),
  );
}

class NotsApp extends StatefulWidget {
  const NotsApp({super.key});

  @override
  State<NotsApp> createState() => _NotsAppState();
}

class _NotsAppState extends State<NotsApp> {
  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettings);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettings);
    super.dispose();
  }

  /// The colours are read as screens are built, so a change of look builds
  /// them all again, keeping what each one is showing.
  void _onSettings() {
    const dark = false;
    if (dark == Brand.dark) return;
    setState(() => Brand.dark = dark);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void again(Element e) {
        e.markNeedsBuild();
        e.visitChildren(again);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(again);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SpeedLog.instance,
      builder: (context, _) => _app(SpeedLog.instance.enabled),
    );
  }

  Widget _app(bool measuring) {
    return MaterialApp(
      // While measuring: the time of every frame, drawn over the screen.
      showPerformanceOverlay: measuring,
      title: 'قلم المصدر',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
