#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

/// Tamano inicial de la ventana, ajustado a la pantalla real.
///
/// La plantilla de Flutter abre siempre 1280x720. En una pantalla de exactamente
/// 1280x720 (portatiles, maquinas virtuales, monitores pequenos) la ventana
/// queda **fuera de la pantalla por abajo**, y el usuario no puede ver ni
/// alcanzar los controles inferiores. Aqui se toma el area de trabajo real
/// (descontando la barra de tareas) y se deja margen para el borde y la barra de
/// titulo.
Win32Window::Size PreferredWindowSize(Win32Window::Point* origin) {
  const int kDesiredWidth = 1280;
  const int kDesiredHeight = 800;

  RECT work_area = {0, 0, kDesiredWidth, kDesiredHeight};
  if (::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0)) {
    const int available_width = work_area.right - work_area.left;
    const int available_height = work_area.bottom - work_area.top;

    // Margen para que la ventana no toque los bordes de la pantalla.
    const int margin = 8;
    int width = kDesiredWidth;
    int height = kDesiredHeight;

    if (width > available_width - margin) {
      width = available_width - margin;
    }
    if (height > available_height - margin) {
      height = available_height - margin;
    }

    // La ventana se abre centrada en el area de trabajo.
    origin->x = work_area.left + (available_width - width) / 2;
    origin->y = work_area.top + (available_height - height) / 2;
    return Win32Window::Size(width, height);
  }

  // Sin informacion de pantalla, se usa un tamano conservador.
  *origin = Win32Window::Point(10, 10);
  return Win32Window::Size(1024, 700);
}

}  // namespace

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
  Win32Window::Point origin(10, 10);
  Win32Window::Size size = PreferredWindowSize(&origin);
  if (!window.Create(L"Xtreme Studio", origin, size)) {
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
