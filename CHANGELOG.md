# Changelog

## 2.2.4

- **No more false "Underlines aren't available" messages.** A hint now needs evidence: you're typing into an editable field (never a button, link, list, the address bar, a search field, Finder or the desktop), its text actually changed, and the failure has lasted a few seconds (not a moment while an app rebuilds its accessibility tree, and not right after a click). It appears at most once per app, ever, as a short card ("No underlines in Chrome here — double-tap ⌥ to correct.") with **Don't show again**; after that, the menu shows "Underlines unavailable in <App> — why?". Turn hints off in Settings → Live checking.
- **Underlines in wrapped paragraphs of rich editors** (Chrome forms, Slack…) now sit on the right line. A paragraph that wraps is one text run several lines tall; Nib placed every underline at the bottom of that run, so words on the first line were underlined on the last. It now works out the run's lines and places each underline on its own line.
- **Chrome underlines stay on their words.** Positions are no longer reused after the page or the field scrolls or the layout changes, only underlines inside the visible field are drawn, and in Chrome and Electron apps each underline is checked against the character under it before it's drawn; a mismatch is recomputed instead of drawn in empty space.
- **✨ Rewrite chip**: sized for your popup font (no more "Rewri…" with large fonts), and placed just after the selection on the same line (or just below it near the screen edge), never over the selected text.
- How these were checked: the Chrome fixes (wrapped runs, layout-keyed position caches, the hit-test check) were verified with self-tests and against a real Chrome log, not yet with a hands-off run; please report any underline that lands in the wrong place, ideally with Menu → Copy Diagnostics….

## 2.2.3

- **Every language is checked by default.** Settings → Languages to check is now opt-out: all languages start ticked, and you untick the ones you don't want checked as you type. Your Mac's language list is only used as a hint when a short piece of text is hard to identify; it never causes a language to be skipped. (In 2.2.2 the default followed the Mac's languages, so Korean wasn't checked on a Mac without Korean in its list.) If you never changed the list, you get the new default automatically; a list you changed is kept.

## 2.2.2

