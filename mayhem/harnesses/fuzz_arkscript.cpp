#include <cstdint>
#include <cstddef>
#include <string>
#include <filesystem>

#include <Ark/Ark.hpp>

// Deliberately no harness-side timer or watchdog: a slow or non-terminating ArkScript program
// (e.g. a fuzzed `(while true ...)`) is bounded by the runner -- libFuzzer's own -timeout /
// Mayhem's per-test timeout (the Mayhemfile `timeout:`) -- and reported as a hang, like a crash.

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    const std::string code(reinterpret_cast<const char*>(data), size);

    try
    {
        // Only a dedicated, pure-ArkScript copy of the standard library is searchable -- never
        // the project's own lib/ tree (build.sh later populates $SRC/lib/hash.arkm, a NATIVE
        // module, as a side effect of the separate oracle build; /mayhem/fuzz-lib never gets
        // that file, so `import` can only ever pull in .ark source, never native code). ArkScript's
        // import package-name grammar also only accepts [A-Za-z0-9_-] per segment (see
        // BaseParser::packageName), so `.`/`/` can never appear inside a segment and `import` can
        // never escape this directory via `..` or an absolute path.
        Ark::State state({ std::filesystem::path("/mayhem/fuzz-lib") });
        state.setDebug(0);

        // Compile the fuzzer bytes as ArkScript source (parser -> import solver -> macro
        // processor -> name resolver -> AST optimiser -> IR -> bytecode compiler), then execute
        // the resulting bytecode in the VM -- both surfaces named in the repo intel. This mirrors
        // upstream's OWN fuzz setup (tests/fuzzing/docker/2-fuzz.sh runs `arkscript @@ -L lib`,
        // i.e. compile AND run, not compile-only).
        if (state.doString(code))
        {
            Ark::VM vm(state);
            vm.run();  // fail_with_exception=false: ArkScript's own Ark::Error hierarchy is
                       // caught internally (see VM::safeRun) and reported, not rethrown; a
                       // genuinely unexpected C++ exception is rethrown when
                       // FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION is defined (build.sh defines
                       // it) so it escapes to become a libFuzzer-reported crash.
        }
    }
    catch (const Ark::Error&)
    {
        // Expected: malformed-but-parseable ArkScript program (type error, unbound symbol,
        // assertion failure, ...). Not a bug.
    }
    // Deliberately NOT catching (...) here: any other exception (e.g. std::bad_alloc from a real
    // bug, or anything escaping the compiler's CodeError-only catch) is a genuine finding and
    // should propagate to std::terminate so libFuzzer/ASan reports it as a crash.

    return 0;
}
