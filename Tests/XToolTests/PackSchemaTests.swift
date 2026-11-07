import Testing
@testable import PackLib

@Test func knownKeysProduceNoWarnings() {
    let yaml = """
    version: 1
    bundleID: com.example.app
    entitlementsPath: App.entitlements
    extensions:
      - product: Widget
        infoPath: Widget-Info.plist
    """
    #expect(PackSchema.unknownKeyWarnings(inYAML: yaml).isEmpty)
}

@Test func unknownKeysAreReportedWithSuggestions() {
    let yaml = """
    version: 1
    bundleId: com.example.app
    entitlements: App.entitlements
    icon: Icon.png
    extension: []
    somethingElse: true
    extensions:
      - product: Widget
        infoPath: Widget-Info.plist
        entitlement: Widget.entitlements
    """
    #expect(PackSchema.unknownKeyWarnings(inYAML: yaml) == [
        "xtool.yml: unknown key 'bundleId' will be ignored. Did you mean 'bundleID'?",
        "xtool.yml: unknown key 'entitlements' will be ignored. Did you mean 'entitlementsPath'?",
        "xtool.yml: unknown key 'extension' will be ignored. Did you mean 'extensions'?",
        "xtool.yml: unknown key 'icon' will be ignored. Did you mean 'iconPath'?",
        "xtool.yml: unknown key 'somethingElse' will be ignored.",
        "xtool.yml: extensions[0]: unknown key 'entitlement' will be ignored. Did you mean 'entitlementsPath'?",
    ])
}
