import 'dart:io';

import 'package:docdiff/features/edit/application/edit_saver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const saver = EditSaver();

  test('覆盖原文件：先生成 .bak 备份再写回', () async {
    final dir = await Directory.systemTemp.createTemp('docdiff_saver');
    final file = File('${dir.path}/doc.txt');
    await file.writeAsString('第一版内容');

    final r = await saver.saveOverwrite(file.path, '修改后内容');

    expect(r.savedPath, file.path);
    expect(r.backupPath, isNotNull);
    // 备份保留原内容
    expect(await File(r.backupPath!).readAsString(), '第一版内容');
    // 原文件被覆盖
    expect(await file.readAsString(), '修改后内容');
    await dir.delete(recursive: true);
  });

  test('原文件不存在时无备份，仅写新文件', () async {
    final dir = await Directory.systemTemp.createTemp('docdiff_saver2');
    final file = File('${dir.path}/new.txt');

    final r = await saver.saveOverwrite(file.path, '新内容');

    expect(r.backupPath, isNull);
    expect(await file.readAsString(), '新内容');
    await dir.delete(recursive: true);
  });

  test('.bak 已存在时生成带时间戳的新备份，不覆盖旧备份', () async {
    final dir = await Directory.systemTemp.createTemp('docdiff_saver3');
    final file = File('${dir.path}/doc.txt');
    await file.writeAsString('v1');
    await saver.saveOverwrite(file.path, 'v2'); // 生成 doc.txt.bak = v1

    final bak1 = File('${file.path}.bak');
    expect(await bak1.readAsString(), 'v1');

    // 再一次保存（doc 已被覆盖为 v2）
    final r2 = await saver.saveOverwrite(file.path, 'v3');
    expect(r2.backupPath, isNotNull);
    expect(r2.backupPath, isNot(bak1.path));

    // 旧 .bak 仍为 v1，新备份为 v2
    expect(await bak1.readAsString(), 'v1');
    expect(await File(r2.backupPath!).readAsString(), 'v2');
    expect(await file.readAsString(), 'v3');
    await dir.delete(recursive: true);
  });
}