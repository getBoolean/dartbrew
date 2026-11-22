# dartbrew

dartbrew is a self-contained Dart SDK and CLI for building, running and testing Dart programs as homebrew apps on the New Nintendo 3DS (the `ctr` target). Public names use CTR naming; never use the "3DS" trademark in package, command, file or API names.

## Code style

The test for every change, and for existing code: after the change, is there less for a maintainer to understand at this project's real scale? Count subsystems, concepts, sources of truth, special cases and code that must be kept consistent by hand.

### Order of leverage

1. **Remove** what the project does not need.
2. **Replace** hand-built infrastructure with a maintained package or generator, when its declarations replace code maintained here. Prove it on one real sample first.
3. **Restructure** so each decision has one owner and callers declare intent.
4. **Clean up** local duplication, dead code, weak tests and stale comments.

### Boundaries: callers say what, one place says how

- Prefer a domain operation that owns a complete invariant and its resource lifecycle over callers that remember cleanup sequences or ordering rules.
- Prefer typed requests, results and states over raw strings and booleans that several places interpret.
- When the variation really is data, use a table of rows the code iterates over (one row per operation, read by every consumer), not per-variant handler code.
- Separate a pure decision function from a small imperative executor when that clarifies both.
- Keep algorithms, hardware interaction and tight loops imperative inside a clear boundary when that is easier to read or cheaper to run.

### Build good abstractions

Look for the abstraction a change wants before writing it inline, and introduce it when it earns its place. Good abstractions here are deep: a small, well-named interface over a real responsibility.

- **Name the domain concept.** When code passes the same group of values around, or keeps re-deriving the same fact, give it a type (a run identity, a netloader target, a build mode) instead of a map, a tuple of strings or a comment.
- **Make invalid states unrepresentable.** Model alternatives as a `sealed` class or an `enum` with fields, and handle them with an exhaustive `switch`. A new case then fails to compile everywhere it must be handled, instead of falling through a default.
- **Give one owner to each decision.** A rule (a path layout, a protocol constant, an exit-code mapping, a file format) lives in exactly one place, and everything else asks that place.
- **Own the lifecycle.** An operation that opens a socket, a file, a process or a temp directory also closes it, on every path including errors and cancellation, so callers cannot forget.
- **Keep I/O at the edges.** Put decisions in pure functions that take values and return values, and keep a thin layer that does the I/O. That is also where the test seam goes.
- **Depend on narrow interfaces.** Pass the one capability a unit needs (a function, a small interface) rather than a large object it could misuse. Inject clocks, file systems and processes only where tests need to replace them.

### Judge abstractions by what they hide

An abstraction is worth having when callers know less or mistakes get harder: it names a domain concept, owns an invariant or lifecycle, separates what from how, makes invalid states unrepresentable, gives tests a real seam, or sets the shape for a family that exists or is already planned. A deep abstraction with one caller is fine; duplication is not a prerequisite.

Reject an abstraction that hides nothing:

- renames a block, moves code between files, or adds a pass-through layer;
- has options with one value or plugin points nothing uses;
- is justified only by variants nobody has planned;
- hides real differences (distinct protocols, target-specific policy) behind flags or callbacks;
- replaces readable control flow with callbacks, boolean switches, string action lists or an over-configurable builder;
- creates a second registry or source of truth beside the existing one.

Frameworks, base classes, generic layers and DSLs face a higher bar, because every reader must learn them.

### Changing code

- A large diff is not a cost in itself. Prefer the change that removes the underlying cause over a timid partial extraction that leaves the old and new shapes both alive.
- When replacing a function, type or module whose callers are all in this repository, update the callers and delete the old version in the same change; no wrappers or aliases. Interfaces used outside the repository are contracts and keep working.
- Preserve observable behavior, evaluation order, errors, cancellation, thread affinity and resource ownership in refactors. Do not bundle a behavior correction into a refactor silently.
- Build what was asked. Add a guard, retry, fallback, option or mode only when an existing contract requires it, when leaving it out lets harm land before anyone would notice, or when adding it later would be expensive (stored data formats, public interfaces, security).

### Clean code

- **Names say what a thing is or does.** Use full words from the domain; a reader should not need the body to understand the call. Booleans read as predicates (`isArmed`, `hasHostLink`).
- **Functions do one thing at one level of abstraction.** Extract a step when it has a name worth reading, not to hit a line count. Return early instead of nesting.
- **No magic values.** A port, a priority, a size or a timeout is a named constant next to the code that owns it, with a comment only when the reason is not obvious.
- **Fail loudly and specifically.** Throw or return an error that names what failed and what to do; never swallow an exception or turn it into a silent default. Validate input at the boundary, then trust it inside.
- **Immutable by default.** Prefer values that do not change after construction; keep mutable state local and short-lived.
- **Leave code clearer than you found it** within the files a change already touches, without widening the change.

### Dart conventions

Follow [Effective Dart](https://dart.dev/effective-dart) and the repository's analyzer settings (`package:lints/recommended.yaml` with `strict-casts` and `strict-raw-types`). `dart format`, `dart analyze` (no issues) and `dart test` must pass before a change is done.

- **Naming:** `UpperCamelCase` types and extensions, `lowerCamelCase` members, variables and constants, `lowercase_with_underscores` files and packages. Avoid abbreviations except widely known ones (`id`, `io`, `ffi`).
- **Types:** never use `dynamic` or untyped collections in this code; annotate public APIs fully. Use `final` for locals and fields that do not change, `const` constructors and values where possible, and non-nullable types unless `null` carries meaning.
- **Modern Dart:** use `sealed` classes, records, pattern matching, `switch` expressions and class modifiers (`final class`, `interface class`) where they make intent explicit. Prefer collection literals, `if`/`for` elements and spreads over imperative building.
- **Async:** use `async`/`await`; never leave a `Future` unawaited by accident (mark a deliberate one with `unawaited`). Close every `StreamSubscription`, `Socket`, `Process` and `IOSink` you open.
- **Libraries:** public API in `lib/`, implementation in `lib/src/`; import with `package:` URIs; keep libraries small and focused, and export only what callers need.
- **Docs:** `///` doc comments on public APIs that state the contract (what it returns, throws, and owns), not how it works.
- **Tests:** `package:test`, with test files mirroring the library they cover and `group`/`test` names that read as behaviors.
- **C/C++** (launcher, SDK patches): follow the Dart SDK's C++ style in `runtime/`, so patches read like upstream code.

### Tests and comments

- Tests prove the behavior a change builds. A test must fail when the behavior breaks and keep passing when only the implementation changes; its expected value never comes from the code under test.
- Test through real entry points; do not add production hooks only tests use.
- Comments state current contracts and constraints. No task-history narration, future promises, commented-out code or comments that repeat the code. When a comment explains surprising structure, prefer the rename, type or extraction that makes it unnecessary.

## Project conventions

- Dart SDK changes go into the managed patch queue (`toolchain/patches/dart/`, registered in `toolchain/versions.json`), never as launcher-side workarounds.
- Linux builds and tests run in the Docker Compose `toolchain` service (container `ctr-dart-toolchain`). Run one heavy SDK build at a time; the WSL VM has a 10 GB memory cap.
- Driving the console for hardware tests: see `.claude/skills/driving-ctr-console/SKILL.md`.
- Heavy Linux builds (SDK target graphs, precompilers, clang, SDK assembly) may run on boat.dev VMs. The owner approved this on 2026-11-21, including sending the repository working tree to boat's EU servers and paying for VM time. The API key comes through the host's secret mechanism, never in chat or the repository.
