import '../../../models/session.dart';

/// 当前 ASR 语言是否使用词间空格。
bool asrLanguageUsesSpaces(String? language) {
  final value = (language ?? '').trim().toLowerCase();
  if (value.isEmpty || value == 'auto') return true;
  final base = value.split(RegExp(r'[-_]')).first;
  const noSpace = {
    'chinese',
    'cantonese',
    'japanese',
    'thai',
    'zh',
    'yue',
    'ja',
    'th',
    'zho',
    'cmn',
  };
  return !noSpace.contains(value) && !noSpace.contains(base);
}

class AsrSrtCue {
  const AsrSrtCue({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  final int index;
  final dynamic start;
  final dynamic end;
  final String text;
}

class _SentencePiece {
  const _SentencePiece({
    required this.word,
    required this.displayStart,
    required this.displayEnd,
  });

  final dynamic word;
  final int displayStart;
  final int displayEnd;
}

/// 用记录里的 text + words 生成字幕 cue。
class AsrSrt {
  AsrSrt(this.record) {
    cues = _buildCues();
  }

  final GenerationRecord record;
  late final List<AsrSrtCue> cues;

  static final RegExp _sentencePattern = RegExp(
      r'[^.!?;\u3002\uff01\uff1f\uff1b\u2026\n]+[.!?;\u3002\uff01\uff1f\uff1b\u2026]?');
  static final RegExp _sentenceEnd =
      RegExp(r'[.!?;\u3002\uff01\uff1f\uff1b\u2026]');
  static final RegExp _clausePunct = RegExp(r'[,\uff0c:\uff1a]');
  static final RegExp _listPunct = RegExp(r'\u3001');
  static final RegExp _matchNoise =
      RegExp(r'[\s.!?;\u3002\uff01\uff1f\uff1b\u2026\uff0c\u3001,\uff1a:]');
  static final RegExp _spaceRun = RegExp(r'\s+');
  static final RegExp _trailingPunct =
      RegExp(r'[.!?;\u3002\uff01\uff1f\uff1b\u2026\uff0c\u3001,\uff1a:]+$');

  static const int _minWidth = 26;
  static const int _targetWidth = 32;
  static const int _maxWidth = 38;
  static const int _hardMaxWidth = 48;
  static const int _sentenceKeepWidth = 38;

  List<dynamic> get _words {
    final words = record.ret?['words'];
    return words is List ? words : const [];
  }

  String get _language => record.ret?['language']?.toString() ?? '';

  String _wordText(dynamic item) =>
      item is Map ? item['word']?.toString() ?? '' : item.toString();

  dynamic _sample(dynamic item, String key) => item is Map ? item[key] : null;

  double _seconds(dynamic sample) =>
      sample is num ? sample.toDouble() / 16000 : 0;

  String _matchKey(String text) =>
      text.toLowerCase().replaceAll(_matchNoise, '');

  String _displayText(String text, bool noSpaces) =>
      text.replaceAll(_spaceRun, noSpaces ? '' : ' ').trim();

  String _withoutTrailingPunctuation(String text) =>
      text.replaceFirst(_trailingPunct, '').trimRight();

  int _displayWidth(String text) {
    var width = 0;
    for (final rune in text.runes) {
      width += rune < 0x80 ? 1 : 2;
    }
    return width;
  }

  String _joinWords(List<dynamic> words, bool noSpaces) {
    final parts = <String>[];
    for (final item in words) {
      final text = _wordText(item).trim();
      if (text.isNotEmpty) parts.add(text);
    }
    return noSpaces ? parts.join() : parts.join(' ');
  }

  List<AsrSrtCue> _buildCues() {
    final words = _words;
    final text = record.displayText;
    final noSpaces = !asrLanguageUsesSpaces(_language);
    if (text.isNotEmpty && _sentenceEnd.hasMatch(text)) {
      final fromText = _cuesFromText(words, text, noSpaces);
      if (fromText != null) return fromText;
    }
    return _cuesFromWords(words, noSpaces);
  }

  List<AsrSrtCue>? _cuesFromText(
    List<dynamic> words,
    String text,
    bool noSpaces,
  ) {
    final flat = <({String ch, int word})>[];
    for (var i = 0; i < words.length; i++) {
      final key = _matchKey(_wordText(words[i]));
      for (final ch in key.split('')) {
        flat.add((ch: ch, word: i));
      }
    }
    if (flat.isEmpty) return null;

    final cues = <AsrSrtCue>[];
    var cursor = 0;
    var index = 1;
    for (final match in _sentencePattern.allMatches(text)) {
      final raw = match.group(0)?.trim() ?? '';
      if (raw.isEmpty) continue;
      final display = _displayText(raw, noSpaces);
      final key = _matchKey(display);
      if (key.isEmpty) continue;

      final firstCursor = cursor;
      var matched = 0;
      while (matched < key.length &&
          cursor < flat.length &&
          flat[cursor].ch == key[matched]) {
        cursor++;
        matched++;
      }
      if (matched != key.length) return null;

      final first = flat[firstCursor].word;
      final last = flat[cursor - 1].word;
      final sentenceCues =
          _splitSentence(words.sublist(first, last + 1), display, index);
      cues.addAll(sentenceCues);
      index += sentenceCues.length;
    }
    if (cues.isEmpty || cursor != flat.length) return null;
    return cues;
  }

  List<_SentencePiece> _sentencePieces(
    List<dynamic> words,
    String display,
  ) {
    final pieces = <_SentencePiece>[];
    var displayIndex = 0;
    for (final word in words) {
      final key = _matchKey(_wordText(word));
      if (key.isEmpty) continue;
      var start = -1;
      for (final ch in key.split('')) {
        while (displayIndex < display.length &&
            display[displayIndex].toLowerCase() != ch) {
          displayIndex++;
        }
        if (displayIndex >= display.length) return const [];
        start = start < 0 ? displayIndex : start;
        displayIndex++;
      }
      pieces.add(_SentencePiece(
        word: word,
        displayStart: start,
        displayEnd: displayIndex,
      ));
    }
    return pieces;
  }

  String _segmentText(
    String display,
    List<_SentencePiece> pieces,
    int start,
    int end,
  ) {
    final endDisplay =
        end + 1 < pieces.length ? pieces[end + 1].displayStart : display.length;
    return display.substring(pieces[start].displayStart, endDisplay).trim();
  }

  double _segmentDuration(List<_SentencePiece> pieces, int start, int end) {
    final begin = _seconds(_sample(pieces[start].word, 'start_sample'));
    final finish = _seconds(_sample(pieces[end].word, 'end_sample'));
    return finish > begin ? finish - begin : 0;
  }

  bool _insideListItem(String display, List<_SentencePiece> pieces, int end) {
    final endAt = pieces[end].displayEnd;
    if (endAt <= 0) return false;
    final next = display.indexOf('\u3001', endAt);
    if (next == endAt) return false;
    if (next > endAt) {
      final remaining = display.substring(endAt, next);
      if (_matchKey(remaining).length <= 1) return true;
    }
    final previous = display.lastIndexOf('\u3001', endAt - 1);
    if (previous < 0) return false;
    final between = display.substring(previous + 1, endAt);
    if (_clausePunct.hasMatch(between) || _sentenceEnd.hasMatch(between)) {
      return false;
    }
    if (_matchKey(between).length <= 1) return true;
    return next > endAt;
  }

  double _boundaryCost(
    String display,
    List<_SentencePiece> pieces,
    int end,
  ) {
    if (end == pieces.length - 1) return 0;
    final nextStart = pieces[end + 1].displayStart;
    final gapText = display.substring(pieces[end].displayEnd, nextStart);
    if (_sentenceEnd.hasMatch(gapText)) return 0;
    if (_clausePunct.hasMatch(gapText)) return 1;
    if (_insideListItem(display, pieces, end)) return 1000;
    if (_listPunct.hasMatch(gapText)) return 1000;
    final gap = _seconds(
          _sample(pieces[end + 1].word, 'start_sample'),
        ) -
        _seconds(_sample(pieces[end].word, 'end_sample'));
    if (gap > 0.45) return 3;
    return 50;
  }

  bool _mustBreakAtClause(String text) {
    for (final match in _clausePunct.allMatches(text)) {
      if (match.start >= text.length - 1) continue;
      final prefix = text.substring(0, match.start + 1);
      if (_displayWidth(prefix) >= _minWidth) return true;
    }
    return false;
  }

  double _segmentCost(
    String display,
    List<_SentencePiece> pieces,
    int start,
    int end,
  ) {
    final text = _segmentText(display, pieces, start, end);
    if (_mustBreakAtClause(text)) return double.infinity;
    final width = _displayWidth(text);
    final whole = start == 0 && end == pieces.length - 1;
    if (width > _hardMaxWidth) {
      return start == end ? 1000.0 + width : double.infinity;
    }
    var cost = (width - _targetWidth).abs().toDouble();
    if (width > _maxWidth) {
      cost += (width - _maxWidth) * 5.0;
    }
    if (!whole && width < _minWidth) {
      cost += (_minWidth - width) * 6.0;
    }
    final duration = _segmentDuration(pieces, start, end);
    if (duration > 7.0) cost += (duration - 7.0) * 8.0;
    cost += _boundaryCost(display, pieces, end);
    return cost;
  }

  List<AsrSrtCue> _splitSentence(
    List<dynamic> words,
    String display,
    int startIndex,
  ) {
    final pieces = _sentencePieces(words, display);
    if (pieces.isEmpty) return const [];
    if (_displayWidth(display) <= _sentenceKeepWidth) {
      return [
        AsrSrtCue(
          index: startIndex,
          start: _sample(pieces.first.word, 'start_sample'),
          end: _sample(pieces.last.word, 'end_sample'),
          text: _withoutTrailingPunctuation(display),
        ),
      ];
    }
    final n = pieces.length;
    final dp = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);

    for (var end = 0; end < n; end++) {
      for (var start = 0; start <= end; start++) {
        final base = start == 0 ? 0.0 : dp[start - 1];
        if (!base.isFinite) continue;
        final cost = _segmentCost(display, pieces, start, end);
        if (!cost.isFinite) continue;
        final total = base + cost;
        if (total < dp[end]) {
          dp[end] = total;
          prev[end] = start - 1;
        }
      }
    }

    final ranges = <({int start, int end})>[];
    var end = n - 1;
    while (end >= 0) {
      final start = prev[end] + 1;
      ranges.add((start: start, end: end));
      if (start == 0) break;
      end = start - 1;
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));

    var index = startIndex;
    return [
      for (final range in ranges)
        AsrSrtCue(
          index: index++,
          start: _sample(pieces[range.start].word, 'start_sample'),
          end: _sample(pieces[range.end].word, 'end_sample'),
          text: _withoutTrailingPunctuation(
            _segmentText(display, pieces, range.start, range.end),
          ),
        ),
    ];
  }

