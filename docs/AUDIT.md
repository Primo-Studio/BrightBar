# BrightBar Audit

## Findings

- The LG display was shown as unsupported because BrightBar only searched the
  older `IODisplayConnect` / `IOFramebuffer` path. On this Apple Silicon Mac,
  the LG appears under `AppleCLCD2` and `DCPAVServiceProxy`.
- `AppleSiliconDDC` can detect `LG ULTRAWIDE`, but DDC brightness read and write
  fail on the current connection. This can be caused by the display input,
  cable, adapter, dock, or monitor DDC/CI settings.
- Sub-zero dimming previously created and destroyed overlay windows during
  slider tracking. Crash reports pointed to AppKit window animation/deallocation
  while dragging a slider. The overlay is now reused and hidden instead.
- Native brightness key handling can be either intercepted or only observed.
  Observed mode means macOS may also process the key, so BrightBar surfaces that
  distinction in the footer.
- The global slider could look inconsistent because nested mutations inside the
  `@Published` display array did not always force SwiftUI to refresh each child
  slider/nits label. Display updates now publish a replaced array.
- Nits shown for software-only displays are upper-bound estimates. Without DDC,
  BrightBar cannot know or raise the monitor's real hardware brightness.
- The per-display slider used local SwiftUI state. That could leave labels such
  as `Sub-zero actif` visible after global changes. Sliders now bind directly to
  the manager state.
- The packaged app was not signed after writing `Info.plist`, so macOS reported
  the identifier as `BrightBar` instead of `studio.primo.BrightBar`.
- Sparkle requires `Sparkle.framework` embedded in `Contents/Frameworks` and an
  `@executable_path/../Frameworks` rpath. A first package attempt crashed at
  launch until the rpath was moved into linker settings.
- GitHub reports `Primo-Studio/BrightBar` as private. Manual downloads work for
  authenticated users, but Sparkle automatic updates require the appcast and ZIP
  URLs to be public or otherwise reachable without login.

## UX Personas

- MacBook + one external monitor: expects F1/F2 to feel native and control all
  displays together.
- Night user: expects quick access to very low brightness without losing the
  cursor or making the screen fully black.
- Accuracy user: expects nits to be useful, but must know they are estimates
  unless the display exposes calibrated luminance data.
- Troubleshooting user: needs to know whether BrightBar is using hardware DDC or
  software dimming.

## Implemented

- Apple Silicon DDC probing via `AppleSiliconDDC`.
- Software fallback mode instead of `Non pris en charge`.
- Stable overlay window lifecycle for sub-zero dimming.
- Clear keyboard status: active, observed, or fallback shortcut only.
- Accessibility permission prompt for F1/F2 interception.
- Re-published display state after every brightness and max-nits change.
- Per-display nits are calculated from the live slider value, with `<=` for
  software-only displays.
- Global warning when at least one display is limited to software dimming.
- Dedicated brightness math helpers with unit tests for clamp, sub-zero, dimming
  opacity, and nit estimates.
- Ad-hoc bundle signing during packaging.
- Developer ID release packaging script for GitHub-downloadable builds.
- Sparkle updater integration with a signed GitHub Release appcast, a manual
  check button, and a 24-hour scheduled check interval.
- Project run script for repeatable build and launch.

## Verification

- `swift test`: 6 tests, 0 failures.
- `swift build`: passed.
- `./Scripts/package_app.sh`: passed.
- `codesign --verify --deep --strict dist/BrightBar.app`: passed.
- `Scripts/package_release.sh`: signs a ZIP with
  `Developer ID Application: Primo Studio (4QB44XVHNL)`.
- `Scripts/generate_appcast.sh`: generates signed `appcast.xml` from the
  notarized release ZIP.
- GitHub Release `v0.1.1` contains the signed ZIP and appcast assets, but the
  repository is private, so unauthenticated Sparkle downloads are blocked until
  the release/feed location is public.
- `./script/build_and_run.sh --verify`: passed.
- Idle process sample after Sparkle integration: 0.0% CPU, about 78 MB RSS.
- Earlier Sparkle packaging attempts produced dyld crash reports before the rpath
  fix; no new BrightBar crash report appeared after the verified launch.
- `system_profiler` sees both the built-in display and `LG ULTRAWIDE`.
- `AppleSiliconDDC detect` sees `LG ULTRAWIDE` on `DP -> DP`.
- `AppleSiliconDDC getvcp 0x10` still fails on the LG, so BrightBar correctly
  stays in software mode for that monitor on the current connection.

## Next Improvements

- Add a diagnostic panel showing DDC read/write test results per display.
- Add a "hardware max test" button that attempts a temporary DDC write with
  explicit user confirmation.
- Add optional native macOS OSD feedback for F1/F2 changes.
- Add per-display sync modes: all displays, built-in only, external only.
- Persist whether a display should prefer DDC or software fallback.
- Add a GitHub Actions release workflow after notary and Sparkle signing
  credentials are stored as encrypted repository secrets.
