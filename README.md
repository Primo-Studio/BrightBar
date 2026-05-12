# BrightBar

BrightBar is a lightweight macOS menu bar app for display brightness control.
It focuses on the useful part of Lunar: fast hardware brightness control without
subscriptions, profiles, scheduling, or extra automation.

## Features

- Menu bar only, no Dock icon.
- Global brightness slider for all controllable displays.
- Per-display sliders.
- External display control through DDC/CI.
- Apple Silicon DDC probing through `AppleSiliconDDC`, with software fallback
  when a display or adapter refuses DDC commands.
- Built-in display control through macOS DisplayServices.
- Sub-zero dimming below 20% using a per-display software overlay.
- Presets: 5%, 20%, 50%, 100%.
- Native brightness keys support, plus `Option + Up` and `Option + Down`.
- Saved brightness per physical display.
- Estimated nits per display, based on a configurable max-nits value.
- Signed automatic updates through Sparkle and GitHub Releases.

## Build

```sh
swift build
```

## Test

```sh
swift test
```

## Run

```sh
./script/build_and_run.sh
```

## Create the app bundle

```sh
./Scripts/package_app.sh
```

The bundle is written to `dist/BrightBar.app`.
The packaging script signs it ad-hoc with the stable bundle identifier
`studio.primo.BrightBar`, which keeps macOS permissions tied to the app bundle
instead of the raw executable name.

## Create a distributable ZIP

```sh
./Scripts/package_release.sh
```

This creates `dist/BrightBar-0.1.1-macOS.zip` signed with:

```text
Developer ID Application: Primo Studio (4QB44XVHNL)
```

For Gatekeeper-friendly distribution outside this Mac, notarize the ZIP:

```sh
xcrun notarytool store-credentials BrightBar-Notary --team-id 4QB44XVHNL --apple-id <apple-id>
NOTARY_PROFILE=BrightBar-Notary ./Scripts/package_release.sh --notarize
```

Generate the Sparkle appcast after the notarized ZIP is created:

```sh
./Scripts/generate_appcast.sh
```

After notarization, upload the ZIP to a GitHub Release. The GitHub CLI is enough:

```sh
gh release create v0.1.1 dist/BrightBar-0.1.1-macOS.zip --title "BrightBar 0.1.1" --notes "Signed, notarized, Sparkle-enabled macOS build."
```

The app checks the `appcast.xml` asset from the latest GitHub Release at most
once per day by default, and the footer button can manually trigger "Check for
Updates".

## Notes

Most external monitors need DDC/CI enabled in the monitor's on-screen menu.
Some USB-C docks block DDC/CI commands; direct USB-C/DisplayPort connections are
usually more reliable.
When BrightBar shows `Logiciel`, the display was detected but DDC write/read did
not work. In that mode BrightBar can dim visually with an overlay, but it cannot
raise the monitor's hardware brightness above the level currently set in the
monitor OSD.

Nit values are estimates. macOS and DDC/CI expose brightness levels, not a
calibrated luminance reading, so set each display's max-nits value to match its
spec sheet for a more useful estimate.

Native brightness key interception may require enabling BrightBar in macOS
Privacy & Security settings for Accessibility or Input Monitoring.
If the footer shows "Soleil observe", BrightBar can see the key press but cannot
consume the system event; macOS may still change the built-in display in
parallel. Granting the permission lets BrightBar show "Soleil actif" and handle
the key coherently.
