# Changelog

## 0.1.4

**Model support**
- Added Ming 3.0 TTS 0.5B support (Ming 3.0 Audio Tiny is not included).

**Improvements**
- Show task numbers in the workbench and history to distinguish repeated generations of the same text.

**Fixes**
- Fixed multiple installed versions/quantizations of the same model still appearing as multiple specs in the workbench and failing task submission.
- Fixed abnormal list filtering after switching from the model library to the downloads tab and back.
- Disable audio.cpp / model weights / data directory settings while the server is running to avoid configuration and runtime state mismatch.
- Fixed the server starting automatically after changing directory settings while stopped, keeping startup manual.
- Fixed playback continuing after deleting a record during audition, and ensured the audio file is deleted normally.

**Other**
- Updated the bundled model spec library with new models and parameters from audio.cpp 0.9.2+.
- Aligned adapted models with the latest specs and completed advanced parameter controls for some models.

## 0.1.3

**New**
- Voice conversion (VC) support (offline), with MeanVC2 adapted.

**Improvements**
- Automatic recovery and retry after a task timeout or wedged inference.
- Close the player when switching sessions.
- Show a loading state at startup.
- Unify UI messages and wording.
- Collapse the installed models section.
- New sessions inherit the current collection.

**Fixes**
- Fix the task timeout setting being reset.
- Fix abnormal timeout slider behavior.
- Fix the status bar text when the service stops.

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
