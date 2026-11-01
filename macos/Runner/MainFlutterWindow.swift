import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // the replay window needs room for its three panes; a render job sizes its own picture, so leave that alone
    self.isRestorable = false // otherwise macOS puts back the size and place from the last run
    if ProcessInfo.processInfo.environment["OPRIVVIEW_JOB"] == nil, let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      let size = NSSize(width: min(1320, visible.width), height: min(820, visible.height))
      let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
      self.setFrame(NSRect(origin: origin, size: size), display: true)
      self.contentMinSize = NSSize(width: 1100, height: 640)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
