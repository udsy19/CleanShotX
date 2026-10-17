# Contributing to Super Screenshot

Thanks for helping make Super Screenshot better! Bug reports, feature ideas, docs and code are all welcome.

## Getting started

```sh
git clone https://github.com/udsy19/super-screenshot.git && cd super-screenshot
./scripts/signing-setup.sh      # once: local signing identity so macOS permissions survive rebuilds
./scripts/build-app.sh --debug  # → build/SuperScreenshot.app
open build/SuperScreenshot.app
```

You only need macOS 14+ and the Swift toolchain from the Command Line Tools (`xcode-select --install`).
Xcode is optional.

## Before you open a pull request

1. `swift build` compiles with **no warnings**.
2. `swift run SuperScreenshotSelfTest` passes — add cases for new logic in `Sources/SuperScreenshotSelfTest/<Module>Tests.swift`.
3. For UI changes, run `./scripts/e2e.sh` against your build and include a screenshot or short recording.
4. Follow the conventions in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules talk through `Services`,
   captures go through `MediaPipeline`, settings use typed `Defaults` keys, no third-party dependencies.
5. Keep changes focused and remove any code your change makes obsolete.

## Reporting bugs

Open an [issue](https://github.com/udsy19/super-screenshot/issues/new/choose) with your macOS version, Mac model
(Apple silicon / Intel), steps to reproduce, and what you expected. Logs are available in Console.app
(filter by `com.udsy.superscreenshot`).

## Code of conduct

Everyone participating is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
