---
name: genkit-dart-quality-loop
description: Run the standard Genkit Dart quality gate loop. Use when working on Genkit repositories or plugins to repeatedly execute formatting, analysis, code generation, and tests until all checks pass with no issues.
---

# Genkit Dart Quality Loop

Execute this exact command sequence from the repository root:

1. `dart format .`
2. `melos run analyze`
3. `melos run build-gen`
4. `melos run test`

After running all four commands, evaluate the results.

- If any command reports issues or fails, fix the issues and run the full four-command sequence again from the top.
- Continue iterating until all four commands complete with no issues.

## Execution rules

- Always run from the repo root.
- Do not skip steps, even if only one command failed in the previous iteration.
- Prefer minimal fixes that preserve existing behavior.
- Before finalizing work, ensure the last full iteration has all four commands passing.
