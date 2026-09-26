/// 头像用的首字符：跳过首尾空白，英文取大写；无有效字符返回 null。
String? firstGlyph(String? source) {
  final s = source?.trim() ?? '';
  if (s.isEmpty) return null;
  final first = String.fromCharCode(s.runes.first);
  final upper = first.toUpperCase();
  // 大写后若长度变化（如 ß → SS）则保留原字符，避免头像撑开。
  return upper.runes.length == 1 ? upper : first;
}
