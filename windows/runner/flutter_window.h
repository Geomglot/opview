#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// The replay window, as the Mac's MainFlutterWindow.swift does it: room for the three panes, put back where it was last
// time, full screen for the preview on request. With [hidden] (a render job) it is never shown at all: the render draws
// its own frames and needs no screen.
class FlutterWindow : public Win32Window {
 public:
  FlutterWindow(const flutter::DartProject& project, bool hidden);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void PlaceWindow();
  void SavePlacement();
  void SetFullScreen(bool on);

  flutter::DartProject project_;
  bool hidden_;
  bool full_screen_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_{sizeof(WINDOWPLACEMENT)};

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
