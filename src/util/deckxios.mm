#include "util/deckxios.h"

#if TARGET_OS_IOS

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <execinfo.h>
#include <mach/mach.h>
#include <pthread.h>
#include <time.h>
#include <atomic>
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


// ---- lifecycle / heartbeat log (why does the process vanish without a crash file?) ----
// <Documents>/deckx-life.txt  : appended event lines (UIApplication notifications, atexit)
// <Documents>/deckx-hb.txt    : overwritten once per second: wall time, seconds since the main queue last ticked,
//                               UIApplication state (0 active,1 inactive,2 background), phys_footprint MB.
// Last heartbeat after a death = when it happened and whether the main thread was stuck / app backgrounded.
std::string s_lifePath, s_hbPath;
std::atomic<int> s_appState{-1};
std::atomic<long long> s_mainTickMs{0};

long long nowMs() {
    timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

void lifeLine(const char* what) {
    if (s_lifePath.empty()) return;
    int fd = open(s_lifePath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[160];
    int n = snprintf(buf, sizeof buf, "%lld %s state=%d\n", nowMs(), what, s_appState.load());
    write(fd, buf, n);
    close(fd);
}

void* heartbeatMain(void*) {
    for (;;) {
        task_vm_info_data_t vi;
        mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
        long long mb = -1;
        if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vi), &cnt) == KERN_SUCCESS) {
            mb = static_cast<long long>(vi.phys_footprint >> 20);
        }
        const long long now = nowMs();
        char buf[160];
        int n = snprintf(buf, sizeof buf, "t=%lld main_age_ms=%lld state=%d footprint_mb=%lld\n", now,
                s_mainTickMs.load() ? now - s_mainTickMs.load() : -1, s_appState.load(), mb);
        int fd = open(s_hbPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, buf, n);
            close(fd);
        }
        sleep(1);
    }
    return nullptr;
}

void atexitHook() {
    lifeLine("atexit (exit() or return from main)");
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
    for (int sig : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGTERM, SIGQUIT}) {
        sigaction(sig, &sa, nullptr);
    }
}

void deckxIosInstallLifecycleLog() {
    const std::string dir = documentsDir();
    if (dir.empty()) return;
    s_lifePath = dir + "/deckx-life.txt";
    s_hbPath = dir + "/deckx-hb.txt";
    unlink(s_lifePath.c_str());
    lifeLine("start");
    atexit(atexitHook);
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    struct Ev { NSNotificationName name; const char* label; };
    static const Ev evs[] = {
        {UIApplicationDidBecomeActiveNotification, "didBecomeActive"},
        {UIApplicationWillResignActiveNotification, "willResignActive"},
        {UIApplicationDidEnterBackgroundNotification, "didEnterBackground"},
        {UIApplicationWillEnterForegroundNotification, "willEnterForeground"},
        {UIApplicationWillTerminateNotification, "willTerminate"},
        {UIApplicationDidReceiveMemoryWarningNotification, "memoryWarning"},
    };
    for (const Ev& e : evs) {
        const char* label = e.label;
        [nc addObserverForName:e.name object:nil queue:nil usingBlock:^(NSNotification*) {
            lifeLine(label);
        }];
    }
    // main-queue tick: proves the main thread is responsive and samples the UIApplication state
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(t, ^{
        s_mainTickMs.store(nowMs());
        UIApplication* app = UIApplication.sharedApplication;
        if (app) s_appState.store(static_cast<int>(app.applicationState));
    });
    dispatch_resume(t);
    pthread_t th;
    pthread_create(&th, nullptr, heartbeatMain, nullptr);
    pthread_detach(th);
}

#endif // TARGET_OS_IOS
