import Testing
@testable import XToolSupport

@Test func deviceWaitHintAlwaysSuggestsUnlockAndTrust() {
    let message = DeviceWaitHint.message(environment: [:], socketExists: { _ in true })
    #expect(message.contains("unlocked"))
    #expect(!message.contains("usbmuxd is not running"))
}

#if os(Linux)
@Test func deviceWaitHintReportsMissingUsbmuxdSocket() {
    let message = DeviceWaitHint.message(environment: [:], socketExists: { _ in false })
    #expect(message.contains("usbmuxd is not running"))
}

@Test func deviceWaitHintNamesCustomSocketAddress() {
    let message = DeviceWaitHint.message(
        environment: ["USBMUXD_SOCKET_ADDRESS": "host.docker.internal:27015"],
        socketExists: { _ in false }
    )
    #expect(message.contains("host.docker.internal:27015"))
    #expect(!message.contains("usbmuxd is not running"))
}
#endif
