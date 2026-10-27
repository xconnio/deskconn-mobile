import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

const int _maxDiffSize = 2 * 1024 * 1024;

enum LineChange { added, modified }

enum ReviewKind { context, added, removed }

class ReviewLine {
  final ReviewKind kind;
  final int? oldNo;
  final int? newNo;
  final String text;

  const ReviewLine(this.kind, this.oldNo, this.newNo, this.text);
}

class ReviewFold {
  final int from;
  final int count;

  const ReviewFold(this.from, this.count);
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (text.endsWith('\n')) lines.removeLast();
  return lines;
}

List<(int, List<String>)> _lineDiff(String original, String current) {
  final tokens = <String, int>{};
  final lineArray = <String>[];
  String encode(String text) {
    final buffer = StringBuffer();
    var start = 0;
    while (start < text.length) {
      var end = text.indexOf('\n', start);
      end = end == -1 ? text.length : end + 1;
      final line = text.substring(start, end);
      final code = tokens.putIfAbsent(line, () {
        lineArray.add(line);
        return lineArray.length - 1;
      });
      buffer.writeCharCode(code);
      start = end;
    }
    return buffer.toString();
  }

  final chars1 = encode(original);
  final chars2 = encode(current);
  return [
    for (final d in dmp.diff(chars1, chars2, checklines: false))
      (d.operation, [for (final unit in d.text.codeUnits) lineArray[unit]]),
  ];
}

Map<int, LineChange> computeLineDiff(String original, String current) {
  final map = <int, LineChange>{};
  if (original == current || original.length > _maxDiffSize || current.length > _maxDiffSize) return map;
  var line = 0;
  int? previous;
  for (final (op, lines) in _lineDiff(original, current)) {
    if (op == dmp.DIFF_EQUAL) {
      line += lines.length;
    } else if (op == dmp.DIFF_INSERT) {
      final kind = previous == dmp.DIFF_DELETE ? LineChange.modified : LineChange.added;
      for (var i = 0; i < lines.length; i++) {
        map[line + i] = kind;
      }
      line += lines.length;
    }
    previous = op;
  }
  return map;
}

List<ReviewLine>? computeReviewLines(String original, String current) {
  if (original.length > _maxDiffSize || current.length > _maxDiffSize) return null;
  final result = <ReviewLine>[];
  var oldNo = 1;
  var newNo = 1;
  for (final (op, lines) in _lineDiff(original, current)) {
    for (final line in _splitLines(lines.join())) {
      if (op == dmp.DIFF_EQUAL) {
        result.add(ReviewLine(ReviewKind.context, oldNo++, newNo++, line));
      } else if (op == dmp.DIFF_DELETE) {
        result.add(ReviewLine(ReviewKind.removed, oldNo++, null, line));
      } else {
        result.add(ReviewLine(ReviewKind.added, null, newNo++, line));
      }
    }
  }
  return result;
}

List<Object> foldReviewLines(List<ReviewLine> lines, int context, Set<int> expanded) {
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].kind == ReviewKind.context) continue;
    for (var j = (i - context).clamp(0, lines.length - 1); j <= (i + context).clamp(0, lines.length - 1); j++) {
      keep[j] = true;
    }
  }
  final rows = <Object>[];
  var i = 0;
  while (i < lines.length) {
    if (keep[i]) {
      rows.add(lines[i++]);
      continue;
    }
    var end = i;
    while (end < lines.length && !keep[end]) {
      end++;
    }
    if (end - i == 1 || expanded.contains(i)) {
      rows.addAll(lines.sublist(i, end));
    } else {
      rows.add(ReviewFold(i, end - i));
    }
    i = end;
  }
  return rows;
}
