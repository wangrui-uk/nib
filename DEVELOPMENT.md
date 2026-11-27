# How Nib works

Notes for contributors. For building and testing, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Code layout

| File | What |
|---|---|
| `App.swift` | Menu bar, menu, correct / undo / suggest flow, windows, command-line modes, `--diff-selftest` |
| `TextAccess.swift` | Per-app routing; reading and writing through Accessibility (minimal edits, read-back, undo); clipboard fallback |
| `TextTarget.swift` | Finding the focused text field (wrappers, rich editors, Chromium/Electron tree) |
| `LiveChecker.swift` | Live checking: polling, per-paragraph cache, underline overlay, popup, Apply |
| `TextMarkers.swift` | Text positions in Chromium/WebKit: text markers, text runs, line hit-testing |
| `Monaco.swift` | VS Code / Cursor main editor: prose rule, EditContext geometry, visible lines |
| `AI.swift`, `Proofread.swift`, `Gemini.swift` | Provider clients (Gemini, Anthropic, OpenAI-compatible, Vertex), the issue-list request, corrections |
| `Rewrite.swift`, `RewriteStyles.swift`, `SelectionChip.swift` | Rewrite card, styles, the ✨ button |
| `HUD.swift`, `PopupCard.swift`, `CardLayout.swift` | Messages, suggestion card, shared card style, on-screen placement, inline diff |
| `Surfaces.swift` | One card at a time: the coordinator that decides what may show |
| `SystemTextChecking.swift` | Opt-in switches for macOS spelling underlines, autocorrect and predictive text (saved and restored) |
| `Diagnostics.swift`, `E2E.swift`, `SelfTest.swift` | Copy Diagnostics, end-to-end runs, in-process tests and UI renders |
| `Settings.swift`, `SettingsView.swift`, `OnboardingView.swift` | Preferences, Keychain, Settings window, setup guide |
| `Usage.swift` | Local usage statistics: token parsing per protocol, storage, Settings → Usage |
| `Updates.swift`, `Consent.swift` | Sparkle updater; the privacy notice and the OK asked before live checking runs |
| `NibIcon.swift` | The app and menu-bar icons, drawn in code |

View state lives in `ObservableObject`s rather than `@State`, because the Command Line Tools have no SwiftUI macro plugin.

## Reading and writing text

| App | Read | Write |
|---|---|---|
| Native Cocoa apps (TextEdit, Notes, Mail, Messages, Pages…) | Accessibility: the selection or the field's value | Accessibility, only the changed words (formatting kept), read back to confirm; then a whole-field write; then paste |
| Safari / WebKit fields | Accessibility | Same, with a paste fallback |
| Chromium browsers (Chrome, Edge, Brave, Arc…) | ⌘C, or ⌘A ⌘C; the web tree is switched on with `AXEnhancedUserInterface` | ⌘V, old clipboard restored, read back when possible |
| Electron apps (Slack, Notion, Discord, Obsidian…) | ⌘C / ⌘A ⌘C; tree via `AXManualAccessibility` | ⌘V |
| VS Code, Cursor, Windsurf, Sublime | ⌘A ⌘C unless text is selected | ⌘V |
| Terminals, password fields | refused | refused |

Safety checks: nothing is pasted if you switched apps or edited the field meanwhile; a correction that would drop an attachment is refused; temporary pastes are marked transient so clipboard managers skip them.

## Live checking

- About 1 s after typing stops, Nib sends the paragraphs it hasn't seen (cached by paragraph text): at most one request every 2 s, up to 4,000 characters each.
- Issues come back as `{kind, text, fix, reason, example}` through each provider's structured-output option, and are found again in the current text, so text that has changed since is never marked wrongly.
- Positions, best first:
  1. `AXBoundsForRange` when it's word-sized and inside the field;
  2. Chromium/WebKit text markers;
  3. the editor's text runs;
  4. line hit-testing.

  VS Code's EditContext gets computed geometry (see `Monaco.swift`).
- Underlines are drawn in a transparent, click-through overlay, re-read every 150 ms.
- Nib never re-checks or reverts its own fixes. Text it wrote counts as checked, and a suggestion that would undo an earlier fix is dropped.
- Chromium/Electron trees that arrive late or get dropped are asked for again (at most every 5 s), and per-field "no positions" results expire after 10 s.

## Diagnostics and logs

- **Copy Diagnostics** (menu) reports, for the focused field, every step live checking takes, with ✓/✗, and the numbers behind them. It never includes text.
- `~/Library/Logs/Nib.log` and `log stream --predicate 'process == "Nib"'` record the app, route, lengths, timings and errors, never text.

## Tests

| Command | What it covers |
|---|---|
| `--diff-selftest` | Pure logic: diffs, merges, card placement, inline diff, VS Code geometry and prose rules, regression cases (no network, no permissions) |
| `--ax-selftest` | Accessibility minimal edits, read-back and undo on an in-process rich text view |
| `--live-selftest` | Live checking end to end in an in-process window (real provider call) |
| `--render-ui DIR` | PNG renders of popups and cards, light and dark |
| `--e2e DIR [--live] [--only "textedit,safari"]` | Drives real apps on throwaway documents; don't use the Mac while it runs |
| `--e2e DIR --attach [--prep-editor] [--scroll-test] [--apply]` | Tests whatever field is in front (used for VS Code) |
| `--ai-check <provider> [--model M] [--key K]` | Checks a provider/key/model from the command line without changing settings |

## Releases

`release.sh` builds, signs with **your** Developer ID (hardened runtime), notarises and staples the app and the DMG, and checks them with Gatekeeper. Configure it with `DEVELOPER_ID` and `NOTARY_PROFILE` (environment, or a git-ignored `release.local.env`). `./release.sh --publish` also creates the GitHub release, uploads the DMG, and adds the update to the Sparkle appcast (`docs/appcast.xml`, signed with the EdDSA key in your Keychain).

## Compatibility notes

- The bundle identifier (`com.ruiwang.grammar-ai`), the Keychain service and the preferences domain date from the app's first name (Grammar AI). They're kept so existing installs keep their key, settings and Accessibility permission.
