# Contributing to Nib

Thanks for helping! Bug reports, fixes, new app support and new rewrite styles are all welcome.

## Build and run

You need macOS 13+ and Swift 5.9+; the Xcode Command Line Tools are enough. There's no Xcode project: Nib is a Swift package, and `build.sh` wraps it into an app bundle.

```sh
./build.sh                       # → build/Nib.app
open build/Nib.app
```

`build.sh` signs with your first "Apple Development" identity, or ad hoc if you have none. To choose one: `SIGN_IDENTITY="Apple Development: …" ./build.sh`. Use a stable identity: macOS ties the Accessibility permission to the signature, and an ad-hoc signature changes on every build. If Nib is already in the Accessibility list but shows "Not allowed" after a rebuild, remove it with **−** and add it again (or use **Restart Nib** in the setup guide).

To test without touching your normal settings, add `--test-model <model>` (settings stay in memory only).

## Tests

Run these before sending a pull request:

```sh
B=build/Nib.app/Contents/MacOS/Nib
$B --diff-selftest     # fast, no network, no permissions: diff, placement, VS Code geometry, prose rules, regressions
$B --ax-selftest       # Accessibility edits on an in-process text view (formatting kept, undo)
$B --live-selftest     # live checking end to end in an in-process window (needs an API key; keep the window in front)
$B --render-ui DIR     # renders the popups and cards (light/dark) as PNGs into DIR
```

`--diff-selftest` must print no `FAIL`. If you change how cards look, attach before/after renders from `--render-ui`.

There's also an end-to-end mode that drives real apps on throwaway documents. It types and clicks, so don't use the Mac while it runs: `open -n build/Nib.app --args --e2e /tmp/nib-e2e --live`. See [DEVELOPMENT.md](DEVELOPMENT.md).

## Reporting a bug

Use the **Bug report** issue template. The most useful thing you can attach is a **Copy Diagnostics** report:

1. Click in the field where Nib misbehaves.
2. Choose **Copy Diagnostics** from Nib's menu-bar menu. After a 5-second countdown, a report is copied to the clipboard.
3. Paste it into the issue.

The report contains numbers and settings only (app, roles, positions, which step failed), never the text you wrote. Please **don't paste your own private text, API keys or screenshots of private messages** into issues; use a made-up sentence that shows the problem instead.

## Pull requests

- Keep changes focused, and explain the user-visible effect in the description.
- Match the existing style: plain Swift, no third-party dependencies beyond Sparkle, and comments that explain *why*.
- Never log or send user text anywhere except to the provider the user chose. Diagnostics stay numbers-only.
- Add a self-test to `--diff-selftest` for pure logic (see the existing cases in `App.swift`).

By contributing you agree that your contributions are licensed under the MIT licence.
