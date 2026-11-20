#pragma once

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS
/// deckx dev helpers (iOS only).
/// Appends the lines of <Documents>/deckx-args.txt (one argument per line,
/// blank lines and lines starting with '#' ignored) to argv. The returned
/// argv stays valid for the whole process lifetime.
void deckxIosAppendArgs(int* pArgc, char*** pArgv);
/// Writes signal + backtrace_symbols_fd to <Documents>/deckx-crash.txt on a
/// fatal signal.
void deckxIosInstallCrashHandler();
/// Writes <Documents>/deckx-life.txt (events) and deckx-hb.txt (1 Hz heartbeat) to explain silent deaths.
void deckxIosInstallLifecycleLog();
#else
inline void deckxIosAppendArgs(int*, char***) {
}
inline void deckxIosInstallCrashHandler() {
}
inline void deckxIosInstallLifecycleLog() {
}
#endif
