#include "flutter_window.h"

#include <knownfolders.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Windows' own save and folder dialogs, as the Mac uses its own through osascript. The save dialog asks before replacing
// a file, as the Mac's does. Nothing chosen gives no value.
std::optional<std::string> ChooseFile(HWND owner, bool folder, const std::wstring& title, const std::wstring& name) {
  Microsoft::WRL::ComPtr<IFileDialog> dialog;
  if (FAILED(CoCreateInstance(folder ? CLSID_FileOpenDialog : CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    return std::nullopt;
  }
  FILEOPENDIALOGOPTIONS options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | (folder ? FOS_PICKFOLDERS : FOS_OVERWRITEPROMPT));
  dialog->SetTitle(title.c_str());
  // start in Videos, where a clip goes when no file is chosen; Windows still prefers the last folder used here
  Microsoft::WRL::ComPtr<IShellItem> videos;
  if (SUCCEEDED(SHGetKnownFolderItem(FOLDERID_Videos, KF_FLAG_DEFAULT, nullptr, IID_PPV_ARGS(&videos)))) {
    dialog->SetDefaultFolder(videos.Get());
  }
  if (!folder) {
    COMDLG_FILTERSPEC mp4[] = {{L"MP4 video", L"*.mp4"}};
    dialog->SetFileTypes(1, mp4);
    dialog->SetDefaultExtension(L"mp4");
    dialog->SetFileName(name.c_str());
  }
  Microsoft::WRL::ComPtr<IShellItem> item;
  PWSTR path = nullptr;
  if (FAILED(dialog->Show(owner)) || FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
    return std::nullopt;
  }
  std::string chosen = Utf8FromUtf16(path);
  CoTaskMemFree(path);
  return chosen;
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(), length);
  return wide;
}

// the window's size on opening and the smallest it can be made, in logical pixels as on the Mac
constexpr int kWidth = 1320, kHeight = 820, kMinWidth = 1100, kMinHeight = 640;
constexpr wchar_t kPlacementKey[] = L"Software\\Geomglot\\OPRivViewReplay";
constexpr wchar_t kPlacementValue[] = L"WindowPlacement";

double ScaleFor(HWND window) { return GetDpiForWindow(window) / 96.0; }

// a remembered place is used only if a good part of it is on a screen that is still attached
bool Reachable(const RECT& r) {
  HMONITOR monitor = MonitorFromRect(&r, MONITOR_DEFAULTTONULL);
  if (!monitor) return false;
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(monitor, &info);
  RECT overlap;
  return IntersectRect(&overlap, &r, &info.rcWork) && overlap.right - overlap.left > 100 && overlap.bottom - overlap.top > 100;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool hidden)
    : project_(project), hidden_(hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  if (!hidden_) PlaceWindow();

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // lets the preview take over the whole screen (Esc in the preview turns it off again through the same call), and opens
  // Windows' own save and folder dialogs
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "oprivview/window", &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "setFullScreen") {
      if (const auto* on = std::get_if<bool>(call.arguments())) SetFullScreen(*on);
      result->Success();
    } else if (method == "chooseSaveFile" || method == "chooseFolder") {
      const auto* name = std::get_if<std::string>(call.arguments());
      bool folder = method == "chooseFolder";
      auto chosen = ChooseFile(GetHandle(), folder, folder ? L"Save clips in" : L"Save the MP4 as", name ? Wide(*name) : L"");
      result->Success(chosen ? flutter::EncodableValue(*chosen) : flutter::EncodableValue());
    } else {
      result->NotImplemented();
    }
  });

  if (!hidden_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      this->Show();
    });
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::PlaceWindow() {
  HWND window = GetHandle();
  WINDOWPLACEMENT saved{};
  DWORD size = sizeof(saved);
  if (RegGetValue(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue, RRF_RT_REG_BINARY, nullptr, &saved, &size) == ERROR_SUCCESS &&
      size == sizeof(saved) && saved.length == sizeof(saved) && Reachable(saved.rcNormalPosition)) {
    saved.showCmd = SW_HIDE;  // shown on the first frame, as usual; the place and size are what is wanted here
    saved.flags = 0;
    SetWindowPlacement(window, &saved);
    return;
  }
  // first run, or last time's place is gone: centred on the screen the window is on, no bigger than that screen
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info);
  const RECT& work = info.rcWork;
  double scale = ScaleFor(window);
  int width = std::min(static_cast<int>(kWidth * scale), static_cast<int>(work.right - work.left));
  int height = std::min(static_cast<int>(kHeight * scale), static_cast<int>(work.bottom - work.top));
  SetWindowPos(window, nullptr, work.left + (work.right - work.left - width) / 2, work.top + (work.bottom - work.top - height) / 2,
               width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}

void FlutterWindow::SavePlacement() {
  if (hidden_ || full_screen_) return;  // full screen is not a place to come back to
  WINDOWPLACEMENT placement{sizeof(placement)};
  if (GetWindowPlacement(GetHandle(), &placement)) {
    RegSetKeyValue(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue, REG_BINARY, &placement, sizeof(placement));
  }
}

void FlutterWindow::SetFullScreen(bool on) {
  HWND window = GetHandle();
  if (on == full_screen_) return;
  if (on) {
    saved_style_ = GetWindowLongPtr(window, GWL_STYLE);
    GetWindowPlacement(window, &saved_placement_);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info);
    const RECT& r = info.rcMonitor;
    SetWindowLongPtr(window, GWL_STYLE, saved_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(window, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(window, GWL_STYLE, saved_style_);
    SetWindowPlacement(window, &saved_placement_);
    SetWindowPos(window, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  full_screen_ = on;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_CLOSE:
      SavePlacement();  // while the window is still there to ask; by WM_DESTROY its handle is already let go
      break;
    case WM_GETMINMAXINFO: {
      // the three panes need this much room
      double scale = ScaleFor(hwnd);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale);
      limits->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
