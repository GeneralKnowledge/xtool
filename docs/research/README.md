# Research notes

Planning documents for the GeneralKnowledge fork of xtool. They are not upstream
documentation and nothing here has been sent to xtool-org.

| Document | Date | Status |
|---|---|---|
| [External project opportunities](external-project-opportunities.md) | 2026-11-07 | Research complete; no implementation yet |

## Summary of the external project research (2026-11-07)

- **Biggest gap:** on iOS 17 and later, xtool cannot do anything after installing the app.
  `xtool launch` is broken ([#44](https://github.com/xtool-org/xtool/issues/44)), and there
  are no logs, crash reports, screenshots, process lists or debugger. Developer services moved
  behind a RemoteXPC tunnel that libimobiledevice does not implement.
- **Best source to reuse:** [idevice](https://github.com/jkcoxson/idevice) (Rust, MIT). It
  implements the no-root iOS 17.4+ tunnel over usbmuxd and every developer service xtool
  needs, with a C FFI. The xtool maintainer recommended wrapping it
  ([#236](https://github.com/xtool-org/xtool/pull/236)), and `swift-rcodesign` already shows
  how xtool-org ships a Rust crate to Swift users as a prebuilt artifact bundle.
- **Recommended first milestone:** a `swift-idevice` package with a narrow C ABI, and an
  `xtool dev run` that installs, launches the app and streams its logs until Ctrl-C. Then an
  adb-style `xtool device` toolkit and `xtool doctor`, a faster inner loop (plan cache,
  profile reuse, no re-zip), and lldb debugging.
- **Leave alone:** simulator on Linux (not feasible), our own actool (AssetKit PRs exist),
  Xcode project builds and hot reload (maintainer work in progress), replacing rcodesign or
  Swift Build, Python or Go helpers.
- **Security fix worth doing anyway:** Linux credential files are written with default
  permissions; create them 0600.

See the full report for evidence, the capability matrix, licensing notes, linked upstream
issues and PRs, and an implementation brief for the first milestone.
