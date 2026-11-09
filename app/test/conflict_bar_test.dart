import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/reader/conflict_bar.dart';
import 'package:nots/sync/conflicts.dart';
import 'package:nots/sync/merge.dart';

Stroke _line(int id, double x) => Stroke(
  id: id,
  tool: InkTool.pen,
  color: 0xFF000000,
  width: 1,
  points: [StrokePoint(x, 1, 0.5, 0), StrokePoint(x, 9, 0.5, 5)],
);

PageConflict _conflict(int page) => PageConflict(
  page: page,
  mine: PageVersion([_line(1, 10)], const []),
  theirs: PageVersion([_line(2, 20)], const []),
  merged: PageVersion([_line(1, 10), _line(2, 20)], const []),
  device: 'iPad 2',
  at: DateTime(2026, 11, 5, 16, 20),
);

void main() {
  late Directory dir;
  late InkDocument doc;
  late ConflictSession session;

  /// The one made outside the tests' fake time: only it can be waited for.
  late ConflictSession first;
  final moves = <int>[];
  final settled = <PageConflict>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nots_conflict_');
    ConflictStore.dirProvider = () async => dir;
    moves.clear();
    settled.clear();
    doc = InkDocument(
      pages: {
        3: [_line(1, 10), _line(2, 20)],
        8: [_line(1, 10), _line(2, 20)],
      },
      nextStrokeId: 5,
    );
    first = session = ConflictSession('b', doc, {
      3: _conflict(3),
      8: _conflict(8),
    });
  });
  tearDown(() async {
    await first.saved;
    await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester t, int page) => t.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (context, _) => ConflictBar(
              session: session,
              page: page,
              onGoTo: moves.add,
              onAccepted: settled.add,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('on a waiting page: the three choices, by name', (t) async {
    await pump(t, 3);
    expect(find.text('كُتب على هذه الصفحة من جهازين'), findsOneWidget);
    expect(find.text('هذا الجهاز'), findsOneWidget);
    expect(find.text('iPad 2'), findsOneWidget);
    expect(find.text('دمج'), findsOneWidget);
  });

  testWidgets('pressing a choice shows it on the page', (t) async {
    await pump(t, 3);
    await t.runAsync(() async {
      await t.tap(find.text('iPad 2'));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(doc.strokesOf(3).single.points.first.x, 20);
    expect(session.of(3)!.choice, PageChoice.theirs);
    expect(doc.strokesOf(8).length, 2); // the other page is left as it was
  });

  testWidgets('pressing through the versions quickly keeps the last', (
    t,
  ) async {
    await t.runAsync(() async {
      await Future.wait([
        for (final c in [
          PageChoice.mine,
          PageChoice.theirs,
          PageChoice.mine,
          PageChoice.merged,
          PageChoice.theirs,
        ])
          session.show(3, c),
      ]);
      await session.saved;
      final again = await ConflictStore.load('b');
      expect(again[3]!.choice, PageChoice.theirs);
    });
    expect(doc.strokesOf(3).single.points.first.x, 20);
  });

  testWidgets('settling hands the question back, and goes to the next', (
    t,
  ) async {
    await pump(t, 3);
    await t.tap(find.text('الصفحة التالية'));
    expect(moves, [8]);
    await t.runAsync(() async {
      await t.tap(find.text('اعتماد ما يظهر الآن'));
      await t.pump();
      // The settling writes files: wait until it is done, not a fixed time
      // (a busy machine takes longer).
      for (var i = 0; i < 100 && settled.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await t.pump();
    expect(settled.single.page, 3);
    expect(session.pages, [8]);
  });

  testWidgets('on other pages: a reminder that leads to the waiting one', (
    t,
  ) async {
    await pump(t, 5);
    expect(find.text('2 صفحات تنتظر اختيارك'), findsOneWidget);
    await t.tap(find.text('2 صفحات تنتظر اختيارك'));
    expect(moves, [8]);
  });

  testWidgets('nothing waiting: nothing shown', (t) async {
    session = ConflictSession('b', doc, {});
    await pump(t, 3);
    expect(find.byType(Material), findsWidgets);
    expect(find.text('هذا الجهاز'), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('a long device name stays inside a phone screen', (t) async {
    t.view.physicalSize = const Size(320, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    session = ConflictSession('b', doc, {
      3: PageConflict(
        page: 3,
        mine: const PageVersion([], []),
        theirs: const PageVersion([], []),
        merged: const PageVersion([], []),
        device: 'A very long tablet model name that goes on and on',
        at: DateTime(2026),
      ),
    });
    await pump(t, 3);
    expect(t.takeException(), isNull);
  });
}
