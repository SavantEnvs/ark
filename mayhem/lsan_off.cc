// mayhem/lsan_off.cc -- build-time LeakSanitizer off-switch (SPEC 6.2 item 15).
//
// -fsanitize=address always bundles LeakSanitizer, and there is no flag that keeps ASan while
// dropping only leak detection. Leaks are not the bug class this target is fuzzed for (ASan's
// memory-safety checks and UBSan are), so leak detection is turned off here, at build time.
// The LeakSanitizer runtime declares this hook weak and calls it before every leak check (the
// at-exit check and libFuzzer's per-input check); this strong definition returns 1, so those
// checks report nothing. ASan and UBSan stay fully active, and no runtime option is set.
//
// mayhem/build.sh compiles this file with $SANITIZER_FLAGS and links it into both ASan-built
// binaries: /mayhem/arkscript (libFuzzer) and /mayhem/arkscript-standalone. The non-sanitized
// oracle build (mayhem-build/test) does not link it, since it has no LeakSanitizer to turn off.
extern "C" int __lsan_is_turned_off() { return 1; }
