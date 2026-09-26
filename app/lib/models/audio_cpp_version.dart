import 'dart:io';

class AudioCppVersion {
  AudioCppVersion({
    required this.path,
    required this.name,
    required this.serverExe,
  });

  final String path;
  final String name;
  final File serverExe;
}