# CrashReporter: alarm(15) truncates crash reports on debug builds — the better the debug info, the less report you get

## Summary

`handleUnrecoverableSignal` arms `alarm(15)` before calling
`CrashReporter::createAndSaveCrash`. That function shells out to `addr2line` to symbolize
the backtrace. On a `CMAKE_BUILD_TYPE=Debug` binary this regularly exceeds 15s, the alarm
handler calls `abort()`, and the report is written truncated — with no backtrace at all,
which is the one part anyone needs.

The failure mode is self-defeating: the more debug information the build carries, the
slower `addr2line` runs, and the less useful the resulting report becomes.

## Where

`src/Compositor.cpp`:

```cpp
// Kill the program if the crash-reporter is caught in a deadlock.
signal(SIGALRM, [](int _) {
    char const* msg = "\nCrashReporter exceeded timeout, forcefully exiting\n";
    [[maybe_unused]] auto w = write(2, msg, strlen(msg));
    abort();
});
alarm(15);

CrashReporter::createAndSaveCrash(sig);
```

## Evidence

Core dump of a truncated report, showing the alarm firing (`_ = 14` is SIGALRM) while
blocked in `addr2line`:

```
#1  operator() (__closure=0x0, _=14) at src/Compositor.cpp:114
#3  <signal handler called>
#5  poll ()
#6  Hyprutils::OS::CProcess::runSync()
#7  execAndGet("addr2line -e /home/<user>/Hyprland/build/Hyprland -Cf 0x284bb54 0x269a047 ...")
#8  CrashReporter::createAndSaveCrash (sig=6) at src/debug/crash/CrashReporter.cpp:232
#9  handleUnrecoverableSignal (sig=6) at src/Compositor.cpp:118
```

The resulting report is 1291 bytes and ends after the library versions — no `Backtrace:`
section. A release build crashing at the same place produces a full 6.9 KB report.
The debug binary here is 431 MB.

Reproduced twice in one session on this machine.

## Suggested fixes

Any of these would help, roughly in order of preference:

1. Write the raw frame addresses to the report *first*, then attempt symbolization and
   append. A truncated report then still contains addresses the reporter can resolve later
   with `addr2line` by hand, instead of nothing.
2. Scale or drop the timeout when the binary is large / built with debug info.
3. Resolve symbols in-process (`libbacktrace`, or `dladdr` + `backtrace_symbols`) rather
   than spawning `addr2line` over the whole binary.

## Environment

Hyprland v0.56.0-156-g4a4a5279, CMAKE_BUILD_TYPE=Debug, Arch Linux, kernel 7.2.2-arch1-1
