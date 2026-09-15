#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutex[] = L"Local\\StickerManager.SingleInstance";
constexpr wchar_t kInstanceReadyEvent[] = L"Local\\StickerManager.InstanceReady";
constexpr DWORD kExistingInstanceTimeoutMs = 10000;
constexpr DWORD kExistingInstancePollMs = 50;

bool ActivateExistingWindow() {
  HWND existing = nullptr;
  const int attempts = static_cast<int>(
      kExistingInstanceTimeoutMs / kExistingInstancePollMs);
  for (int attempt = 0; attempt < attempts && existing == nullptr; ++attempt) {
    existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"sticker_manager");
    if (existing != nullptr) break;

    // The ready event is created after the mutex, so opening it can race with
    // the first Flutter frame. Polling the event name keeps that race bounded
    // without blocking the duplicate process indefinitely.
    HANDLE ready_event = OpenEventW(SYNCHRONIZE, FALSE, kInstanceReadyEvent);
    if (ready_event != nullptr) {
      WaitForSingleObject(ready_event, kExistingInstancePollMs);
      CloseHandle(ready_event);
    } else {
      Sleep(kExistingInstancePollMs);
    }
  }
  if (existing == nullptr) return false;
  if (!IsWindowVisible(existing)) {
    ShowWindow(existing, SW_SHOW);
  } else if (IsIconic(existing)) {
    ShowWindow(existing, SW_RESTORE);
  }
  const DWORD current_thread = GetCurrentThreadId();
  const DWORD target_thread = GetWindowThreadProcessId(existing, nullptr);
  bool attached = false;
  if (target_thread != 0 && target_thread != current_thread) {
    attached = AttachThreadInput(current_thread, target_thread, TRUE) != FALSE;
  }
  BringWindowToTop(existing);
  const BOOL foreground = SetForegroundWindow(existing);
  if (attached) AttachThreadInput(current_thread, target_thread, FALSE);
  // A duplicate launch is a management entry point. Ask the existing Dart
  // controller to leave quick-picker mode before it is shown.
  PostMessage(existing, FlutterWindow::kRestoreManagementMessage, 0, 0);
  return foreground != FALSE || GetForegroundWindow() == existing;
}

bool AcquiredReleasedMutex(HANDLE mutex) {
  const DWORD result = WaitForSingleObject(mutex, 0);
  return result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  SetLastError(ERROR_SUCCESS);
  HANDLE single_instance =
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  // A failed mutex creation means the single-instance guarantee cannot be
  // established. Exit instead of allowing a second unmanaged process.
  if (single_instance == nullptr) {
    return EXIT_FAILURE;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (ActivateExistingWindow()) {
      CloseHandle(single_instance);
      return EXIT_SUCCESS;
    }

    // If the first process crashed during startup, its mutex is released even
    // though it never signalled the ready event. Take ownership and continue
    // as the primary process instead of exiting without an application.
    if (!AcquiredReleasedMutex(single_instance)) {
      CloseHandle(single_instance);
      return EXIT_SUCCESS;
    }
  }

  HANDLE ready_event = CreateEventW(nullptr, TRUE, FALSE, kInstanceReadyEvent);
  if (ready_event == nullptr) {
    CloseHandle(single_instance);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // The management view starts at a dense, comfortably resizable size. The
  // Flutter controller restores the user's last size and maximized state once
  // window_manager is ready, while the global hotkey temporarily uses its
  // compact 760x600 picker layout.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 760);
  if (!window.Create(L"sticker_manager", origin, size)) {
    if (SUCCEEDED(com_result)) {
      ::CoUninitialize();
    }
    CloseHandle(ready_event);
    CloseHandle(single_instance);
    return EXIT_FAILURE;
  }
  SetEvent(ready_event);
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (SUCCEEDED(com_result)) {
    ::CoUninitialize();
  }
  CloseHandle(ready_event);
  CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
