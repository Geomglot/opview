import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // the replay window needs room for its three panes; a render job draws off screen, so it shows no window or Dock icon
    self.isRestorable = false // otherwise macOS puts back the size and place from the last run
    if ProcessInfo.processInfo.environment["OPRIVVIEW_JOB"] != nil {
      NSApp.setActivationPolicy(.accessory)
      self.alphaValue = 0
      self.ignoresMouseEvents = true
      DispatchQueue.main.async { self.orderOut(nil) }
    } else if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      self.contentMinSize = NSSize(width: 1100, height: 640)
      let size = NSSize(width: min(1320, visible.width), height: min(820, visible.height))
      let opening = NSRect(origin: NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2), size: size)
      self.setFrame(opening, display: true)
      // back where it was last time, unless that was on a screen that is no longer attached
      self.setFrameAutosaveName("OPRivViewReplay")
      self.setFrameUsingName("OPRivViewReplay")
      let reachable = NSScreen.screens.contains { $0.visibleFrame.intersection(self.frame).width > 100 && $0.visibleFrame.intersection(self.frame).height > 100 }
      if !reachable {
        self.setFrame(opening, display: true)
      }
      fullScreenChannel(flutterViewController)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // lets the preview take over the whole screen, and tells it when macOS's own controls end that
  private func fullScreenChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "oprivview/window", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setFullScreen", let want = call.arguments as? Bool, let window = self {
        if window.styleMask.contains(.fullScreen) != want { window.toggleFullScreen(nil) }
      }
      result(nil)
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { _ in
      channel.invokeMethod("exitedFullScreen", arguments: nil)
    }
  }
}