- **Chinese and Korean.** Each paragraph's language is detected on your Mac, and the AI is told the language and its rules: for Chinese, wrong characters (在/再, 的/得/地…), measure words, full-width punctuation, and Simplified or Traditional kept as written; for Korean, spacing (띄어쓰기), spelling, particles, and the speech level and honorifics kept as written. Casual chat and mixed Chinese/Korean–English text are left alone. On the held-out evaluation, Chinese fix accuracy rose from 3/5 to 5/5, with English and Korean at 100%.
- **Settings → Languages I write in**: choose which languages are checked as you type (default: English plus your Mac's languages); "Other languages" covers the rest.
- Fixed: live checking never checked Chinese text (it needed three space-separated words) and skipped short Korean sentences.
- Fixed: ⌥⌥ could occasionally change a correct Chinese character (it now runs at temperature 0).
- Suggestions whose fix rewrote more than the marked words (seen with some Qwen and DeepSeek models) are narrowed to what actually changes, so applying them can't duplicate text.
- Underline positions: VS Code places Chinese, Japanese and Korean text by its real width (measured from the editor font and macOS's fallback fonts: Hangul ≈ 1.44 and Chinese ≈ 1.66 ASCII columns, including word wrap); rich editors (Slack, Chrome) place underlines by measured text width. Verified hands-off with Chinese and Korean in TextEdit, a Chrome textarea and a Chrome rich editor, and in VS Code.
- Providers: a parameter a model rejects (e.g. `temperature` on newer Claude models, `response_format` on DeepSeek) is remembered, so later calls need one request instead of two. Test connection works with thinking models.

## 2.2.1

- **Better prompts, measured.** A new evaluation set (synthetic only, in `Evals/`) and harness (`Nib --eval`) compared the old and new instructions on held-out cases. Rewrites no longer invent details, change numbers ("40k" → "$40,000"), or follow instructions hidden in the text; the "Confident", "Sales", "Apology", "Feedback" and "Complaint" styles no longer ask for things the text doesn't contain. Held-out rewrite pass rate 2/7 → 6/7; live-checking accuracy unchanged at 100%, with about 40% fewer input tokens per check.
- Code is never "corrected": identifiers, file names, URLs, e-mails, @mentions, #channels and anything in backticks are left alone by live checking, and ⌥⌥ puts `code` back exactly as it was.
- Fixed: an underline could be placed inside another word when the mistake was a short word that also appears inside an earlier one ("er" in "gestern").

## 2.2.0

- **Usage statistics** (Settings → Usage): calls and tokens (input, output and thinking, counted separately) for today, 7 days or 30 days, split by feature (live checking, correct, rewrite, test connection) and by model when there's more than one. Calls whose provider didn't report tokens are counted and marked. **Export CSV…** and **Reset Statistics…**. Optional menu line: "Today: N calls · X tokens".
- Stored only on your Mac (the last 1,000 calls and 90 days of daily totals), with no text ever and nothing sent anywhere.
- Fixed: the "No API key" message could name the wrong provider.

## 2.1.0

- **Privacy notice and consent.** The setup guide and Settings → Privacy say exactly what is sent where: your text goes to the provider you chose, with your key, and live checking sends paragraphs as you type. Live checking doesn't start until you confirm.
- **Automatic updates** (Sparkle, EdDSA-signed). Nib checks for updates automatically; you can turn this off in Settings. **Check for Updates…** is in the menu.
- First public, open-source release (MIT).

## 2.0.20

- Popups are never clipped: long text wraps at about 460 pt (scaled with the font-size setting), and every floating card stays on screen.
- Long changes are shown in place, with punctuation-level detail, so a single "?" or "," can't be missed. The changed part of a fix is in the accent colour.

## 2.0.19

- VS Code: underlines in files opened from disk. Current VS Code exposes the whole file as one block, so Nib now works out each word's position from the cursor row, the character width and word wrap.

## 2.0.18

- VS Code: file names from the window's document, more prose file types, and only the visible lines are checked. Copy Diagnostics explains the prose decision and how lines were matched.

## 2.0.16 – 2.0.17

- Slack and other Chromium/Electron apps recover by themselves when their accessibility tree arrives late or is dropped. Nib asks for it again (at most every 5 s), and per-field "no positions" results expire after 10 s.

## 2.0.11 – 2.0.15

- Experimental underlines in code editors (VS Code, Cursor, Windsurf), off by default, for prose files only.
- Model ID protected from accidental edits (Edit… / Save).
- Fixed: 2.0.11–2.0.14 broke Slack underlines; the code-editor rules now apply only in code editors.

## 2.0.1 – 2.0.10

- Rich editors in Chromium and Electron apps: underlines and the popup in Slack, Chrome `<textarea>`, `<input>` and contenteditable.
- Copy Diagnostics: a step-by-step report (numbers only, never text) of where live checking stops in the front app.
- A Restart Nib button in the setup guide (needed after the Accessibility permission changes).

## 2.0.0

- Choose your AI provider and model: Gemini (AI Studio or Vertex AI), Claude, OpenAI, DeepSeek, Qwen (international or China), or any OpenAI-compatible server. One key per provider in the Keychain; Load models; Test connection with plain-language errors.

## 1.0.1

- Developer ID–signed, notarised DMG.

## 1.0

- Correct with ⌥⌥ (apply, or show the changes first), undo with ⌃⌥Z.
- Live checking with underlines, a popup (Apply / Apply All / Ignore) and usage examples for tricky words.
- Rewrite selection (✨ or ⇧⇧) in 13 editable styles.
- Pause with ⌘⌘. Opt-in switches to hide macOS's own spelling underlines, autocorrect or predictive text while Nib is on (your settings are restored).
- Setup guide, Settings, menu-bar status.
