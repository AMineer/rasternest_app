# Contributing to RasterNest

Thanks for helping! Bug reports, feature ideas and pull requests are all welcome.

## Getting started

```sh
git clone https://github.com/AMineer/rasternest_app.git
cd rasternest_app
make test   # unit tests
make run    # build + launch the app
```

Requirements: macOS 14+ with Xcode 16+ (Swift 6). For the Linux CLI, Swift 6 on Linux, or `make linux-check` with Docker.

## Guidelines

- Keep `RasterNestCore` **Foundation-only**. No AppKit, CoreGraphics functions or ScreenCaptureKit there, so it keeps building on Linux and Windows.
- Platform code goes behind `#if canImport(...)` / `#if os(...)` in `RasterNestCapture`, or in an OS-specific target.
- Add tests for model and geometry changes in `Tests/RasterNestCoreTests`.
- UI changes: include a screenshot (made with RasterNest, naturally) in the PR.
- Keep PRs focused; open an issue first for large features.

## Releasing

Maintainers: run `scripts/set-version.sh X.Y.Z`, commit, tag `vX.Y.Z` and push. CI does the rest (see `docs/DISTRIBUTION.md`).
