import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Automation hook: AILIA_WINDOW_SIZE=1280x720 sets the initial
    // window size (used together with AILIA_SCREENSHOT). Applied one
    // tick later so window state restoration cannot override it.
    if let sizeStr = ProcessInfo.processInfo.environment["AILIA_WINDOW_SIZE"] {
      let parts = sizeStr.split(separator: "x").compactMap { Double($0) }
      if parts.count == 2 {
        DispatchQueue.main.async {
          var frame = self.frame
          frame.size = NSSize(width: parts[0], height: parts[1])
          self.setFrame(frame, display: true)
        }
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
