// deckx: Qt 6.12's futex code (QSemaphore/QMutex/QWaitCondition on Apple) calls os_sync_wait_on_address & co.
// Those exist only from iOS 17.4; on iOS 16 the weak import is NULL and the first contended QSemaphore::acquire
// jumps to address 0 (SIGSEGV pc=0, seen on iPhone X / iOS 16.7.12, CachingReaderWorker thread).
// Defining the symbols in the executable makes the linker bind Qt's references here instead of to libSystem.
// Backed by __ulock_*, which is what the real implementation uses and which libsystem_kernel exports since iOS 10.
#include <cerrno>
#include <cstddef>
#include <cstdint>

extern "C" {
int __ulock_wait(uint32_t operation, void* addr, uint64_t value, uint32_t timeout_us);
int __ulock_wake(uint32_t operation, void* addr, uint64_t wake_value);
}

namespace {
constexpr uint32_t UL_COMPARE_AND_WAIT = 1;
constexpr uint32_t UL_COMPARE_AND_WAIT_SHARED = 3;
constexpr uint32_t UL_COMPARE_AND_WAIT64 = 5;
constexpr uint32_t UL_COMPARE_AND_WAIT64_SHARED = 7;
constexpr uint32_t ULF_WAKE_ALL = 0x100;
constexpr uint32_t ULF_NO_ERRNO = 0x01000000;
constexpr uint32_t OS_SYNC_SHARED = 1; // OS_SYNC_*_ADDRESS_SHARED

uint32_t waitOp(size_t size, uint32_t flags) {
    const bool shared = flags & OS_SYNC_SHARED;
    if (size == 8) return (shared ? UL_COMPARE_AND_WAIT64_SHARED : UL_COMPARE_AND_WAIT64) | ULF_NO_ERRNO;
    return (shared ? UL_COMPARE_AND_WAIT_SHARED : UL_COMPARE_AND_WAIT) | ULF_NO_ERRNO;
}

int doWait(void* addr, uint64_t value, size_t size, uint32_t flags, uint32_t timeoutUs) {
    if (size != 4 && size != 8) { errno = EINVAL; return -1; }
    const int rc = __ulock_wait(waitOp(size, flags), addr, value, timeoutUs);
    if (rc < 0) { errno = -rc; return -1; }
    return rc; // number of remaining waiters
}

int doWake(void* addr, size_t size, uint32_t flags, bool all) {
    if (size != 4 && size != 8) { errno = EINVAL; return -1; }
    uint32_t op = waitOp(size, flags) | (all ? ULF_WAKE_ALL : 0);
    const int rc = __ulock_wake(op, addr, 0);
    if (rc < 0) { errno = -rc; return -1; }
    return 0;
}
} // namespace

extern "C" {
__attribute__((visibility("default"))) int os_sync_wait_on_address(
        void* addr, uint64_t value, size_t size, uint32_t flags) {
    return doWait(addr, value, size, flags, 0);
}

__attribute__((visibility("default"))) int os_sync_wait_on_address_with_timeout(
        void* addr, uint64_t value, size_t size, uint32_t flags, uint32_t /*clockid*/, uint64_t timeoutNs) {
    uint64_t us = (timeoutNs + 999) / 1000;
    if (us == 0) us = 1; // 0 would mean "forever" for __ulock_wait
    if (us > UINT32_MAX) us = UINT32_MAX;
    return doWait(addr, value, size, flags, static_cast<uint32_t>(us));
}

__attribute__((visibility("default"))) int os_sync_wake_by_address_any(void* addr, size_t size, uint32_t flags) {
    return doWake(addr, size, flags, false);
}

__attribute__((visibility("default"))) int os_sync_wake_by_address_all(void* addr, size_t size, uint32_t flags) {
    return doWake(addr, size, flags, true);
}
}
