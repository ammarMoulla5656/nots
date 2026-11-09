import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/reader/reader_sheets.dart';
import 'package:nots/ui/theme.dart';

void main() {
  testWidgets('searching the contents keeps only the matching titles', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: TocSheet(
              entries: const [
                (title: 'كتاب الطهارة', level: 1, pdfPage: 5),
                (title: 'أحكام المياه', level: 2, pdfPage: 6),
                (title: 'كتاب الصلاة', level: 1, pdfPage: 40),
                (title: 'أوقات الصلاة', level: 2, pdfPage: 41),
              ],
              currentPdfPage: 6,
              onLink: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('أحكام المياه'), findsOneWidget);
    expect(find.text('كتاب الصلاة'), findsOneWidget);

    // Without the hamza or the diacritics it still finds them.
    await t.enterText(find.byType(TextField), 'الصلاه');
    await t.pump();
    expect(find.text('كتاب الصلاة'), findsOneWidget);
    expect(find.text('أوقات الصلاة'), findsOneWidget);
    expect(find.text('كتاب الطهارة'), findsNothing);

    await t.enterText(find.byType(TextField), 'احكام');
    await t.pump();
    expect(find.text('أحكام المياه'), findsOneWidget);
    expect(find.text('كتاب الصلاة'), findsNothing);

    await t.enterText(find.byType(TextField), 'لا يوجد مثله');
    await t.pump();
    expect(find.text('لا يوجد عنوان بهذا البحث.'), findsOneWidget);
  });
}
