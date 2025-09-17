import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Install the plugin’s provider early so Dock text/URL drops are accepted at launch.
    if NSApp.servicesProvider == nil,
       let cls = NSClassFromString("DesktopDropServicesProvider") as? NSObject.Type {
      NSApp.servicesProvider = cls.init()
    }
  }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
