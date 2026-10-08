import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Nothing under lib/ imports dart:io, which is what keeps the package usable on
/// Flutter web (pub.dev derives platform support from imports). Read reporting
/// adds code to the read path of every app; this keeps it, and anything after
/// it, from quietly dropping the web target.
void main() {
  test('nothing under lib/ imports dart:io', () {
    final ioImport = RegExp(r'''^\s*(import|export)\s+['"]dart:io['"]''', multiLine: true);
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => ioImport.hasMatch(f.readAsStringSync()))
        .map((f) => f.path)
        .toList();

    expect(offenders, isEmpty);
  });
}
