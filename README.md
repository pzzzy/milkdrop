# MilkDrop for macOS

A standalone native macOS reimplementation using Swift, AppKit, and Metal. This source-only staging contains the app/core and test source plus the reviewed notices and build script. It does **not** include the original MilkDrop source archive, third-party preset collection, preset artwork, or generated application/build artifacts.

## Features

- AppKit and Metal with extended-range `rgba16Float` feedback rendering
- Extended-linear Display P3 output; EDR-ready when the selected display exposes EDR headroom
- Core Audio system-output capture for audio-reactive visuals
- Local FFT audio analysis with bass, mid, treble, spectrum, and waveform data
- Portable NS-EEL init/per-frame interpreter
- Native Metal custom-shape and custom-wave passes
- Fullscreen controls: Space next, B previous, R random, F fullscreen, Escape exit/quit

## Build and run

Requires macOS 15 or later and Swift 6.2 (Xcode or compatible Swift toolchain).

Build the app/core and deterministic core validation executable:

```sh
swift build -c release
.build/release/MilkDropCoreCheck
```

Package and launch the app without presets:

```sh
./scripts/build-app.sh
open dist/MilkDrop.app
```

With no preset files installed, the app starts with its built-in fallback visualization. To use your own preset files, set `MILKDROP_PRESETS` to a directory of `.milk` files before launching, or place a personally licensed preset collection in `MilkDrop.app/Contents/Resources/Presets`. Presets and associated images are not part of this staging. Ensure you have the rights to use and redistribute any assets you add.

The first launch may request System Audio Recording permission. The packaging script signs ad hoc by default; set `MILKDROP_SIGNING_IDENTITY` to a signing identity available on your machine if you need a different local signing mode. No developer-specific identity is embedded in this project.

## Verification

`MilkDropCoreCheck` exercises core parser, EEL, FFT, and waveform behavior. XCTest fixture sources are under `Tests/`; run `swift test` in an Xcode environment with XCTest available. A successful release build and CoreCheck do not validate live audio capture or graphics performance.

## Compatibility scope

The parser retains classic state, numbered programs, custom waves/shapes, and embedded warp/composite shader blocks. Portable NS-EEL init/per-frame execution and native custom-shape/custom-wave rendering are implemented. Advanced per-pixel programs and arbitrary original HLSL still require further native translation; compatibility is not pixel-identical to DirectX MilkDrop 2.

## Third-party content and licensing

See `THIRD_PARTY_NOTICES.txt` for the notices included in this staging. Those notices do not establish a license for this reimplementation as a whole, nor do they clear every source file or asset for redistribution. The project-owned application/core source in this staging is licensed under MIT; see `LICENSE`. That grant applies only to project-authored code and does not relicense third-party material. Review provenance and rights for each added file and asset before distributing or publishing this project.
