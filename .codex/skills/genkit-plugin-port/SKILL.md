---
name: genkit-plugin-port
description: Port a Genkit plugin from a source language to a target language with functional equivalence. Use when Codex needs to recreate a Genkit plugin in another language (e.g. TypeScript to Python or vice versa), including implementation, tests, example app, build/config, and docs; or when asked to translate or port a Genkit plugin for Anthropic/Codex.
---

# Genkit Plugin Port

You are a software engineer tasked with porting a Genkit plugin from a source language to a target language.

## Context & Inputs

You have access to:

- A browser automation tool via `mcp__browser_tools__run_playwright_script` (Playwright) for interacting with the Genkit UI (and for researching language/library equivalents and Genkit plugin APIs when needed).
- The plugin's repository, including source code, tests, and any example/test app.
- A filesystem and CLI to inspect, build, run, and test the code.

## Objective

Recreate the plugin in the target language so that it is **functionally equivalent** to the original.

**"Functionally equivalent"** means:

- Same external API surface (as appropriate for the target language ecosystem): configuration options, exported symbols, and expected behaviors.
- Same runtime behavior: inputs/outputs, error handling, retries/timeouts, streaming behavior, and edge cases.
- Same operational characteristics where feasible: logging, resource management, auth/credentials handling, and defaults.
- Equivalent test coverage and passing tests (or a clearly documented reason when exact parity is impossible).

## Deliverables

Produce a complete port that includes:

1) Plugin implementation in the target language  
2) Any accompanying test/example app translated (if present)  
3) Updated build/config files for the target ecosystem  
4) Documentation updates (README / usage snippets) reflecting the target language  

## Workflow

1) Read and summarize the plugin's purpose, public API, and key behaviors.  
2) Identify language/runtime differences and choose idiomatic target-language equivalents without changing semantics.  
3) Port incrementally:
   - Core types/interfaces
   - Main implementation
   - Integration points (Genkit registration, config, lifecycle)
   - Tests and example app
4) Validate equivalence:
   - Run the original tests (where possible) to understand expected behavior
   - Run the translated tests and example app
  - Use Playwright via `mcp__browser_tools__run_playwright_script` to interact with the Genkit UI and verify the translated plugin behaves the same (configuration, flows/tools visibility, execution traces, streaming, errors).

## Constraints

- Keep the logic and structure as close as reasonable; prefer minimal behavioral changes.
- If you must diverge (dependency gaps, platform differences), document:
  - What changed
  - Why it changed
  - The impact on behavior
  - Any follow-up work or alternatives

## Done Criteria

The port is complete when:

- The plugin builds in the target language and passes its test suite.
- The example/test app runs (if present).
- Behavior matches the original for documented use cases and edge cases, **including when exercised through the Genkit UI**.
- Any unavoidable differences are explicitly documented.
