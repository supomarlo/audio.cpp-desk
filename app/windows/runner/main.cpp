#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Optional saved window rect (physical outer rect). Applied after Create via
  // SetWindowPos, because Create scales logical -> physical using monitor DPI.
  RECT saved = {};
  bool has_saved = false;
  {
    const std::wstring ini = WindowStatePath();
    auto readInt = [&](const wchar_t* key) {
      wchar_t s[32];
      ::GetPrivateProfileStringW(L"window", key, L"", s, 32, ini.c_str());
      return s[0] == 0 ? 0 : _wtoi(s);
    };
    const int x = readInt(L"x");
    const int y = readInt(L"y");
    const int w = readInt(L"w");
    const int h = readInt(L"h");
    if (w >= 400 && h >= 300) {
      saved = {x, y, x + w, y + h};
      // Ignore rects that no longer intersect any monitor.
      if (::MonitorFromRect(&saved, MONITOR_DEFAULTTONULL) != nullptr) {
        has_saved = true;
      }
    }
  }
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"audio.cpp Desk", origin, size)) {
    return EXIT_FAILURE;
  }
  if (has_saved) {
    ::SetWindowPos(window.GetHandle(), nullptr, saved.left, saved.top,
                   saved.right - saved.left, saved.bottom - saved.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
