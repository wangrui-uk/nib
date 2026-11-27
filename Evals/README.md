# Prompt evaluation

Synthetic test cases (never real user text) for Nib's three AI tasks, and a harness that runs the app's real request code on them.

- `proofread.json`: live-checking cases, with the expected issues (span, acceptable fixes, kind) or none (`mustNotChange`).
- `correct.json`: ⌥⌥ cases with acceptable outputs.
- `rewrite.json`: rewrite cases with must-keep / must-not-add strings; graded by an LLM judge too.
- `prompts/<version>/`: candidate instructions (`proofread.txt`, `correct.txt`, `rewrite.txt` with `{style}`, optional `styles.json`, and a `guards` file to turn on the code guards). `v0` is the 2.2.0 baseline; `v5` is what 2.2.1 ships (and equals the built-in prompts).

Each case has a `split`: iterate on `dev`, report on `test`.

```sh
B=build/Nib.app/Contents/MacOS/Nib
$B --eval Evals --prompts builtin --split dev --out /tmp/nib-evals            # current app prompts
$B --eval Evals --prompts v0 --split test --judge none --label base          # no in-app judge: writes *.judge-input.json
$B --eval-merge RUN.json VERDICTS.json --judge-name haiku                     # add an external judge's verdicts
$B --eval Evals --provider deepseek --model deepseek-chat --prompts builtin   # another provider (uses its saved key)
```

Scoring: proofread recall, fix accuracy (the corrected region compared with the acceptable fixes, whatever span the model chose), precision, must-not-change violations, valid JSON; ⌥⌥ exact match and violations; rewrite must-keep checks plus a judge rubric (facts, no invention, meaning, language, style, length, format). Tokens and latency are recorded per call. Nothing is written to the app's usage statistics.
