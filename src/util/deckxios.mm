#include "util/deckxios.h"

#if TARGET_OS_IOS

#import <Foundation/Foundation.h>

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

char s_crashPath[1024] = {0};
std::vector<std::string> s_args;
std::vector<char*> s_argv;

std::string documentsDir() {
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) {
        return std::string();
    }
    return std::string([dirs[0] UTF8String]);
}

// Only async-signal-safe calls: open/write/close/signal/raise/_exit and
// backtrace()/backtrace_symbols_fd() (primed at install time).
void crashHandler(int sig) {
    int fd = open(s_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char msg[32] = "signal ";
        size_t n = strlen(msg);
        char digits[8];
        int d = 0;
        int v = sig;
        do {
            digits[d++] = static_cast<char>('0' + v % 10);
            v /= 10;
        } while (v > 0 && d < 7);
        while (d > 0) {
            msg[n++] = digits[--d];
        }
        msg[n++] = '\n';
        write(fd, msg, n);
        void* frames[64];
        const int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

} // namespace

void deckxIosAppendArgs(int* pArgc, char*** pArgv) {
    const std::string path = documentsDir() + "/deckx-args.txt";
    NSString* text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text) {
        return;
    }
    for (NSString* line in [text componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet newlineCharacterSet]]) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        s_args.emplace_back([trimmed UTF8String]);
    }
    if (s_args.empty()) {
        return;
    }
    for (int i = 0; i < *pArgc; ++i) {
        s_argv.push_back((*pArgv)[i]);
    }
    for (std::string& arg : s_args) {
        s_argv.push_back(arg.data());
    }
    *pArgc = static_cast<int>(s_argv.size());
    s_argv.push_back(nullptr);
    *pArgv = s_argv.data();
}

void deckxIosInstallCrashHandler() {
    const std::string path = documentsDir() + "/deckx-crash.txt";
    if (path.size() < 17 || path.size() >= sizeof(s_crashPath)) {
        return;
    }
    memcpy(s_crashPath, path.c_str(), path.size() + 1);

    void* prime[4];
    backtrace(prime, 4); // load unwinder now, not inside the handler

    static char s_altStack[64 * 1024];
    stack_t ss;
    ss.ss_sp = s_altStack;
    ss.ss_size = sizeof(s_altStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crashHandler;
    sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    for (int sig : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP}) {
        sigaction(sig, &sa, nullptr);
    }
}

#endif // TARGET_OS_IOS
