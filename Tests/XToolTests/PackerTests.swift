import Testing
import Foundation
@testable import PackLib

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

@Test func writeIfChangedKeepsUnchangedFiles() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("xtool-write-if-changed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Package.swift")

    try Packer.writeIfChanged(Data("a".utf8), to: file)
    let past = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

    try Packer.writeIfChanged(Data("a".utf8), to: file)
    let unchanged = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    #expect(unchanged == past)

    try Packer.writeIfChanged(Data("b".utf8), to: file)
    #expect(try Data(contentsOf: file) == Data("b".utf8))
    let changed = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    #expect(changed != past)
}

@Test func compilerRTLibraryNameFollowsBuildTriple() {
    #expect(Packer.compilerRTLibraryName(for: "arm64-apple-ios") == "libclang_rt.ios.a")
    #expect(Packer.compilerRTLibraryName(for: "arm64-apple-ios17.0-simulator") == "libclang_rt.iossim.a")
    #expect(Packer.compilerRTLibraryName(for: "arm64-apple-macosx") == "libclang_rt.osx.a")
}
