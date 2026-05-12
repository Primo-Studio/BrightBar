# BrightBar

BrightBar is a lightweight macOS menu bar app for display brightness control.
It focuses on the useful part of Lunar: fast hardware brightness control without
subscriptions, profiles, scheduling, or extra automation.

## Features

- Menu bar only, no Dock icon.
- Global brightness slider for all controllable displays.
- Per-display sliders.
- External display control through DDC/CI.
- Built-in display control through macOS DisplayServices.
- Sub-zero dimming below 20% using a per-display software overlay.
- Presets: 5%, 20%, 50%, 100%.
- Native brightness keys support, plus `Option + Up` and `Option + Down`.
- Saved brightness per physical display.
- Estimated nits per display, based on a configurable max-nits value.

## Build

```sh
swift build
```

## Run

```sh
swift run BrightBar
```

## Create the app bundle

```sh
./Scripts/package_app.sh
```

The bundle is written to `dist/BrightBar.app`.

## Notes

Most external monitors need DDC/CI enabled in the monitor's on-screen menu.
Some USB-C docks block DDC/CI commands; direct USB-C/DisplayPort connections are
usually more reliable.

Nit values are estimates. macOS and DDC/CI expose brightness levels, not a
calibrated luminance reading, so set each display's max-nits value to match its
spec sheet for a more useful estimate.

Native brightness key interception may require enabling BrightBar in macOS
Privacy & Security settings for Accessibility or Input Monitoring.
If the footer shows "Soleil observe", BrightBar can see the key press but cannot
consume the system event; macOS may still change the built-in display in
parallel. Granting the permission lets BrightBar show "Soleil actif" and handle
the key coherently.
