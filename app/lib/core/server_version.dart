const String kMinimumAudioCppVersion = '0.9.3';

enum ServerVersionStatus { supported, tooOld, unknown }

ServerVersionStatus serverVersionStatus(String version) {
  final raw = version.trim();
  if (raw.isEmpty) return ServerVersionStatus.tooOld;

  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
  if (match == null) return ServerVersionStatus.unknown;

  final current = [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
  final minimumMatch =
      RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(kMinimumAudioCppVersion)!;
  final minimum = [
    int.parse(minimumMatch.group(1)!),
    int.parse(minimumMatch.group(2)!),
    int.parse(minimumMatch.group(3)!),
  ];
  for (var i = 0; i < minimum.length; i++) {
    if (current[i] == minimum[i]) continue;
    return current[i] > minimum[i]
        ? ServerVersionStatus.supported
        : ServerVersionStatus.tooOld;
  }
  return ServerVersionStatus.supported;
}
