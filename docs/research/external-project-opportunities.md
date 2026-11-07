# xtool: external project research, capability audit and roadmap

Date: 2026-11-07. Baseline: fork branch `ixos` at `2ac0ba9`, which is upstream
`xtool-org/xtool` `main` at `4ec0e96` plus eight patches (four of ours and upstream
PRs [#392], [#394], [#369], [#358]).

This is a research and planning document. Nothing in it has been implemented.

**How to read the evidence labels**

- **[Verified]** means I read the source (file and line cited, or a commit), or ran a command.
- **[Maintainer]** means a statement by the xtool maintainer in an issue or PR, quoted.
- **[Hypothesis]** means I believe it from documentation or reasoning but did not run it.
  Each one says how to check it.
- **[Recommendation]** means my engineering judgement.

No iPhone and no Xcode.xip were available in this environment, so nothing here was run
against a device. Every device claim is from source code or project documentation.

---

## 1. Executive summary

xtool already does the hard part of "iOS development without a Mac": it builds an iOS app
from a SwiftPM package on Linux with the real Xcode SDK, provisions it against Apple's
developer services with a free or paid account, signs it with apple-codesign, and installs
it over usbmuxd. That pipeline works today (ixOS apps run on a real iPhone built from Linux).

What it does not do is anything **after** the install. On any iPhone running iOS 17 or later
(that is, every current device) xtool cannot launch the app, cannot show its logs, cannot
fetch its crash reports, cannot take a screenshot and cannot attach a debugger.
[Verified: `LaunchCommand.swift` uses the lockdown `DebugserverClient`, which iOS 17+ no
longer exposes; `DDIMounter.swift` is wrapped in `#if false`; there is no log, crash or
screenshot code.] [Maintainer, #44: "xtool launch is currently broken on iOS 17+ since
libimobiledevice doesn't support the new RemoteXPC debugging mechanism ... it's a high
effort task."]

That gap is the difference between "a build tool" and "a development environment". The
edit, run, look-at-logs loop is where developers spend their day, and it is entirely
missing. Compiling faster or handling more project shapes matters less than being able to
see what your app did.

The problem is already solved in open source, natively, without root and on Linux:

- [**idevice**](https://github.com/jkcoxson/idevice) (Rust, MIT) implements the iOS 17.4+
  CoreDeviceProxy tunnel over plain usbmuxd with an in-process TCP stack (no root, no TUN
  device), Remote Service Discovery, personalized Developer Disk Image mounting, CoreDevice
  app launch/kill/process list, debugserver proxy, os_trace and syslog relay, crash reports,
  screenshots, DVT instruments and XCTest. It ships a C FFI. It is in production in
  StikDebug, CrossCode and Protokolle. [Verified: source and `ffi/src` exports.]
- The xtool maintainer has already said this is the library to use. [Maintainer, #236: "I
  don't think we should have the RSD code in the xtool layer ... I'd highly recommend
  wrapping idevice for this."]
- xtool already has the exact packaging pattern needed: `swift-rcodesign` (and `xadi`) wrap
  a Rust crate behind a small hand-written C ABI and ship it as a SwiftPM static-library
  artifact bundle for macOS, iOS and glibc Linux, so consumers need no Rust toolchain.
  [Verified: `xtool-org/swift-rcodesign` README and `Package.swift`.]

**Main recommendation.** Build a `swift-idevice` package in the same shape as
`swift-rcodesign`, and use it to give xtool a complete run loop:
`xtool dev run` builds, installs, **launches** the app and **streams its logs** until you
press Ctrl-C. Then grow it into an adb-style `xtool device` toolkit (processes, crash
reports, screenshots, Developer Disk Image status) and an `lldb` debug path. This is the
first milestone in §10 and §11.

Everything else in this report is secondary to that, and most of it is already being worked
on upstream (asset catalogs, Xcode project builds, hot reload, Swift Build fixes). Our job
there is to test and review, not to write parallel implementations.

---

## 2. Current xtool capability assessment

### 2.1 Architecture [Verified]

`Package.swift` defines these targets:

| Target | Role |
|---|---|
| `xtool` | `@main` entry point; wires persistence dependencies. |
| `XToolSupport` | All CLI commands (swift-argument-parser), SDK builder, LSP/BSP config. |
| `PackLib` | `Planner` (reads the SwiftPM graph), `Packer` (generates a builder package, runs `swift build`, assembles the `.app`), `XcodePacker` (generates an `.xcodeproj`), `BuildSettings`, `DarwinSDK`, `SwiftVersion`. |
| `XKit` | Apple account auth (GrandSlam SRP, 2FA, Anisette), Developer Services client (OpenAPI-generated App Store Connect API), provisioning, signing (`RCodesignSigner`), device connection and install (`Connection`, `AppInstaller`, `IPAUploader`, `IPAInstaller`). Also builds for iOS. |
| `XcodeProjects` | pbxproj/xcworkspace model on top of tuist/XcodeProj and apple/xcode-project-format. |
| `XUtils`, `XCLIUtils` | Subprocess helpers, temp directories, console I/O, shutdown registry. |
| `DeveloperAPI` | 29k lines of generated OpenAPI client. |
| `CXKit` | Small C helpers (mobileprovision parsing via OpenSSL, version string). |

External xtool-org dependencies:

- **xtool-core**: on Linux, uses the *system* `libplist`, `libusbmuxd`, `libimobiledevice-glue`
  and `libimobiledevice` through pkg-config `systemLibrary` targets; on Apple platforms,
  prebuilt xcframeworks from `xtool-libs`. [Verified: `xtool-core/Package.swift`.] The
  AppImage bundles libimobiledevice built from `master` and libplist 2.6.0
  [Verified: `Dockerfile`], so the shipped binary is not at the mercy of distro versions, but
  a source build (`swift build`) on Ubuntu is.
- **SwiftyMobileDevice**: about 3,000 lines of Swift wrapping a subset of libimobiledevice:
  usbmux, lockdown, AFC, AMFI, heartbeat, house_arrest, misagent, mobile_image_mounter,
  debugserver, sbservices, installation_proxy. [Verified.]
- **swift-rcodesign**: Swift bindings to apple-codesign 0.29.0 (`sign`, `read_entitlements`).
  Replaced zsign in [#389] (merged 2026-10-30). [Verified.]

### 2.2 Commands and what they really do [Verified]

| Command | Implementation | State |
|---|---|---|
| `setup`, `sdk build/install/update/remove/status` | `SDKBuilder` unxips Xcode.xip with libunxip, prunes it, downloads `darwin-tools-linux-llvm` (ld64.lld, llvm tools) and OpenAppleMacros, writes `swift-sdk.json`, `toolset.json`, `toolset-swb.json`. | Works. `status` has no machine-readable output or SDK paths. |
| `auth login/logout/status` | GrandSlam SRP + 2FA + Anisette (xadi/omnisette), or an App Store Connect API key. | Works; under heavy upstream churn ([#415]-[#417], [#424]). |
| `new` | Template SwiftPM project with `xtool.yml`. | Works. |
| `dev build` | `PackOperation`: check Swift version, ensure SDK, plan, write builder package, `swift build`, pack `.app`, ad-hoc sign entitlements; `--sign`, `--ipa`, `--triple`, `--jobs`, `-c`. | Works. |
| `dev run` (default) | Same, then `IntegratedInstaller.install`: register device, fetch cert, **delete and re-create the profile**, sign, zip IPA, AFC upload, installation_proxy install. | Installs. **Does not launch.** |
| `dev generate-xcode-project` | `XcodePacker` writes an `.xcodeproj` wrapping the package (for use on a Mac). | Works. |
| `dev build-server` | Runs `swift package experimental-build-server` with the iOS SDK options (Swift 6.4+). `LSPConfig` writes `.bsp/xtool.json` on every build. | Works; this is what SourceKit-LSP uses. |
| `devices` | usbmuxd device list with a wait loop. | Works. Hangs when usbmuxd is down (our patch `devices-wait-hint` adds a hint). |
| `install`, `uninstall` | `IntegratedInstaller` / installation_proxy. | Work. `uninstall` exits 0 on failure ([#354], PR [#355]). |
| `launch` | installation_proxy lookup + lockdown `DebugserverClient` `A`/`qLaunchSuccess`/`D`. | **Broken on iOS 17+** ([#44]). |
| `ds teams/devices/identifiers/profiles/certificates`, `anisette` | Developer Services listing. | Works. |

There is no command for logs, crash reports, screenshots, processes, Developer Disk Image,
Developer Mode, device info, debugging, or tests.

### 2.3 Build pipeline [Verified, partly measured in the earlier findings doc]

1. `Planner` runs `swift package show-dependencies` and then `swift package describe` for
   every package, in parallel (2.1s warm, 8.2s cold for a 52-package graph; measured
   earlier). It walks the chosen library product's targets to collect resource bundles,
   binary targets and dynamic libraries. `describe` drops platform and trait conditions
   ([#154], [#433]). There is a `TODO: cache plan` (`Planner.swift:76`).
2. `Packer.build` writes a generated builder package in `xtool/.xtool-tmp` with one
   `.executableTarget` per product (app and extensions), each depending on the user's
   library and adding linker flags (rpath, compiler-rt on Linux, `-platform_version`,
   strip in release, `_NSExtensionMain` for appex). Our patch makes this write-if-changed,
   which stops a forced relink on every run.
3. `swift build --build-system swiftbuild --triple arm64-apple-ios --toolset toolset-swb.json`
   on Swift 6.4+ (the legacy `native` system with `--swift-sdk` otherwise).
4. `Packer.pack` copies the binary, resource bundles, frameworks, dylibs and root resources
   into a fresh temp `.app`, writes `Info.plist`, then moves it to `xtool/<App>.app`.
5. **Resources:** SwiftPM resource bundles are copied as built. Root `resources:` are copied
   verbatim. There is **no asset catalog compilation** (no `actool`), no storyboard/xib
   compilation, no `.xcstrings` compilation, and no Info.plist `DT*` build keys.
   ([#123] closed wontfix for a proprietary-tool reason; [#219]/[#325] now propose AssetKit.)

### 2.4 Signing and provisioning [Verified]

- `AutoSigner` → `DeveloperServicesProvisioningOperation` → per-bundle App ID,
  capabilities, app groups, certificate, and `DeveloperServicesFetchProfileOperation`, which
  lists all certificates and devices, **deletes the existing "XTL profile" and creates a new
  one on every run** (`DeveloperServicesFetchProfileOperation.swift:79-125`).
- `RCodesignSigner` signs the whole bundle recursively with per-bundle entitlements.
- Nothing verifies the signed bundle against its embedded profile before upload. When iOS
  rejects an install (`0xe8008015`, `0xe800801c`, entitlement mismatch) the user sees the
  device's raw error.
- On Linux, tokens and keys are stored by `DirectoryStorage`
  (`KeyValueStorage.swift:86-115`) with `Data.write(to:)`, i.e. default umask permissions
  (usually 0644), in the persistent directory. There is a `TODO` about libsecret in
  `Sources/xtool/XTool.swift:11`. [Hypothesis: on a default Ubuntu umask these files are
  world-readable. Check with `ls -l ~/.local/share/xtool/data` or wherever
  `persistentDirectory` resolves.]

### 2.5 Device layer [Verified]

- Discovery: `ClientDevice.search` subscribes to usbmuxd events; USB and network devices.
- Pairing: relies on usbmuxd pair records; `IntegratedInstaller.performWithRecovery` loops
  on "pairing dialog pending" and "passcode protected".
- Install: AFC upload of a full IPA to `/PublicStaging/XTool-App`, then installation_proxy.
- `HeartbeatHandler` only runs on iOS (`#if os(iOS)`).
- `Debugger.swift` (vAttachWait over lockdown debugserver) is unused.
- `DDIMounter.swift` is disabled with `#if false` and a Linux `fatalError`.

### 2.6 Tests [Verified]

80 Swift Testing / XCTest cases in `Tests/XToolTests`: concurrency utilities, console I/O,
Swift version parsing, `xtool.yml` schema, Packer helpers, Darwin SDK paths, certificate
parsing, one Xcode project test. One bats smoke test in `integration-tests/`. There are
**no tests** for `Planner` against real package shapes, for provisioning, for signing
output, or for any device interaction. Upstream has a self-hosted Mac runner repo
(`xtool-org/mac-actions-runner`), but no device-in-the-loop CI.

### 2.7 Linux versus macOS [Verified]

| Area | Linux | macOS |
|---|---|---|
| Toolchain | swift.org toolchain + xtool's Darwin SDK built from Xcode.xip; ld64.lld | Xcode toolchain |
| Build system | swiftbuild with `toolset-swb.json` (Swift 6.4+) | swiftbuild / native, implicit Darwin SDK |
| Simulator | Build only | `dev run --simulator` via `xcrun simctl` |
| Device libs | system or AppImage-bundled libimobiledevice | prebuilt xcframeworks |
| Credentials | plain files | Keychain |

### 2.8 Known limitations and TODOs [Verified]

`Planner.swift:76` plan cache; `DevCommand.swift:59` run from a subdirectory;
`IntegratedInstaller.swift:235` reuse `Connection`; `SDKBuilder.swift:103` parallelise SDK
install; `xtool/XTool.swift:11` Linux credential store; `DDIMounter` disabled.

---

## 3. External project catalogue

Maintenance dates are the last push reported by GitHub search on 2026-11-07. "Linux" means
the project itself runs on Linux.

| Project | What it is | Licence | Last push | Linux | Fit for xtool | Category |
|---|---|---|---|---|---|---|
| [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | Rust iOS device protocol library, C FFI, CLI tools | MIT | 2026-10-27 | Yes | **High.** Maintainer-recommended. | Direct reuse (wrap) |
| [doronz88/pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | Most complete Python device toolkit | **GPL-3.0** | 2026-11-05 | Yes | Reference and test oracle only. | Learn from |
| [danielpaulus/go-ios](https://github.com/danielpaulus/go-ios) | Go device toolkit, userspace tunnel | MIT | 2026-11-05 | Yes | Second reference; Go is hard to embed. | Learn from |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) | C device library xtool already links | LGPL-2.1 | 2026-06-10 | Yes | Already used. Has unused services (os_trace, syslog, screenshotr, diagnostics, crash via AFC). No RemoteXPC/RSD. | Already a dependency |
| [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd), [libplist](https://github.com/libimobiledevice/libplist), [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue), [libtatsu](https://github.com/libimobiledevice/libtatsu) | Support libs; libtatsu does TSS for personalized DDI | LGPL-2.1 | 2025-09 to 2026-11 | Yes | Already built into the AppImage. | Already a dependency |
| [usbmuxd](https://github.com/libimobiledevice/usbmuxd) | System daemon | GPL-2.0 | 2025-12-06 | Yes | Runtime prerequisite, separate process. | Prerequisite |
| [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) | Install CLI | GPL-2.0 | 2025-10-30 | Yes | xtool's installer already mirrors it. | Learn from |
| [jkcoxson/netmuxd](https://github.com/jkcoxson/netmuxd), [tihmstar/usbmuxd2](https://github.com/tihmstar/usbmuxd2), [rusbmux](https://github.com/abdubanna/rusbmux) | usbmuxd replacements with Wi-Fi support | LGPL-2.1 / LGPL-3.0 / Apache-2.0 | 2026-08 / 2025-06 / 2026-10 | Yes | Document as optional for Wi-Fi ([#134]). | Document |
| [xtool-org/swift-rcodesign](https://github.com/xtool-org/swift-rcodesign) | Swift bindings to apple-codesign | no SPDX in metadata | 2026-10-23 | Yes | In use. Missing verify/inspect APIs. | Extend upstream |
| [indygreg/apple-platform-rs](https://github.com/indygreg/apple-platform-rs) (apple-codesign) | Rust signing, verification, notarization | MPL-2.0 [Hypothesis: from crate metadata, GitHub API returned none] | 2026-10-17 | Yes | Already underneath rcodesign. | Already a dependency |
| [zhlynn/zsign](https://github.com/zhlynn/zsign) / [xtool-org/zsign](https://github.com/xtool-org/zsign) | C++ signer | MIT | 2026-10 | Yes | Replaced by rcodesign; no reason to return. | Avoid |
| [ProcursusTeam/ldid](https://github.com/ProcursusTeam/ldid) | Mach-O signer | **AGPL-3.0** | 2026-07-24 | Yes | Licence incompatible with embedding. | Avoid |
| [swiftlang/swift-build](https://github.com/swiftlang/swift-build) + [xtool-org fork](https://github.com/xtool-org/swift-build) | Build engine used by `--build-system swiftbuild` | Apache-2.0 | 2026-11 | Yes | In use via the toolchain. Fork carries 5 patches. | Upstream fixes |
| [swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager) (+ xtool-org fork) | Package manager | Apache-2.0 | 2026-11-06 | Yes | In use. | Upstream fixes |
| [swiftlang/swift-driver](https://github.com/swiftlang/swift-driver), [swift-llbuild](https://github.com/swiftlang/swift-llbuild) (+ forks) | Compiler driver, low-level build engine | Apache-2.0 | 2026-11 | Yes | Indirect; no xtool-specific gap found. | Leave |
| [swiftlang/sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp), [vscode-swift](https://github.com/swiftlang/vscode-swift) | Language server, VS Code extension | Apache-2.0 | 2026-11 | Yes | xtool already provides a BSP server. Needs docs/templates. | Integrate (docs) |
| [tuist/XcodeProj](https://github.com/tuist/XcodeProj) | pbxproj read/write | MIT | 2026-11-06 | Yes | Already a dependency (`XcodeProjects`). | Already a dependency |
| [tuist/tuist](https://github.com/tuist/tuist) | Project generation, caching, selective testing | NOASSERTION (mixed; server parts are not OSS) | 2026-11-07 | CLI is macOS-centric | Ideas only (manifest validation, cache keys). | Learn from |
| [xtool-org/AssetKit](https://github.com/xtool-org/AssetKit) | Clean-room `actool` replacement (CoreUI 970) | MIT | 2026-05-25 | Yes | Being integrated by [#325]. | Test/review upstream |
| [xtool-org/xload](https://github.com/xtool-org/xload), [InjectionLite fork](https://github.com/xtool-org/InjectionLite) | Hot reload runtime | MIT | 2026-11-03 | Yes | Maintainer WIP (`hot-reload-command` branch). | Leave to maintainer |
| [xtool-org/darwin-tools-linux-llvm](https://github.com/xtool-org/darwin-tools-linux-llvm), [OpenAppleMacros](https://github.com/xtool-org/OpenAppleMacros), [xadi](https://github.com/xtool-org/xadi) | Toolset, macro plugins, Anisette | MIT / MIT / LGPL-2.1 | 2026-09 to 2026-10 | Yes | Already in use. | Already dependencies |
| [p-x9/MachOKit](https://github.com/p-x9/MachOKit) | Pure Swift Mach-O parser | MIT | 2026-11-05 | Yes | Useful for a `doctor`/verify step (load commands, platform version, linked dylibs). | Optional reuse |
| [blacktop/ipsw](https://github.com/blacktop/ipsw), [go-macho](https://github.com/blacktop/go-macho) | Mach-O, dyld cache, symbolication research | MIT | 2026-11 | Yes | Reference for crash symbolication. | Learn from |
| [google/ios-webkit-debug-proxy](https://github.com/google/ios-webkit-debug-proxy) | WebInspector to Chrome DevTools | BSD-3-Clause | 2025-07-02 | Yes | Only relevant for WebView apps. | Out of scope |
| [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent) | UI automation server | BSD-like | 2026-10-29 | Device-side | idevice has a `wda` feature. Later. | Later |
| [kolabs-dev/isim](https://github.com/kolabs-dev/isim) | "iOS-compatible simulator" for Linux | Apache-2.0 | 2026-11-06 (single squashed commit, 36 stars) | Yes | Reimplements frameworks rather than running Apple's runtime. Not a fidelity target. | Avoid |
| [darlinghq/darling](https://github.com/darlinghq/darling) | Darwin compatibility layer | GPL-3.0 | 2026-11-06 | Yes | Cannot run CoreSimulator in practice. | Avoid |
| [SideStore/SideStore](https://github.com/SideStore/SideStore), [StikDebug](https://github.com/StephenDev0/StikDebug), [CrossCode](https://github.com/nab138/CrossCode) | On-device sideloading/JIT; cross-platform IDE using idevice | AGPL-3.0 / various | 2026-10 | n/a | Evidence that idevice works in production. | Evidence only |
| [swiftlang/swift-sdk-generator](https://github.com/swiftlang/swift-sdk-generator) | Generates Linux/static SDKs | Apache-2.0 | 2026-11-03 | Yes | Does not do Darwin targets; xtool's `SDKBuilder` is already better for this. | Leave |

---

## 4. Detailed analysis of the most promising projects

### 4.1 idevice (the key finding)

**What it covers** [Verified from `idevice/src/services` and `ffi/src`]: usbmuxd client,
lockdown and pairing files, `core_device_proxy` (iOS 17.4+ lockdown service that carries a
tunnel), `tunnel_tcp_stack` (in-process TCP over that tunnel via `jktcp`, so **no root and no
TUN interface**), RSD handshake, XPC over HTTP/2, CoreDevice `app_service`
(`list_apps`, `launch_application`, `list_processes`, `send_signal`, `uninstall_app`),
`debug_proxy` (GDB remote protocol over the tunnel), `mobile_image_mounter` including
`mount_personalized` with TSS (Developer Disk Image on iOS 17+), `os_trace_relay`,
`syslog_relay`, `crashreportcopymobile`, `screenshotr` and DVT `screenshot`, DVT
`process_control`, `device_info`, `sysmontap`, `location_simulation`, `notifications`,
`installation_proxy`, `afc`, `house_arrest`, `misagent`, `amfi`, `heartbeat`, `xctest`,
`wda`. The FFI exports about 200 functions for these.

**Why it beats the alternatives for xtool**

- It is the only one of the three modern stacks designed to be embedded (the README says
  so; pymobiledevice3 needs Python, go-ios needs a Go runtime).
- MIT licence: we may adapt code with attribution. pymobiledevice3 is GPL-3.0, so its code
  must not be copied into MIT xtool.
- The maintainer named it ([#44], [#236]).
- xtool-org already ships two Rust crates to Swift users this way (`swift-rcodesign`,
  `xadi`), so the build, release and AppImage story is solved.

**Risks** [Verified unless marked]

- Pre-0.2: "Breaking changes will happen at each point release until 0.2.0" (README). Pin an
  exact version and keep our own C ABI so churn stays inside one crate.
- **Symbol clash:** `idevice-ffi` exports a libplist-compatible C API through `plist_ffi`
  (`ffi/plist.h`), while xtool also links the real libplist through libimobiledevice.
  Linking both statically into one binary will collide on `plist_*` symbols.
  [Hypothesis: confirm by linking a test binary against both.] Mitigation: do **not** ship
  `idevice-ffi`; write a narrow shim crate (the swift-rcodesign approach) that exposes only
  the calls xtool needs, passes plists as XML/binary byte buffers, and exports
  `xtidevice_*`-prefixed symbols only.
- Single primary maintainer (jkcoxson), hobby project. Mitigated by MIT licence (we can
  vendor or fork) and by its use in large deployed apps.
- Two device stacks in one binary (libimobiledevice for install, idevice for developer
  services) during the transition. Acceptable short term; see §10 M2 for convergence.
- Rust crypto backend choice: pick `ring` (or `aws-lc`) rather than `openssl` to avoid
  coupling to the system OpenSSL that xtool-core already links.

### 4.2 pymobiledevice3

The most complete and best-documented toolkit, and the best **reference and test oracle**.
Its docs state the facts xtool's design depends on:

- From iOS 17.0, developer services sit behind an encrypted tunnel listed by RSD and
  spoken in RemoteXPC; on iOS 17.4+ the lockdown `CoreDeviceProxy` service makes that
  tunnel available over usbmuxd with no extra pairing. [Verified:
  `misc/understanding_idevice_protocol_layers.md`, `docs/guides/ios17-tunnels.md`.]
- A no-root userspace tunnel works on Linux for iOS 17.4+; iOS 17.0–17.3 needs root
  (`tunneld`) on Linux. [Verified: support table in `ios17-tunnels.md`.]
- An in-process tunnel cannot be reached by an external `lldb`; the fix is a local TCP port
  forwarder (`debugserver start-server --local-port`). [Verified: same guide.] xtool's debug
  design must include such a forwarder.

It also covers features worth copying the *design* of: `syslog live` filtering by process,
crash report pull-and-clear, `developer dvt` process list/kill/launch, a `doctor` command,
and machine-readable output (`docs/guides/machine-readable-output.md`). GPL-3.0 means we
read it and test against it, and do not port its code.

[Recommendation] Use pymobiledevice3 during development as an oracle: when `xtool` and
`pymobiledevice3` disagree on a device, `pymobiledevice3` is probably right.

### 4.3 go-ios

MIT, actively maintained, implements the same surface as idevice (tunnel with a userspace
port, RSD, appservice, debugproxy, ostrace, crash reports, DTX instruments, testmanagerd,
imagemounter). [Verified: directory listing of `ios/`.] Not embeddable in Swift without a Go
runtime, so it is a second reference implementation, useful when idevice and pymobiledevice3
behave differently.

### 4.4 libimobiledevice (already linked)

Master has `ostrace`, `syslog_relay`, `screenshotr`, `diagnostics_relay`, `notification_proxy`,
`webinspector`, and `ideviceimagemounter` already mounts **personalized** DDIs via libtatsu.
[Verified.] SwiftyMobileDevice wraps none of these. It has **no** RemoteXPC, RSD or
CoreDeviceProxy code [Verified: no matches in `src/`], and on iOS 17+ the developer services
(debugserver, screenshotr, DVT) are only reachable through that tunnel.

So libimobiledevice could give xtool `logs` (os_trace and syslog are ordinary lockdown
services) and crash reports (AFC on `com.apple.crashreportcopymobile`) cheaply, but not
launch, debugging, process lists or screenshots on iOS 17+. [Recommendation] Do not invest in
wrapping more of libimobiledevice; put the effort into one stack (idevice) that covers both
the lockdown and the tunnel services.

### 4.5 Signing: swift-rcodesign / apple-codesign / zsign

- xtool moved from zsign to rcodesign in [#389] because "It's much more usable as a library."
  [Maintainer] One regression is open: release builds of xtool crash the compiler on Linux
  ([#431], fix in [#432], approved).
- apple-codesign handles nested bundles, per-bundle entitlements, Mach-O universal binaries
  and code-signature generation correctly; swift-rcodesign exposes only `sign` and
  `read_entitlements`. [Verified: `include/rcodesign.h`.]
- **Gap:** no verification or inspection API. apple-codesign has signature verification and
  signature info printing upstream. [Hypothesis: exposing them through swift-rcodesign is a
  small Rust + C ABI change.] That would let xtool check, before uploading, that every
  Mach-O is signed, entitlements match the embedded profile, the profile contains the
  device UDID and has not expired, and that the bundle ID matches. That turns iOS's opaque
  `0xe8008015` into a precise error.
- [Recommendation] Keep rcodesign. zsign has no concrete advantage now; ldid is AGPL.

### 4.6 Swift Build / SwiftPM / driver / llbuild and the xtool-org forks

- xtool drives Swift Build only through `swift build --build-system swiftbuild` with a toolset
  file; it does not link Swift Build as a library. [Verified: `BuildSettings.swift`.]
- `xtool-org/swift-build` `release/6.4.x` carries five commits by the maintainer that are not
  in upstream `main` under the same subject: "Support MachO parsing outside Darwin", "Fix
  linker task ordering", "Fix xcframework invalidation", "Add more comprehensive task
  interception", "Fix generatePreviewInfo writing stray .dia file". [Verified: `git log
  up/main..origin/release/6.4.x`.] Upstream `main` has a different xcframework invalidation
  fix (#1694). The SwiftPM, swift-driver and llbuild forks exist too.
- [Hypothesis] These forks support the maintainer's hot-reload and previews work
  (branches `hot-reload-command`, `hotreload`, `swb-sdks`) and are used to build a custom
  toolchain, since xtool's own manifest does not reference them. Ask before touching.
- Build incrementality is SwiftPM/Swift Build's job and already works; the waste is in
  xtool's wrapper (plan every run, profile every run, re-zip and re-upload every run).
  [Verified in the earlier findings doc.]
- [Recommendation] Do not fork or replace the build system. Fix xtool's wrapper (plan cache,
  profile reuse, incremental install) and report any Swift Build Linux bugs upstream with a
  reduced test case.

### 4.7 Editor support: SourceKit-LSP, Tuist, XcodeProj

- xtool already writes `.bsp/xtool.json` and serves `xtool dev build-server`, so SourceKit-LSP
  gets iOS-SDK-aware completion and diagnostics on Linux with Swift 6.4+. [Verified:
  `LSPConfig.swift`, `DevBSPCommand.swift`.] The missing pieces are documentation, editor
  templates (VS Code `tasks.json`/`launch.json`), and a debug configuration once debugging
  exists.
- Tuist's useful ideas (strict manifest validation, content-hash cache keys, selective
  testing) are design input only; its CLI and project model are Xcode-project-centric.
- XcodeProj is already a dependency. Building `.xcodeproj` projects ([#144]) is planned by
  the maintainer on top of Swift Build. [Maintainer: "This is now planned: SwiftBuild makes
  this feasible, though xtool still needs to implement converting the xcodeproj
  representation."]

### 4.8 Simulator

- Simulator runtimes are macOS binaries that need CoreSimulator, launchd_sim and dyld_sim on a
  Darwin kernel. There is no credible path to run Apple's simulator on Linux or Windows
  without a macOS VM. [Hypothesis, consistent with the maintainer on #177: "you can't run
  these tests outside of macOS, because running them requires the iOS simulator which xtool
  doesn't provide."]
- `isim` reimplements UIKit/SwiftUI-like frameworks on Linux. That can show *something*, but
  behaviour will differ from iOS, so it cannot validate an app. `macbox` runs a macOS VM in
  Docker, which has licensing problems on non-Apple hardware.
- [Recommendation] Do not pursue. Building for the simulator triple already works. Put the
  effort into making the physical device loop fast, which is what a Linux developer actually
  has.

---

## 5. Missing capability matrix

Legend: ✅ works, ⚠️ partial, ❌ missing. "Path" is the recommended source.

| Capability | xtool today | iOS ≤16 | iOS 17.0–17.3 | iOS 17.4+ | Path |
|---|---|---|---|---|---|
| List devices | ✅ | ✅ | ✅ | ✅ | existing |
| Device info (model, iOS, Developer Mode, DDI) | ❌ | | | | idevice lockdown + image mounter + AMFI |
| Install / uninstall | ✅ / ⚠️ exit code | ✅ | ✅ | ✅ | existing; [#355] |
| Launch app | ⚠️ | ✅ (lockdown debugserver) | ❌ | ❌ | idevice CoreDevice `app_service` |
| Terminate app, list processes | ❌ | | | | idevice `app_service` / DVT |
| Stream logs | ❌ | | | | idevice `os_trace_relay` (lockdown; no tunnel needed) |
| Crash reports | ❌ | | | | idevice `crashreportcopymobile` (lockdown) |
| Screenshot | ❌ | | | | idevice `screenshotr` (≤16) / DVT screenshot (17+) |
| Mount Developer Disk Image | ❌ (`#if false`) | | | | idevice `mount_personalized` + TSS |
| Developer Mode status/reveal | ❌ (AMFI client exists, unused) | | | | SwiftyMobileDevice `AMFIClient` or idevice |
| Debug with lldb | ❌ | | | | idevice `debug_proxy` + local TCP forwarder |
| On-device XCTest | ❌ ([#177], PR [#236]) | | | | idevice `xctest` (later) |
| Wi-Fi deploy | ⚠️ depends on usbmuxd | | | | netmuxd/usbmuxd2 docs; PR [#318] |
| Plan cache | ❌ | | | | xtool PackLib |
| Profile reuse | ❌ | | | | xtool XKit |
| Incremental install | ❌ | | | | xtool XKit [Hypothesis: installation_proxy "Developer" package type with an uploaded `.app` directory avoids zipping] |
| Pre-install signature/profile verification | ❌ | | | | swift-rcodesign verify + xtool |
| Asset catalogs | ❌ | | | | AssetKit via [#325] |
| Info.plist DT* keys | ❌ | | | | [#323] / [#398] |
| Xcode project builds | ❌ | | | | maintainer plan ([#144]) |
| Editor support | ⚠️ BSP present, undocumented | | | | docs + templates |
| Secure credential storage on Linux | ❌ plain files | | | | file modes now, libsecret later |
| Simulator on Linux | ❌ | | | | not pursued |

iOS 17.0–17.3 on Linux would need a root TUN tunnel. [Recommendation] Do not support it;
print "update iOS to 17.4 or later" instead.

---

## 6. Potential integrations and adaptations

| # | Opportunity | Existing implementation | External project | Proposed approach | Difficulty | Impact | Linux | Dependencies | Risks | Upstream potential | Kind |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | Developer services on iOS 17+ (launch, kill, ps, DDI) | Broken `launch`, disabled DDI | [idevice] | New `swift-idevice` (Rust shim + C ABI + SwiftPM artifact bundle, rcodesign pattern); XKit `DeviceServices` layer | High | **Transformative** | Native, no root (17.4+) | New: Rust crate (prebuilt), idevice pinned | API churn, plist symbol clash, two stacks | High: maintainer asked for it ([#236]) | Direct reuse (wrap) |
| B | `dev run` launches and streams logs | Installs only | [idevice] `os_trace_relay`, `app_service` | Build on A; filter log by launched PID; Ctrl-C terminates app | Medium (after A) | **Transformative** | Native | A | Log volume, process-name filtering | High | Develop new capability |
| C | Crash reports | none | [idevice] `crashreportcopymobile`; [blacktop/ipsw] for symbolication ideas | `xtool device crashes [--pull]`; later symbolicate with the build's dSYM | Medium | High | Native | A | Symbolication needs dSYM and `atos`-like tool | Medium | Reuse + new |
| D | lldb debugging | unused `Debugger.swift` | [idevice] `debug_proxy`; pymobiledevice3 forwarder design | `xtool debug`: launch suspended, forward debugproxy to `127.0.0.1:PORT`, run `lldb` with `process connect` | High | High | Partial [Hypothesis: swift.org Linux lldb has the remote-ios platform plugin; verify] | A, lldb | Linux lldb + Darwin dSYM untested | Medium | Adapt |
| E | Plan cache + `dump-package` planner | Planner re-runs every build | SwiftPM | Key on hashes of `Package.swift`, `Package.resolved`, `xtool.yml`, Swift version, triple | Medium | Medium | Native | none | Cache invalidation bugs | High ([#154]) | New |
| F | Profile reuse | delete+create every run | — | Cache profile by (bundle ID, cert serial, device set, entitlements hash, expiry) | Medium | Medium | Native | none | Signing code churn ([#430]) | High after discussion | New |
| G | Incremental install | full copy, zip, AFC upload | ideviceinstaller, pymobiledevice3 | Upload `.app` directly with `PackageType: Developer`; skip unchanged files later | Medium-High | Medium-High for big apps | Native | none | Needs device measurement | Medium | Adapt |
| H | Pre-install verification | none | apple-codesign verify | Extend swift-rcodesign with verify/inspect; `xtool doctor app` | Medium | Medium | Native | rcodesign | ABI growth | High (xtool-org repo) | Extend dependency |
| I | `xtool doctor` (host + device) | none | pymobiledevice3 `doctor` design | Check Swift/SDK/usbmuxd/pairing/Developer Mode/DDI/iOS ≥17.4/auth; `--json` | Low-Medium | High for support load | Native | A for device checks | New CLI surface | Ask first | New |
| J | Asset catalogs | none | [AssetKit] | Review and test [#325] on ixOS apps; report gaps | Low (for us) | High for real apps | Native | AssetKit | App Store processing issue noted in #325 | Already upstream | Test/review |
| K | Editor experience | BSP server exists | SourceKit-LSP, vscode-swift | Docs; `xtool new` writes `.vscode/` tasks and (after D) launch config | Low | Medium | Native | none | Editor churn | High (docs) | Integrate |
| L | Credential file permissions | 0644 files | — | Create files 0600 and dir 0700 now; libsecret optional later | Low | Medium (security) | Native | none | None | High | New |
| M | On-device XCTest | none | [idevice] `xctest` | `xtool test` after A is stable; coordinate with [#236] author | High | High | Native | A | XCTest bundle packaging | Medium | Reuse |
| N | Wi-Fi development | depends on usbmuxd | netmuxd, usbmuxd2 | Document; review [#318] | Low | Low-Medium | Native | external daemon | Flaky networking | Medium | Document |

---

## 7. Technical risks and licensing considerations

**Licences**

- xtool is MIT. We can adapt code from MIT (idevice, go-ios, MachOKit) and Apache-2.0
  (swiftlang) projects with attribution.
- **Do not copy code from pymobiledevice3 (GPL-3.0), ldid (AGPL-3.0), Darling (GPL-3.0),
  SideStore (AGPL-3.0).** Reading them to understand a protocol is fine; port behaviour from
  the MIT implementations instead.
- libimobiledevice and friends are LGPL-2.1 and already linked; the AppImage ships them as
  shared libraries, which keeps LGPL relinking obligations simple. If `swift-idevice` is
  statically linked, it must not pull in LGPL code statically. idevice's `plist_ffi`
  contains a copy of libplist's LGPL header (`ffi/plist.h` says so), another reason to
  avoid shipping `idevice-ffi` as is.
- apple-codesign is MPL-2.0 (file-level copyleft); already accepted by xtool via rcodesign.
- Apple's Xcode.xip licence: xtool already makes users download Xcode themselves; nothing
  here changes that. Never redistribute SDK or DDI files. The personalized DDI comes from the
  user's own Xcode or Apple's signing service (TSS) per device.

**Technical risks**

- iOS updates can change CoreDevice services. Mitigation: depend on a library whose
  maintainer tracks iOS releases (idevice is at 0.1.68 with frequent releases), pin it, and test on the newest iOS before bumping.
- TSS/DDI: personalized mounting contacts Apple's TSS server with device identifiers. This is
  what Xcode does; say so in docs and never log ECID/nonces at info level.
- Two device stacks: keep them behind one XKit protocol so we can retire SwiftyMobileDevice
  paths one at a time.
- Rust in the build: precedent exists (rcodesign, xadi) and consumers get prebuilt artifact
  bundles (Swift 6.2+ on Linux). The Dockerfile/AppImage build needs no change because the
  artifact bundle is downloaded by SwiftPM. [Hypothesis: confirm static artifact bundles link
  into the AppImage build exactly as rcodesign's do.]

**Security**

- Credentials on Linux are plain files with default permissions (§2.4). Fix before adding
  more stored state (cached profiles, pairing records for tunnels).
- `xtool debug` must bind its forwarder to `127.0.0.1` only.
- Never print or store pairing records, TSS responses, signing keys or app-specific passwords
  in logs or `--json` output.

---

## 8. Existing upstream issues and PRs relevant to the plan

Read on 2026-11-07. All links are to `xtool-org/xtool`. Maintainer quotes from the issue
pages.

**Device and run loop**

- [#44] `xtool launch` broken on iOS 17+. Open. Maintainer: high effort; options "move to
  pymobiledevice3 or idevice, or rewrite"; "I'm going to leave this issue open to track this."
- [#106] View app logs. Maintainer: "This is planned, but for now your best bet is to use a
  tool like pymobiledevice3."
- [#236] PR: on-device XCTest/XCUITest via `xtool test`. Maintainer: "I don't think we should
  have the RSD code in the xtool layer ... I'd highly recommend wrapping idevice."
- [#177] Running unit tests: needs a simulator (not available) or a "pretty large effort"
  device path.
- [#19], [#119], [#164], [#185] WSL/usbmuxd connection hangs; [#134] Wi-Fi deploy;
  [#318] draft PR keeping wireless sessions alive.
- [#354] / [#355] uninstall exit code.

**Build and packaging**

- [#154], [#433] conditional dependencies break the Planner.
- [#290], [#408] builder package resolution (overlap with our `pack-keep-builder-package`).
- [#291], [#292], [#293], [#295] dynamic library embedding (joshuaswarren).
- [#313], [#379], [#320], [#393] app extension binaries dead-stripped / `main` removed.
- [#323], [#398] `DT*` Info.plist keys; [#395] extension Info.plist keys; [#397] App Intents
  metadata.
- [#358], [#369], [#392], [#394] already folded into our `ixos` branch.
- [#123] actool: closed wontfix ("actool is proprietary"); superseded by [#219] (maintainer
  "open to merging" but worried about "2.5K LoC for an undocumented file format") and
  [#325] (draft, AssetKit, "App Store Connect never finishes processing an upload whose
  `Assets.car` comes from AssetKit"). [#310] actool wrapper failure on WSL.
- [#144] Xcode project builds: planned by the maintainer via Swift Build.
- [#124], [#386] Swift version check (our `swift-version-check` patch).
- [#431] / [#432] release-build compiler crash after the rcodesign switch.

**Signing and provisioning**

- [#352] entitlements outside supported types silently not provisioned; [#324] reconcile
  entitlements with profile; [#206] reuse a p12; [#312] do not re-register devices;
  [#120] P12 support; [#326] distribution signing; [#327] App Store upload.

**Auth** (very active; leave to the maintainer unless asked): [#308], [#407], [#414], [#424],
[#399].

**Simulator and platforms:** [#311] simulator on Linux (no maintainer reply; we judge
infeasible); [#93], [#362], [#370], [#350], [#429] other Apple platforms (out of scope).

**Maintainer work in progress (do not duplicate)** [Verified from upstream branch names and
commits]: `hot-reload-command` / `hotreload` (hot reload with xload/InjectionLite), `swb-sdks`,
Swift Build fork patches (§4.6), `xcodeproj-direct` (merged as [#300]).

---

## 9. Prioritised improvement opportunities

Ranked by practical impact per unit of effort, favouring reuse and upstream fit.

1. **Run loop on iOS 17+: launch + logs** (A + B). Turns xtool from "builds and installs"
   into a development loop. Reuses idevice. Maintainer-endorsed direction. *Transformative.*
2. **`xtool device` toolkit and `xtool doctor`** (A + C + I + screenshots). adb-like
   inspection, and fewer "it hangs" reports. *High.*
3. **Fast inner loop** (E + F + G). Plan cache, profile reuse, incremental install. Removes
   network round trips and full re-zips from every run. *Medium-high*, needs device timing.
4. **Debugging with lldb** (D). The last big piece of the Xcode experience; depends on 1.
   *High*, with real uncertainty about Linux lldb.
5. **Pre-install verification and credential hygiene** (H + L). Precise errors instead of
   device error codes; fixes a real security weakness. *Medium*, low effort.
6. **Real-app compatibility by reviewing upstream work** (J, DT keys, extension fixes,
   dynamic library PRs). Use ixOS apps as test cases. *High* for users, low effort for us
   because others wrote the code.
7. **Editor templates and docs** (K). *Medium*, low effort.
8. **On-device XCTest** (M). *High*, but only after 1 and 4 are stable.

Deliberately not on the list: simulator, our own actool, replacing rcodesign, replacing the
build system, our own Xcode project builder, hot reload, App Store upload, other Apple
platforms, Python helpers.

---

## 10. Proposed implementation roadmap

Milestones are sized so each ends in something a developer can use. "Repos" names where code
changes; per Reuben's instruction, everything lives in GeneralKnowledge forks until he decides
to contact upstream.

### M1. Run loop: launch and logs on iOS 17.4+ (recommended first; detailed in §11)

- **What:** `swift-idevice` package; XKit `DeviceServices`; fixed `xtool launch`;
  `xtool dev run` launches the app and streams its logs; `xtool logs`.
- **Why:** the single biggest missing capability; every later device feature reuses it.
- **Uses:** idevice (core_device_proxy, tunnel_tcp_stack, rsd, app_service,
  mobile_image_mounter, os_trace_relay), existing usbmuxd pairing, existing `ConnectionOptions`.
- **Repos:** new `GeneralKnowledge/swift-idevice`; `GeneralKnowledge/xtool`.
- **Verify:** on Reuben's iPhone (iOS 26) from Linux: `xtool launch com.apple.Preferences`
  opens Settings; `xtool dev run` in an ixOS example shows its `print`/`Logger` output and
  Ctrl-C stops the app. Unit tests for log filtering and DDI decision logic with fakes.
- **End result:** the same experience as Xcode's Run button plus console, from Linux.

### M2. Device toolkit and doctor

- **What:** `xtool device info|apps|ps|kill|crashes|screenshot|ddi`, `xtool doctor [--json]`
  covering host (Swift, SDK version, usbmuxd socket, credentials) and device (paired, trusted,
  Developer Mode, iOS ≥17.4, DDI mounted). Move `launch`/`uninstall` onto `DeviceServices`
  and start retiring direct SwiftyMobileDevice use in commands.
- **Uses:** swift-idevice (`crashreportcopymobile`, DVT `screenshot`, `device_info`,
  `amfi`), our `devices-wait-hint` and `swift-version-check` patches.
- **Repos:** swift-idevice (more ABI), xtool.
- **Verify:** each command against the device; compare outputs with
  `pymobiledevice3 apps list`, `crash ls`, `developer dvt screenshot`. `--json` snapshot tests.
- **MVP:** `crashes` lists and pulls `.ips` files (no symbolication); `screenshot` writes a PNG;
  `doctor` prints pass/fail per check with a fix hint.

### M3. Fast inner loop

- **What:** plan cache (and Planner on `dump-package` if [#154] is agreed); provisioning
  profile reuse; install without zipping (upload the `.app` directory) and, later, delta
  upload; timing output (`--timings`) so every change is measured.
- **Uses:** PackLib, XKit provisioning, installation_proxy.
- **Repos:** xtool.
- **Verify:** `xtool dev run --timings` on ixOS Chat before/after: no-op run, one-line Swift
  change, resource-only change. Target: no network calls on a no-op run with a valid profile,
  and no zip step.
- **MVP:** plan cache + profile reuse only (both need no device protocol work).

### M4. Debugging

- **What:** `xtool debug [--attach PID|--wait-for NAME]`: mount DDI, launch suspended via
  app_service, open `debug_proxy`, forward to `127.0.0.1:<port>`, then exec `lldb` with
  `platform select remote-ios` / `process connect connect://127.0.0.1:<port>` and the build's
  dSYM. Emit a VS Code `launch.json` (lldb-dap) template.
- **Uses:** swift-idevice `debug_proxy`, swift.org lldb, the SDK's `dsymutil`.
- **Spike first (1–2 days):** confirm the Linux lldb from the Swift toolchain can debug an
  arm64 iOS process over gdb-remote and load symbols from a dSYM produced on Linux.
  If it cannot, MVP is "print the forwarder port and the commands to use from any lldb".
- **Verify:** breakpoint in an ixOS example's `ContentView` body, `po` a Swift value.

### M5. Real-app compatibility (review, test, contribute)

- **What:** build the ixOS apps (Counter, Weather, Chat, Pocket Library) against the open PRs
  for asset catalogs ([#325]), DT keys ([#323]/[#398]), extensions ([#393]/[#320]), dynamic
  libraries ([#291]–[#295]); write down what breaks; add regression fixtures under
  `Tests/` and `Examples/`. Track [#144] Xcode project support instead of building our own.
- **Repos:** xtool fork (`ixos` branch for local use), AssetKit if we find bugs.
- **Verify:** each app builds, installs and passes a manual smoke test on device.

### M6. Editor experience

- **What:** a Linux editor guide (VS Code + vscode-swift, Neovim) using the existing BSP;
  `xtool new` optionally writes `.vscode/tasks.json` (build, run) and, after M4, `launch.json`.
- **Verify:** fresh Ubuntu VM, `xtool new Hello`, open in VS Code, completion for `UIKit`
  symbols, errors shown inline, run task installs and launches.

### M7. On-device tests (later)

- **What:** `xtool test` builds an XCTest bundle into a test host app and runs it via
  idevice `xctest`; JUnit output.
- **Prerequisites:** M1, M4. Coordinate with the author of [#236] rather than starting fresh.

### Security fix that can ride along any milestone

- Create credential files 0600 and the data directory 0700 in `DirectoryStorage`; add a test.

---

## 11. Recommended first milestone (implementation brief)

**Goal:** on Linux, with an iPhone on iOS 17.4 or later over USB, `xtool dev run` builds,
installs, launches the app and streams its log output until Ctrl-C, which terminates the app.
`xtool launch <bundle-id>` works. `xtool logs [--process NAME|--pid N]` streams logs.

### 11.1 Package `swift-idevice` (new repository)

Copy the structure of `xtool-org/swift-rcodesign`:

```
swift-idevice/
  Cargo.toml            # crate "xtidevice", depends on idevice = "=0.1.68" (pin exactly),
                        # features: usbmuxd, core_device_proxy, tunnel_tcp_stack, rsd, xpc,
                        # core_device (app_service), mobile_image_mounter, tss,
                        # os_trace_relay, lockdown, ring (crypto backend)
  rust-toolchain.toml
  src/lib.rs            # narrow C ABI, xtidevice_* symbols only, panics caught at the boundary
  include/xtidevice.h, include/module.modulemap
  Sources/IDevice/*.swift   # Swift wrapper: async APIs, owned errors
  Package.swift         # binaryTarget artifact bundle, same linker settings as rcodesign
  scripts/build.sh, scripts/release.sh   # copied from swift-rcodesign
  Tests/
```

C ABI for M1 (keep it this small):

```c
// Opaque handles
typedef struct xtid_session xtid_session;   // usbmuxd + lockdown + CoreDeviceProxy tunnel + RSD
typedef struct xtid_log_stream xtid_log_stream;

// Connect to a device by UDID through usbmuxd (honours USBMUXD_SOCKET_ADDRESS).
int32_t xtid_session_open(const char *udid, const char *label, xtid_session **out, char **err);
void    xtid_session_close(xtid_session *);

// Device facts for doctor/launch decisions: ProductVersion, DeveloperModeStatus, DDI mounted.
int32_t xtid_device_info_plist(xtid_session *, uint8_t **xml, size_t *len, char **err);

// Ensure a personalized DDI is mounted. ddi_dir = Xcode's DeveloperDiskImages/iOS_DDI
// (from xtool's Darwin SDK). Returns 0 if already mounted or mounted now.
int32_t xtid_ddi_ensure_mounted(xtid_session *, const char *ddi_dir, char **err);

// CoreDevice app service.
int32_t xtid_app_launch(xtid_session *, const char *bundle_id, const char *const *argv,
                        size_t argc, const char *const *env /* KEY=VALUE */, size_t envc,
                        uint8_t terminate_existing, uint8_t start_suspended,
                        int64_t *out_pid, char **err);
int32_t xtid_app_signal(xtid_session *, int64_t pid, int32_t signal, char **err);

// os_trace_relay over lockdown (no tunnel needed). pid < 0 = all processes.
int32_t xtid_log_open(xtid_session *, int64_t pid, xtid_log_stream **out, char **err);
// Blocks until next entry; returns entry as JSON {ts, pid, process, subsystem, category, level, message}.
int32_t xtid_log_next(xtid_log_stream *, char **json, char **err);
void    xtid_log_close(xtid_log_stream *);

void xtid_free_string(char *);
void xtid_free_bytes(uint8_t *, size_t);
```

Notes:
- Run one tokio runtime inside the shim (as `idevice-ffi` does) and expose blocking calls;
  the Swift side wraps them with `Task { @concurrent in ... }` per xtool's conventions
  (`AGENTS.md` forbids `Task.detached`).
- Plists cross the boundary as XML bytes so we never export `plist_*` symbols.
- [Hypothesis to check first] where Xcode 26/27 keeps the personalized DDI
  (`Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/DeveloperDiskImages/`
  or `.../Xcode/.../iOS_DDI`), and whether `SDKBuilder`'s slim mode prunes it. If it does,
  add it to the kept paths in `SDKBuilder` and bump `sdkEpoch`.

### 11.2 xtool changes

- `Package.swift`: add `.package(url: ".../swift-idevice", exact: "0.1.0")`; XKit depends on
  product `IDevice`.
- `Sources/XKit/DeviceServices/` (new): `protocol DeviceServices` with
  `launch(bundleID:arguments:environment:) -> PID`, `terminate(pid:)`,
  `logs(pid:) -> AsyncThrowingStream<LogEntry>`, `ensureDeveloperDiskImage()`, `info()`;
  live implementation over swift-idevice; register as a swift-dependencies key so commands use
  `@Dependency(\.deviceServices)` (repo convention).
- Version gate: if `ProductVersion` < 17.0, keep the existing lockdown `DebugserverClient`
  launch; 17.0–17.3 throw a clear error ("iOS 17.0–17.3 needs a root tunnel; update iOS");
  ≥17.4 use the tunnel.
- `LaunchCommand`: use `DeviceServices`; add `--wait-logs`.
- `DevRunCommand`: after install, unless `--no-launch`, launch with `terminate_existing`,
  then stream logs for that PID (and its process name, so relaunches are followed), stop and
  `SIGTERM` the app on Ctrl-C via `ShutdownRegistry`. `--no-logs` to skip streaming.
- `LogsCommand` (new, in the Device group): `xtool logs [--process NAME] [--pid N] [--level]
  [--json]`.
- Errors: Developer Mode off → "Enable Settings > Privacy & Security > Developer Mode";
  DDI missing from SDK → "re-run `xtool sdk update`"; TSS failure → network hint.

### 11.3 Tests

- swift-idevice: Rust unit tests for the ABI (null handling, error strings); Swift tests for
  wrappers with a mock handle.
- xtool: tests for the version gate, log filtering by PID and process name, Ctrl-C
  shutdown ordering, with a fake `DeviceServices`.
- Manual device checklist in `docs/research/m1-device-checklist.md` (to write with the
  implementation): iOS 26 device over USB, Developer Mode on/off, DDI mounted/unmounted,
  locked/unlocked device, app already running, app crashes on launch.

### 11.4 Definition of done

From a clean Linux machine with xtool installed from the fork, an iPhone on iOS 26 over USB:

1. `xtool launch com.apple.Preferences` opens Settings.
2. In `ixOS/examples/counter`, `xtool dev run` ends with the app in the foreground and its log
   lines in the terminal within 2 seconds of launch; Ctrl-C closes the app.
3. With Developer Mode off, step 2 fails with the Developer Mode message, not a raw error.
4. First run mounts the DDI automatically; second run reports it as already mounted.
5. `swift test` passes; `make lint` passes.

### 11.5 Effort estimate [Recommendation]

swift-idevice shim + packaging: 4–6 days (the rcodesign scripts do most of the release
work). XKit/commands: 3–4 days. Device testing and fixes: 2–3 days. About three weeks of
focused work, most of the risk in the first device session.

---

## 12. Final answers

**1. What is the biggest opportunity to make xtool substantially better?**
Close the loop after install. On iOS 17+ xtool cannot launch, log, debug or inspect, and
that is where developers spend their time. Fixing launch and logs makes `xtool dev run` feel
like Xcode's Run button; nothing else on the list changes daily use as much.

**2. Which existing project offers the most valuable functionality to learn from or adapt?**
idevice. It already implements the no-root iOS 17.4+ tunnel and every developer service xtool
needs, under MIT, with a C FFI, and the xtool maintainer has asked for it to be wrapped.
pymobiledevice3 is the best reference and test oracle, but it is GPL-3.0 and Python.

**3. What are we missing that would make Linux iOS development feel much closer to Xcode?**
In order: launch with a live console; crash reports; a debugger; a one-command health check
that explains why a device is not working; asset catalogs; and a fast no-op run (no
provisioning round trip, no re-zip). Editor support already exists through the BSP server and
mostly needs documentation.

**4. What could we realistically implement in the next few milestones?**
M1 (launch + logs) in about three weeks, M2 (device toolkit + doctor) in about two more, and
the profile-reuse and plan-cache half of M3 in parallel because it needs no device protocol
work. M4 (lldb) is realistic only after a short spike proves Linux lldb can debug an iOS
process.

**5. What should we deliberately avoid building?**
A Linux iOS simulator; our own actool (AssetKit exists); our own Xcode project builder
(maintainer is on it); a replacement for rcodesign or Swift Build; a Python or Go helper
process; root TUN tunnels for iOS 17.0–17.3; hot reload (maintainer WIP); App Store upload
and other Apple platforms (open PRs exist; not our goal). Also avoid wrapping more of
libimobiledevice: it is the stack that cannot reach iOS 17+ developer services.

**6. If I were responsible for xtool, what would I build first, and why?**
`swift-idevice` and, on top of it, `xtool dev run` that launches the app and streams its logs.
It removes the most-reported gap ([#44], [#106]), it follows the maintainer's stated design,
it reuses a mature MIT implementation instead of re-deriving Apple's protocols, it uses a
packaging pattern xtool-org already ships, and every later device feature (crashes,
screenshots, debugging, tests) is a few more functions on the same session.

[#44]: https://github.com/xtool-org/xtool/issues/44
[#106]: https://github.com/xtool-org/xtool/issues/106
[#119]: https://github.com/xtool-org/xtool/issues/119
[#120]: https://github.com/xtool-org/xtool/issues/120
[#123]: https://github.com/xtool-org/xtool/issues/123
[#124]: https://github.com/xtool-org/xtool/issues/124
[#134]: https://github.com/xtool-org/xtool/issues/134
[#144]: https://github.com/xtool-org/xtool/issues/144
[#154]: https://github.com/xtool-org/xtool/issues/154
[#164]: https://github.com/xtool-org/xtool/issues/164
[#177]: https://github.com/xtool-org/xtool/issues/177
[#185]: https://github.com/xtool-org/xtool/issues/185
[#19]: https://github.com/xtool-org/xtool/issues/19
[#206]: https://github.com/xtool-org/xtool/pull/206
[#219]: https://github.com/xtool-org/xtool/pull/219
[#236]: https://github.com/xtool-org/xtool/pull/236
[#290]: https://github.com/xtool-org/xtool/pull/290
[#291]: https://github.com/xtool-org/xtool/pull/291
[#292]: https://github.com/xtool-org/xtool/pull/292
[#293]: https://github.com/xtool-org/xtool/pull/293
[#295]: https://github.com/xtool-org/xtool/pull/295
[#300]: https://github.com/xtool-org/xtool/pull/300
[#308]: https://github.com/xtool-org/xtool/issues/308
[#310]: https://github.com/xtool-org/xtool/issues/310
[#311]: https://github.com/xtool-org/xtool/issues/311
[#312]: https://github.com/xtool-org/xtool/pull/312
[#313]: https://github.com/xtool-org/xtool/issues/313
[#318]: https://github.com/xtool-org/xtool/pull/318
[#320]: https://github.com/xtool-org/xtool/pull/320
[#323]: https://github.com/xtool-org/xtool/pull/323
[#324]: https://github.com/xtool-org/xtool/pull/324
[#325]: https://github.com/xtool-org/xtool/pull/325
[#326]: https://github.com/xtool-org/xtool/pull/326
[#327]: https://github.com/xtool-org/xtool/pull/327
[#350]: https://github.com/xtool-org/xtool/pull/350
[#352]: https://github.com/xtool-org/xtool/issues/352
[#354]: https://github.com/xtool-org/xtool/issues/354
[#355]: https://github.com/xtool-org/xtool/pull/355
[#358]: https://github.com/xtool-org/xtool/pull/358
[#362]: https://github.com/xtool-org/xtool/pull/362
[#369]: https://github.com/xtool-org/xtool/pull/369
[#370]: https://github.com/xtool-org/xtool/pull/370
[#379]: https://github.com/xtool-org/xtool/issues/379
[#386]: https://github.com/xtool-org/xtool/issues/386
[#389]: https://github.com/xtool-org/xtool/pull/389
[#392]: https://github.com/xtool-org/xtool/pull/392
[#393]: https://github.com/xtool-org/xtool/pull/393
[#394]: https://github.com/xtool-org/xtool/pull/394
[#395]: https://github.com/xtool-org/xtool/pull/395
[#397]: https://github.com/xtool-org/xtool/pull/397
[#398]: https://github.com/xtool-org/xtool/pull/398
[#399]: https://github.com/xtool-org/xtool/pull/399
[#407]: https://github.com/xtool-org/xtool/issues/407
[#408]: https://github.com/xtool-org/xtool/pull/408
[#414]: https://github.com/xtool-org/xtool/issues/414
[#415]: https://github.com/xtool-org/xtool/pull/415
[#417]: https://github.com/xtool-org/xtool/pull/417
[#424]: https://github.com/xtool-org/xtool/issues/424
[#429]: https://github.com/xtool-org/xtool/pull/429
[#430]: https://github.com/xtool-org/xtool/pull/430
[#431]: https://github.com/xtool-org/xtool/issues/431
[#432]: https://github.com/xtool-org/xtool/pull/432
[#433]: https://github.com/xtool-org/xtool/issues/433
[#93]: https://github.com/xtool-org/xtool/issues/93
[idevice]: https://github.com/jkcoxson/idevice
[AssetKit]: https://github.com/xtool-org/AssetKit
[blacktop/ipsw]: https://github.com/blacktop/ipsw