  List<AsrSrtCue> _cuesFromWords(List<dynamic> words, bool noSpaces) {
    final groups = <List<dynamic>>[];
    var group = <dynamic>[];
    double? groupStart;
    double? lastEnd;
    var width = 0;

    void flush() {
      if (group.isEmpty) return;
      groups.add(List<dynamic>.from(group));
      group = <dynamic>[];
      groupStart = null;
      lastEnd = null;
      width = 0;
    }

    for (final item in words) {
      final text = _wordText(item).trim();
      if (text.isEmpty) continue;
      final start = _sample(item, 'start_sample');
      final end = _sample(item, 'end_sample');
      final startSec = _seconds(start);
      final endSec = _seconds(end);
      final itemWidth = _displayWidth(text);
      if (group.isNotEmpty) {
        final gap = startSec - (lastEnd ?? startSec);
        final duration = endSec - (groupStart ?? startSec);
        if (gap > 0.45 || duration > 5.0 || width + itemWidth > _maxWidth) {
          flush();
        }
      }
      groupStart ??= startSec;
      group.add(item);
      width += itemWidth;
      lastEnd = endSec;
    }
    flush();

    return [
      for (var i = 0; i < groups.length; i++)
        AsrSrtCue(
          index: i + 1,
          start: _sample(groups[i].first, 'start_sample'),
          end: _sample(groups[i].last, 'end_sample'),
          text: _withoutTrailingPunctuation(
            _joinWords(groups[i], noSpaces),
          ),
        ),
    ];
  }

  String _srtTime(dynamic value) {
    final sample = value is num ? value.toDouble() : 0.0;
    final totalMs = (sample * 1000 / 16000).round();
    final hours = totalMs ~/ 3600000;
    final minutes = (totalMs % 3600000) ~/ 60000;
    final seconds = (totalMs % 60000) ~/ 1000;
    final millis = totalMs % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)},${three(millis)}';
  }

  String _previewTime(dynamic value) {
    final sample = value is num ? value.toDouble() : 0.0;
    final totalSeconds = (sample / 16000).floor();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
    return '${two(minutes)}:${two(seconds)}';
  }

  String get preview {
    final out = StringBuffer();
    for (final cue in cues) {
      out.writeln(
          '#${cue.index}  ${_previewTime(cue.start)} ~ ${_previewTime(cue.end)}');
      out.writeln(cue.text);
      out.writeln();
    }
    return out.toString().trimRight();
  }

  String get srt {
    final out = StringBuffer();
    for (final cue in cues) {
      out.writeln(cue.index);
      out.writeln('${_srtTime(cue.start)} --> ${_srtTime(cue.end)}');
      out.writeln(cue.text);
      out.writeln();
    }
    return out.toString().trimRight();
  }
}
