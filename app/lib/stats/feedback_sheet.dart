import 'package:flutter/material.dart';

import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'usage.dart';
import 'usage_upload.dart';

/// «اقترح كتاباً» ([kind] 'book') or «الإبلاغ عن مشكلة» ([kind] 'problem'):
/// the message waits on the device and goes to the administrators with the
/// next report over Wi-Fi.
Future<void> showFeedbackSheet(BuildContext context, String kind) =>
    showNotsSheet<void>(context, builder: (_) => _FeedbackSheet(kind: kind));

class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet({required this.kind});

  final String kind;

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _text = TextEditingController();
  final _about = TextEditingController();
  bool _sent = false;

  bool get _book => widget.kind == 'book';

  @override
  void dispose() {
    _text.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    await FeedbackOutbox.instance.add(
      widget.kind,
      text,
      about: _about.text.trim(),
    );
    Usage.instance.feature(_book ? 'suggest_book' : 'report_problem');
    if (mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final onWifi = Usage.instance.network == 'wifi';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(_book ? 'اقترح كتاباً' : 'الإبلاغ عن مشكلة'),
              if (_sent) ...[
                Icon(Icons.check_circle, color: Brand.blue, size: 44),
                const SizedBox(height: 10),
                Text(
                  onWifi
                      ? 'شكراً لك. تصل رسالتك إلى إدارة التطبيق خلال دقائق.'
                      : 'شكراً لك. تُرسل رسالتك عند اتصال الجهاز بشبكة واي فاي.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(height: 1.7),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('تم'),
                ),
              ] else ...[
                Text(
                  _book
                      ? 'اكتب اسم الكتاب ومؤلفه، وما تعرفه عن طبعته، لنضيفه إلى المكتبة.'
                      : 'اكتب المشكلة كما حدثت: ماذا فعلت، وما الذي ظهر. إن كانت في كتاب فاذكر اسمه والصفحة.',
                  style: TextStyle(color: Brand.muted, height: 1.7),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _about,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: _book
                        ? 'اسم الكتاب'
                        : 'في أي كتاب أو أي شاشة (اختياري)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _text,
                  autofocus: !_book,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    labelText: _book ? 'المؤلف والتفاصيل' : 'المشكلة',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed:
                      _text.text.trim().isEmpty &&
                          !(_book && _about.text.trim().isNotEmpty)
                      ? null
                      : () {
                          if (_text.text.trim().isEmpty) {
                            _text.text = _about.text.trim();
                          }
                          _send();
                        },
                  icon: const Icon(Icons.send),
                  label: const Text('إرسال'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
