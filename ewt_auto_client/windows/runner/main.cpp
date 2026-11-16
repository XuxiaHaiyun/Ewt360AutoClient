#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Suppress Windows hard-error dialogs during DLL loading. Failures are still
  // reported via GetLastError() and logged below. This prevents modal popups
  // from blocking startup when a DLL cannot load.
  ::SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Flutter engine calls SetDefaultDllDirectories on startup, which restricts
  // the DLL search path. This prevents ffmpeg_kit's MinGW runtime DLLs
  // (libstdc++-6.dll, etc.) from being found as indirect dependencies of
  // libffmpegkit.dll. Pre-load all dependency DLLs here with
  // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR so that each DLL's own dependencies are
  // resolved from its directory. Once loaded, the modules stay in the
  // process address space and the plugin's subsequent LoadLibraryA call will
  // return the already-loaded handle.
  //
  // Previously used LOAD_WITH_ALTERED_SEARCH_PATH (deprecated), which caused
  // err=127 (ERROR_PROC_NOT_FOUND) on some Windows versions. Switched to
  // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR + LOAD_LIBRARY_SEARCH_SYSTEM32 with retry.
  {
    wchar_t exe_path[MAX_PATH] = {0};
    if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {
      std::wstring dir(exe_path);
      size_t pos = dir.find_last_of(L"\\/");
      if (pos != std::wstring::npos) {
        dir = dir.substr(0, pos);

        // Modern load flags: search DLL's own directory + System32 only
        // (no PATH search, prevents conflicting DLLs from other dirs)
        const DWORD kSearchFlags =
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;

        // FFmpeg dependency chain (in dependency order)
        const wchar_t* dlls[] = {
            L"libwinpthread-1.dll", L"libgcc_s_seh-1.dll",
            L"libstdc++-6.dll",     L"libbz2-1.dll",
            L"libiconv-2.dll",      L"liblzma-5.dll",
            L"zlib1.dll",           L"zlib.dll",
            L"libva.dll",           L"libva_win32.dll",
            L"avutil-60.dll",       L"swresample-6.dll",
            L"avcodec-62.dll",      L"avformat-62.dll",
            L"avfilter-11.dll",     L"swscale-9.dll",
            L"avdevice-62.dll",     L"libffmpegkit.dll",
        };

        FILE* logf = nullptr;
        fopen_s(&logf, "dll_load_errors.log", "a");
        if (logf) {
          fprintf(logf, "=== DLL pre-load session ===\n");
        }

        for (const auto* dll : dlls) {
          std::wstring full_path = dir + L"\\" + dll;
          HMODULE h = nullptr;
          DWORD err = 0;

          // Retry 3 times (handles transient issues like AV file locks)
          for (int attempt = 0; attempt < 3 && h == nullptr; attempt++) {
            // Check if already loaded (by previous retry or system)
            h = ::GetModuleHandleW(dll);
            if (h != nullptr) {
              if (logf) {
                fprintf(logf, "Already loaded: %ls\n", dll);
              }
              break;
            }
            h = ::LoadLibraryExW(full_path.c_str(), nullptr, kSearchFlags);
            if (h == nullptr) {
              err = ::GetLastError();
              if (attempt < 2) ::Sleep(100);  // Wait before retry
            }
          }

          if (h == nullptr) {
            if (logf) {
              // Get human-readable error message
              char err_msg[256] = {0};
              FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM, nullptr, err,
                              MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                              err_msg, 256, nullptr);
              fprintf(logf, "FAILED: %ls (err=%lu: %s)\n", dll, err, err_msg);
            }
          }
        }

        if (logf) {
          fprintf(logf, "=== session end ===\n\n");
          fclose(logf);
        }
      }
    }
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"EwtAutoClient", origin, size)) {
    return EXIT_FAILURE;
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
