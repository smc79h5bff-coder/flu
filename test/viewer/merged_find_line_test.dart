import 'package:docdiff/features/diff/domain/diff_entry.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:docdiff/features/diff/domain/diff_result.dart';
import 'package:docdiff/features/viewer/presentation/widgets/merged_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DiffResult _diff() => DiffResult(
      entries: [
        const DiffEntry(operation: DiffOperation.equal, text: '第一行'),
        DiffEntry(
            operation: DiffOperation.insert, text: '插入苹果', newText: '插入苹果'),
        const DiffEntry(operation: DiffOperation.equal, text: '第三行'),
        DiffEntry(
            operation: DiffOperation.delete, text: '删除的香蕉', oldText: '删除的香蕉'),
      ],
      engineType: DiffEngineType.line,
    );

Widget _wrap(DiffResult r, {String find = ''}) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MergedView(result: r, findQuery: find),
        ),
      ),
    );

void main() {
  group('MergedView 行号', () {
    testWidgets('渲染行号 gutter 且不崩', (tester) async {
      await tester.pumpWidget(_wrap(_diff()));

      // equal + insert 两行都会在行号列显示 "1"。
      expect(find.text('1', findRichText: true), findsNWidgets(2));
      expect(find.text('第一行', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不传 findQuery 时正常渲染', (tester) async {
      await tester.pumpWidget(_wrap(_diff()));
      expect(find.text('第一行', findRichText: true), findsOneWidget);
      expect(find.text('插入苹果', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('MergedView 查找高亮', () {
    testWidgets('命中文本可被找到且无异常', (tester) async {
      await tester.pumpWidget(_wrap(_diff(), find: '苹果'));

      expect(find.text('插入苹果', findRichText: true), findsOneWidget);
      final rich = tester.widgetList<RichText>(find.byType(RichText)).any(
          (rt) => rt.text.toPlainText().contains('苹果'));
      expect(rich, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无命中时不崩', (tester) async {
      await tester.pumpWidget(_wrap(_diff(), find: '不存在的词'));
      expect(tester.takeException(), isNull);
    });
  });
}