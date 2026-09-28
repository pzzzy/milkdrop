# Security policy

## Scope

This is a local macOS visualization application. The source-only staging does not bundle presets, images, or other user assets.

## Reporting a vulnerability

Do not report sensitive security issues in a public issue or pull request. Contact the project maintainer privately through a verified channel listed by the repository owner. No private reporting endpoint is configured in this staging; until one is published, avoid sending sensitive details through public channels.

## Security notes

- The app requests system-audio capture to visualize output audio; it does not require microphone access for that function.
- Treat third-party presets and shader/equation content as untrusted input. Review before use.
- Do not commit credentials, signing certificates, private keys, personal logs, or generated artifacts.
- The packaging script uses ad-hoc signing unless the operator explicitly supplies `MILKDROP_SIGNING_IDENTITY`.
