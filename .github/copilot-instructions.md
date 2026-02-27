# arbtt Copilot Instructions

## Project Profile

- Language: Haskell (primarily `Haskell98`), Cabal package with multiple executables.
- Main build tool: `cabal` (Stack config exists, but Cabal is canonical in this repo).
- Test style: `tasty` + golden tests in `tests/`.
- Platform support in code: Linux/X11, macOS, Windows via CPP and OS-specific modules.

## Working Rules for This Repo

- Make minimal, surgical changes; avoid broad refactors unless explicitly requested.
- Preserve existing style (module layout, naming, import style, CPP layout, and formatting).
- Prefer explicit, small edits to existing modules over introducing new abstractions.
- Keep behavior stable unless the task explicitly changes behavior.
- Update docs or tests when behavior or CLI behavior changes.

## Haskell Conventions

- Follow existing extension and pragma patterns already used per file.
- Keep imports consistent with nearby code (qualified aliases, ordering, and grouping).
- Avoid introducing new dependencies unless necessary; if needed, justify and scope tightly.
- Respect cross-platform branches (`#if defined(WIN32)`, `DARWIN`, etc.).
- Keep public types and constructors explicit and stable where possible.

## Build and Validation Expectations

When changing code, prefer validating with the smallest relevant commands first:

1. `cabal build all`
2. `cabal test test`

If a task is packaging-related, verify packaging commands in addition to normal build/test.

## Packaging Roadmap Constraints

Current priority is Debian packaging only.

- Stage 1 target: fast `.deb` builds for Ubuntu `DISTRIB_RELEASE=25.04`.
- Do **not** introduce RPM/Red Hat packaging in this stage unless explicitly asked.
- Do **not** introduce GitHub Actions CI/CD automation yet unless explicitly asked.
- Prefer local/reproducible packaging scripts and docs first; CI wiring comes later.

When implementing Debian packaging work:

- Use standard Debian tooling (`debian/` metadata + `dpkg-buildpackage`) unless instructed otherwise.
- Keep packaging deterministic and focused on this repository's existing executables.
- Start with native host build assumptions (Ubuntu 25.04), then add backport/container strategy later.

## Change Scope Guardrails

- Do not rename files/modules or move directory structure unless required.
- Do not add unrelated cleanup in the same change.
- Do not alter release/distribution strategy beyond the task scope.
- If a request is ambiguous, choose the simplest implementation that matches current repo patterns.

## Helpful Commands

- Build: `cabal build all`
- Run tests: `cabal test test`
- Build executable quickly: `cabal build exe:arbtt-capture`
- Run stats manually during debugging: `cabal run arbtt-stats -- --help`

## Collaboration Defaults

- Explain assumptions briefly before major changes.
- Prefer short implementation plans for multi-step packaging/build tasks.
- Report what was validated and what still needs manual verification.