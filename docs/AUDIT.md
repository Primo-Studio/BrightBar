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
- Project run script for repeatable build and launch.

## Next Improvements

- Add a diagnostic panel showing DDC read/write test results per display.
- Add a "hardware max test" button that attempts a temporary DDC write with
  explicit user confirmation.
- Add optional native macOS OSD feedback for F1/F2 changes.
- Add per-display sync modes: all displays, built-in only, external only.
- Persist whether a display should prefer DDC or software fallback.
