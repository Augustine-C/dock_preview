# Repository Guidelines

## Project Structure & Module Organization

- `Sources/DockPreview/`: application lifecycle, hover coordination, accessibility, capture, AppKit panels, and SwiftUI settings.
- `Sources/PreviewCore/`: reusable window matching, hover state, layout, and cache logic.
- `Tests/PreviewCoreTests/`: XCTest coverage for core behavior.
- `Resources/Info.plist`: metadata and versions; `scripts/make-icon.swift` generates the icon.
- `scripts/`: build, test, and performance measurement tools.
- `validation/` and `VALIDATION.md`: measurements and verification. Generated artifacts belong in ignored `build/` or `.build/`.

## Build, Test, and Development Commands

Target macOS 27.0, Apple Silicon, and Xcode tools; SwiftPM tools 6.0, Swift 5 language mode.

```sh
./scripts/build.sh                 # Build, bundle, and sign the arm64 release app
open "build/Dock Preview.app"      # Run the menu-bar application
./scripts/test.sh                  # Run XCTest through SwiftPM
open -n "build/Dock Preview.app" --args --demo
```

Demo mode uses synthetic cards. Measure resources with `python3 scripts/measure.py --pid <PID> --seconds 30 --mode idle --output build/idle.json`.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods and properties. Follow existing Swift/AppKit conventions. No formatter or linter is configured; run `git diff --check` before committing.

Keep UI work on the main actor and accessibility state on its serial queue. Preserve session-generation checks so stale asynchronous results cannot update a different preview.

## Testing Guidelines

Name XCTest methods `test<Behavior>`, such as `testResetInvalidatesPendingCapture`. Cover matching ambiguity, hover cancellation, layout boundaries, and cache limits. No coverage percentage is required.

Test and build code changes. Manually verify affected minimized-window, Spaces, fullscreen, and permission behavior. Record evidence in `VALIDATION.md`, distinguishing automated checks from interaction results.

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): description`, with an optional scope and a short imperative description. Types include `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, and `revert`. Examples: `fix(capture): match off-Space windows` and `docs: update contributor guidelines`. Mark breaking changes with `!` or a `BREAKING CHANGE:` footer.

Agents must commit changes throughout development, after each coherent, validated milestone, rather than waiting until the task ends. Create focused local commits for implementations, regression fixes, tests, and documentation. Review and stage only task-related changes; preserve unrelated work. Record validation limitations in the commit body. Do not push unless authorized.

PRs should describe the problem, behavior, validation, and limitations. Link related issues and include sanitized screenshots for UI changes.

## Security & Configuration

Use public APIs and normal close/quit confirmation flows. Never force-terminate applications or persist/upload previews. Bound screenshot concurrency and cache budgets.

Signing uses `SIGNING_IDENTITY`, then ignored `.signing-identity`, otherwise ad-hoc signing. Never commit certificates, credentials, signing configuration, or private diagnostics. Permission grants remain user-controlled.
