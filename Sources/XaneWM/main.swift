#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = Server()

    func applicationDidFinishLaunching(_ notification: Notification) {
        server.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.shutdown()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)   // no Dock icon, no menu bar of its own
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
#else
print("XaneWM runs on macOS only. XaneCore and xanectl build on any platform.")
#endif
