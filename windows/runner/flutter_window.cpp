#include "flutter_window.h"

#include <commctrl.h>
#include <shellapi.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <climits>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view);
  if (SetWindowSubclass(view, DropWindowProc, 0,
                        reinterpret_cast<DWORD_PTR>(this))) {
    drop_window_ = view;
    DragAcceptFiles(view, TRUE);
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (drop_window_) {
    DragAcceptFiles(drop_window_, FALSE);
    RemoveWindowSubclass(drop_window_, DropWindowProc, 0);
    drop_window_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::DropWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR subclass_id,
    DWORD_PTR ref_data) {
  auto* window = reinterpret_cast<FlutterWindow*>(ref_data);
  if (message == WM_DROPFILES) {
    const std::unique_ptr<std::remove_pointer_t<HDROP>, decltype(&DragFinish)>
        drop(reinterpret_cast<HDROP>(wparam), DragFinish);
    const UINT count = DragQueryFileW(drop.get(), UINT_MAX, nullptr, 0);
    flutter::EncodableList paths;
    for (UINT i = 0; i < count; ++i) {
      const UINT length = DragQueryFileW(drop.get(), i, nullptr, 0);
      if (length == 0) continue;
      std::wstring path(length + 1, L'\0');
      if (DragQueryFileW(drop.get(), i, path.data(), length + 1) == 0) continue;
      const std::string utf8 = Utf8FromUtf16(path.c_str());
      if (!utf8.empty()) paths.emplace_back(utf8);
    }
    if (!paths.empty() && window->flutter_controller_) {
      flutter::MethodChannel<flutter::EncodableValue> channel(
          window->flutter_controller_->engine()->messenger(),
          "pdf_text_editor/file_drop",
          &flutter::StandardMethodCodec::GetInstance());
      channel.InvokeMethod(
          "drop", std::make_unique<flutter::EncodableValue>(std::move(paths)));
    }
    return 0;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, DropWindowProc, subclass_id);
    window->drop_window_ = nullptr;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
