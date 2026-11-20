/* deckx_midi — CoreMIDI transport with a plain C ABI (macOS + iOS). No host types.
 *
 * THREADING CONTRACT
 *  - All functions may be called from any thread EXCEPT: deckx_midi_destroy / *_close must not be
 *    called from inside a callback of the same object (deadlock/UB).
 *  - Receive callback (deckx_midi_rx_fn): called on a CoreMIDI-owned, high-priority thread, never the
 *    caller's. It may NOT block, take locks, allocate, or call deckx_midi_close/destroy. It may copy
 *    bytes into a lock-free ring. `bytes` is valid only during the call. One call = one complete
 *    message (short message of 1-3 bytes, or a whole SysEx F0..F7 reassembled across packets;
 *    SysEx > DECKX_MIDI_MAX_SYSEX bytes is dropped). Realtime bytes (F8..FF) are delivered on their own.
 *  - host_time_ns: packet timestamp (mach host time, in ns, same clock as mach_absolute_time scaled);
 *    taken from the packet, not from arrival. For SysEx it is the timestamp of the first packet.
 *  - Hotplug callback (deckx_midi_hotplug_fn): delivered via the run loop of the thread that called
 *    deckx_midi_create. That thread must run its CFRunLoop (iOS/macOS main thread does; a CLI must call
 *    deckx_midi_pump). Callback may call deckx_midi_list/open; must not call destroy.
 *  - After deckx_midi_close_input returns, no further rx callbacks for that input occur.
 * Return values: 0 = ok, else the CoreMIDI OSStatus; deckx_midi_status_name() gives its name. */
#ifndef DECKX_MIDI_H
#define DECKX_MIDI_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define DECKX_MIDI_MAX_SYSEX 65536

typedef struct deckx_midi deckx_midi;           /* client */
typedef struct deckx_midi_in deckx_midi_in;     /* open input  (a CoreMIDI source we listen to) */
typedef struct deckx_midi_out deckx_midi_out;   /* open output (a CoreMIDI destination we send to) */

typedef struct {
    uint32_t unique_id;     /* kMIDIPropertyUniqueID; stable across replug for real devices */
    int      is_input;      /* 1 = source (device -> us), 0 = destination (us -> device) */
    int      online;        /* 0 if kMIDIPropertyOffline */
    char     name[128];     /* display name */
    char     manufacturer[64];
    char     model[64];
} deckx_midi_endpoint;

typedef enum { DECKX_MIDI_ADDED = 1, DECKX_MIDI_REMOVED = 2, DECKX_MIDI_CHANGED = 3 } deckx_midi_event;

typedef void (*deckx_midi_rx_fn)(void *ctx, const uint8_t *bytes, size_t len, uint64_t host_time_ns);
typedef void (*deckx_midi_hotplug_fn)(void *ctx, deckx_midi_event ev, uint32_t unique_id, int is_input);

int  deckx_midi_create(const char *client_name, deckx_midi_hotplug_fn hp, void *hp_ctx, deckx_midi **out);
void deckx_midi_destroy(deckx_midi *m);  /* closes nothing: close all in/out first */
void deckx_midi_pump(double seconds);    /* run the calling thread's CFRunLoop for <= seconds (CLI/tests) */

/* Fills up to `max` entries; returns total endpoint count (may exceed max). */
int  deckx_midi_list(deckx_midi *m, deckx_midi_endpoint *out, int max);

int  deckx_midi_open_input(deckx_midi *m, uint32_t unique_id, deckx_midi_rx_fn cb, void *ctx, deckx_midi_in **out);
void deckx_midi_close_input(deckx_midi_in *in);
int  deckx_midi_open_output(deckx_midi *m, uint32_t unique_id, deckx_midi_out **out);
void deckx_midi_close_output(deckx_midi_out *o);

/* One short message (1-3 bytes) or one SysEx (F0..F7). Sent immediately. Any thread; may allocate for
 * messages > 256 bytes, so not for the render thread. */
int  deckx_midi_send(deckx_midi_out *o, const uint8_t *bytes, size_t len);

uint64_t    deckx_midi_now_ns(void);               /* same clock as host_time_ns */
const char *deckx_midi_status_name(int32_t status); /* "kMIDIUnknownEndpoint" etc, "OSStatus -123" if unknown */

#ifdef __cplusplus
}
#endif
#endif
