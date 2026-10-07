# Changelog

## 0.1.2

**Improvements**
- Workbench: hide the language option for the IndexTTS2 2.0 model (it does not support language selection).
- Automatically retry a task once when it fails due to a connection problem.
- Pause the queue when the server is unavailable, instead of failing tasks one by one.

**Fixes**
- Fix the language option not taking effect for IndexTTS2 2.5.
- Fix occasional "connection refused" errors with the server.
- Fix unclear error when the emotion reference audio file is missing.

**Other**
- Update the Flutter version used for building to 3.47.6.

## 0.1.1

**New**
- Added a "Task timeout" option on the Settings page to adjust the maximum processing time of a single generation task.

**Improvements**
- Parameters are locked while the server is starting or running; stop the server first to change them, to avoid interrupted tasks or issues caused by frequent restarts.
- Polished the voice library list layout.
- Enforced a 1280×720 minimum window size.

**Fixes**
- Fixed the server not starting again after being stopped, and improved start/stop reliability.
- Fixed the model library not refreshing after the first available audio.cpp server is detected.

## 0.1.0

- Initial public release.
- Model library with multi-source downloads and variant descriptions.
- Workbench (TTS / ASR) with per-family field rules, timer, and player.
- Sessions and collections with metadata/audio separation.
- Voice library, generation history, server control.
- Bilingual UI (zh / en).
