import Foundation
import XKit
import XUtils

/// Prints advice if we've been waiting a while for a device to show up.
///
/// A missing usbmuxd socket is not an error by itself: on Linux, udev often
/// starts usbmuxd only once a device is plugged in. But if nothing shows up
/// after a few seconds, a stopped usbmuxd or an untrusted device is the usual
/// cause, and we'd otherwise wait forever without saying why.
enum DeviceWaitHint {
    static let delay: Double = 5

    static func start() -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(seconds: delay)
            } catch {
                return
            }
            d.out.print(message(environment: ProcessInfo.processInfo.environment))
        }
    }

    static func message(
        environment: [String: String],
        socketExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var lines = ["No device found yet. Check that the device is connected, unlocked, and trusts this computer."]
        #if os(Linux)
        if let address = environment["USBMUXD_SOCKET_ADDRESS"], !address.isEmpty {
            lines.append("Looking for usbmuxd at \(address) (USBMUXD_SOCKET_ADDRESS); make sure it is reachable.")
        } else if !socketExists("/var/run/usbmuxd") {
            lines.append("""
            usbmuxd is not running (no socket at /var/run/usbmuxd). Install usbmuxd, then start it \
            with `sudo systemctl start usbmuxd` or by plugging the device in again.
            """)
        }
        #endif
        return lines.joined(separator: "\n")
    }
}
