#include "util/deckxios.h"

#if TARGET_OS_IOS

#import <Foundation/Foundation.h>

#include <execinfo.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>
#include <sys/ucontext.h>
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

// Async-signal-safe only. backtrace() returns nothing on this build (frame pointers omitted),
// so dump fault addr, pc/lr/sp/fp from the ucontext and walk the fp chain by hand.
// Addresses are runtime; subtract the printed slide (image 0 = main binary) to get file offsets.
void putHex(int fd, const char* tag, uint64_t v) {
    char buf[48];
    size_t n = 0;
    for (const char* t = tag; *t; ++t) buf[n++] = *t;
    buf[n++] = '0';
    buf[n++] = 'x';
    for (int sh = 60; sh >= 0; sh -= 4) buf[n++] = "0123456789abcdef"[(v >> sh) & 0xf];
    buf[n++] = '\n';
    write(fd, buf, n);
}

void crashHandler(int sig, siginfo_t* info, void* uc) {
    int fd = open(s_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        putHex(fd, "signal ", static_cast<uint64_t>(sig));
        putHex(fd, "slide ", static_cast<uint64_t>(_dyld_get_image_vmaddr_slide(0)));
        putHex(fd, "fault ", reinterpret_cast<uint64_t>(info->si_addr));
        _STRUCT_MCONTEXT64* mc = static_cast<ucontext_t*>(uc)->uc_mcontext;
        putHex(fd, "pc ", arm_thread_state64_get_pc(mc->__ss));
        putHex(fd, "lr ", arm_thread_state64_get_lr(mc->__ss));
        putHex(fd, "sp ", arm_thread_state64_get_sp(mc->__ss));
        putHex(fd, "fp ", arm_thread_state64_get_fp(mc->__ss));
        uint64_t* fp = reinterpret_cast<uint64_t*>(arm_thread_state64_get_fp(mc->__ss));
        for (int i = 0; i < 40 && fp && (reinterpret_cast<uintptr_t>(fp) & 7) == 0; ++i) {
            putHex(fd, "frame ", ptrauth_strip(fp[1], ptrauth_key_return_address));
            uint64_t* next = reinterpret_cast<uint64_t*>(fp[0]);
            if (next <= fp) break;
            fp = next;
        }
        // frame-pointer chain is useless in -fomit-frame-pointer code: also dump the main image's real
        // load address (image 0 is not it on this device), x0..x28 and a raw stack window. Offline: keep
        // words inside [exe, exe+__TEXT size) whose previous instruction is bl/blr = poor man's backtrace.
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const mach_header* h = _dyld_get_image_header(i);
            if (h && h->filetype == MH_EXECUTE) {
                putHex(fd, "exe ", reinterpret_cast<uint64_t>(h));
                break;
            }
        }
        for (int i = 0; i < 29; ++i) {
            char tag[8] = {'x', static_cast<char>('0' + i / 10), static_cast<char>('0' + i % 10), ' ', 0};
            putHex(fd, tag, mc->__ss.__x[i]);
        }
        const uint64_t* sp = reinterpret_cast<const uint64_t*>(arm_thread_state64_get_sp(mc->__ss));
        for (int i = 0; i < 768 && (reinterpret_cast<uintptr_t>(sp) & 7) == 0; ++i) {
            putHex(fd, "stk ", ptrauth_strip(sp[i], ptrauth_key_return_address));
        }
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


    static char s_altStack[64 * 1024];
    stack_t ss;
    ss.ss_sp = s_altStack;
    ss.ss_size = sizeof(s_altStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crashHandler;
    sa.sa_flags = SA_ONSTACK | SA_RESETHAND | SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (int sig : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP}) {
        sigaction(sig, &sa, nullptr);
    }
}

#endif // TARGET_OS_IOS
