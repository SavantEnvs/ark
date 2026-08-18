# Uncaught `std::ios_base::failure` on a failed `import` when compiling from a string

**Found by:** the `arkscript` libFuzzer target (`mayhem/harnesses/fuzz_arkscript.cpp`), within
seconds of a `-fork` smoke run over the seed corpus (see `crash-repro.ark`), and independently
minimized to one line.

**Reproduce (no sanitizer needed — this is a plain abort, not a memory-safety bug):**

```
$ arkscript -e "(import doesnotexist)"
terminate called after throwing an instance of 'std::__ios_failure'
  what():  basic_filebuf::underflow error reading the file: Is a directory
Aborted (core dumped)
```

Also reachable through `Ark::State::doString()` directly (what our harness, the REPL, and
`arkscript -e` all use), and through the fuzz target on any program whose first top-level
`import` cannot be resolved — `crash-repro.ark` here is one such input pulled straight from a
`-fork=4` smoke run over `tests/fuzzing/corpus-cmin-tmin/`.

## Root cause

`Ark::Welder::computeASTFromString()` has no real source file, so it sets the "root" used for
resolving relative imports to the process's **current working directory**:

```cpp
// src/arkreactor/Compiler/Welder.cpp
bool Welder::computeASTFromString(const std::string& code)
{
    m_root_file = std::filesystem::current_path();  // No filename given, take the current working directory
    return computeAST(ARK_NO_NAME_FILE, code);
}
```

When a top-level `(import foo)` fails to resolve, `ImportSolver::findFile()` throws a `CodeError`
whose `CodeErrorContext` carries that same `m_root_file` — i.e. a real **directory** path, not the
`ARK_NO_NAME_FILE` sentinel string used everywhere else to mean "there is no file to read":

```cpp
// src/arkreactor/Compiler/Package/ImportSolver.cpp — parseImport() -> findFile()
throw CodeError(
    fmt::format("...couldn't import {}: file not found", ...),
    CodeErrorContext(file.generic_string(), ...));   // file == m_root_file == a directory
```

`Welder::computeAST()`'s catch block *does* check the outer compilation unit's filename against
`ARK_NO_NAME_FILE` and picks `Diagnostics::generateWithCode(e, code)` (the in-memory, safe path)
— but that path still renders the error's *own* embedded `CodeErrorContext.filename` by opening it
for a source-line preview (`Diagnostics::Printer::Printer` → `Ark::Utils::readFile()`), unaware
that this particular context's "filename" is actually the CWD directory, not a source file. Opening
a directory with `std::ifstream` succeeds, and the first read then throws `std::ios_base::failure`
("Is a directory") — uncaught, so it terminates the process.

## Impact

Any ArkScript embedder or the CLI's own `-e`/`--eval` mode (and the REPL, which also compiles via
`doString`) crashes on a single malformed `import` in code it never wrote to disk — a trivial,
user-triggerable denial of service with no attacker-controlled memory corruption. For our fuzz
target it also means "any input with an unresolvable first-level import" is a guaranteed abort,
which is why it dominates the crash set in a short smoke run — this is a real, singular bug rather
than fleet noise, and it does not reduce the value of the corpus (its fixed, singular PC lets
libFuzzer keep growing coverage past it in `-fork` mode with `-ignore_crashes=1`; see the
`-fork=4` note in the integration writeup).

## Suggested upstream fix

In `ImportSolver::findFile` (or at the `CodeError` construction site), use `ARK_NO_NAME_FILE`
instead of `m_root_file` when the root came from a string compilation (`is_directory(m_root_file)`
is already computed once in `ImportSolver::setup` — the same check that decides `m_root` there
could gate which value is threaded into the thrown error's context), OR have
`Diagnostics::Printer` treat a context filename that is a directory (or equals
`ARK_NO_NAME_FILE`) as "no source preview available" instead of unconditionally opening it.

**Not fixed here** — this repo's `mayhem/` layer is purely additive per the integration contract;
this note plus `crash-repro.ark` is the record for upstream / the next worker.
