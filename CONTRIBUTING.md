# Contributing

## Before submitting

- Keep changes focused and explain user-visible behavior and compatibility limitations.
- Do not add the original MilkDrop source archive, user-picked preset collections, preset images, or generated build products without file-by-file provenance and redistribution review.
- Do not add or imply a project-wide license. Preserve third-party notices and include applicable notices for any added material.
- Never include credentials, local signing identities, personal logs, screenshots, or machine-specific artifacts.

## Build and checks

On macOS with Swift 6.2 or newer:

```sh
swift build -c release
.build/release/MilkDropCoreCheck
```

Run `swift test` in an Xcode environment with XCTest available. If changing rendering, audio capture, or app startup, describe the hardware/runtime verification performed and the limitations of any non-hardware test.
