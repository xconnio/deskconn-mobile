import 'package:deskconn_mobile_app/core/text_editor/editor_files.dart';
import 'package:deskconn_mobile_app/core/text_editor/line_diff.dart';
import 'package:diff_match_patch/diff_match_patch.dart' as dmp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeLineDiff', () {
    test('marks inserted lines as added', () {
      expect(computeLineDiff('a\nb\n', 'a\nx\nb\n'), {1: LineChange.added});
    });

    test('marks replaced lines as modified', () {
      expect(computeLineDiff('a\nb\nc\n', 'a\nB\nc\n'), {1: LineChange.modified});
    });

    test('ignores deletions', () {
      expect(computeLineDiff('a\nb\nc\n', 'a\nc\n'), isEmpty);
    });
  });

  test('computeReviewLines numbers both sides', () {
    final lines = computeReviewLines('a\nb\n', 'a\nc\n')!;
    expect(lines.map((l) => (l.kind, l.oldNo, l.newNo, l.text)), [
      (ReviewKind.context, 1, 1, 'a'),
      (ReviewKind.removed, 2, null, 'b'),
      (ReviewKind.added, null, 2, 'c'),
    ]);
  });

  test('foldReviewLines folds long unchanged runs', () {
    final original = List.generate(20, (i) => 'line $i').join('\n');
    final current = original.replaceFirst('line 10', 'changed');
    final rows = foldReviewLines(computeReviewLines(original, current)!, 3, {});
    expect(rows.whereType<ReviewFold>().map((f) => (f.from, f.count)), [(0, 7), (15, 6)]);
  });

  test('buildEditPatch round-trips', () {
    const original = 'hello\nworld\n';
    const edited = 'hello\nbrave new world\n';
    final patch = buildEditPatch(original, edited);
    expect(dmp.patchApply(dmp.patchFromText(patch), original)[0], edited);
  });
}
