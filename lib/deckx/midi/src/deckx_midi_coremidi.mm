// CoreMIDI implementation of deckx_midi.h. No globals.
#include "deckx_midi.h"
#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct deckx_midi {
    MIDIClientRef client;
    deckx_midi_hotplug_fn hp;
    void *hp_ctx;
};

struct deckx_midi_in {
    MIDIPortRef port;
    MIDIEndpointRef src;
    deckx_midi_rx_fn cb;
    void *ctx;
    // byte-stream parser state (touched only on the CoreMIDI read thread)
    uint8_t msg[3]; int have, need; uint8_t running;
    bool in_sx; bool sx_over; size_t sx_len; uint64_t sx_ts;
    uint8_t *sx;  // DECKX_MIDI_MAX_SYSEX, allocated at open
};

struct deckx_midi_out {
    MIDIPortRef port;
    MIDIEndpointRef dst;
};

static uint64_t to_ns(uint64_t t) {
    static_assert(sizeof(mach_timebase_info_data_t) > 0, "");
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);  // cheap, no allocation
    return t * tb.numer / tb.denom;
}
uint64_t deckx_midi_now_ns(void) { return to_ns(mach_absolute_time()); }

const char *deckx_midi_status_name(int32_t s) {
    static thread_local char buf[32];
    switch (s) {
    case 0: return "noErr";
    case kMIDIInvalidClient: return "kMIDIInvalidClient";
    case kMIDIInvalidPort: return "kMIDIInvalidPort";
    case kMIDIWrongEndpointType: return "kMIDIWrongEndpointType";
    case kMIDINoConnection: return "kMIDINoConnection";
    case kMIDIUnknownEndpoint: return "kMIDIUnknownEndpoint";
    case kMIDIUnknownProperty: return "kMIDIUnknownProperty";
    case kMIDIWrongPropertyType: return "kMIDIWrongPropertyType";
    case kMIDINoCurrentSetup: return "kMIDINoCurrentSetup";
    case kMIDIMessageSendErr: return "kMIDIMessageSendErr";
    case kMIDIServerStartErr: return "kMIDIServerStartErr";
    case kMIDISetupFormatErr: return "kMIDISetupFormatErr";
    case kMIDIWrongThread: return "kMIDIWrongThread";
    case kMIDIObjectNotFound: return "kMIDIObjectNotFound";
    case kMIDIIDNotUnique: return "kMIDIIDNotUnique";
    case kMIDINotPermitted: return "kMIDINotPermitted";
    case -50: return "paramErr";
    }
    snprintf(buf, sizeof buf, "OSStatus %d", (int)s);
    return buf;
}

static void cfs(MIDIObjectRef o, CFStringRef prop, char *dst, size_t n) {
    dst[0] = 0; CFStringRef s = NULL;
    if (MIDIObjectGetStringProperty(o, prop, &s) == noErr && s) {
        CFStringGetCString(s, dst, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(s);
    }
}
static uint32_t uid_of(MIDIObjectRef o) { SInt32 v = 0; MIDIObjectGetIntegerProperty(o, kMIDIPropertyUniqueID, &v); return (uint32_t)v; }

static void fill(MIDIEndpointRef e, int is_in, deckx_midi_endpoint *d) {
    memset(d, 0, sizeof *d);
    d->unique_id = uid_of(e); d->is_input = is_in;
    SInt32 off = 0; MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &off); d->online = !off;
    cfs(e, kMIDIPropertyDisplayName, d->name, sizeof d->name);
    cfs(e, kMIDIPropertyManufacturer, d->manufacturer, sizeof d->manufacturer);
    cfs(e, kMIDIPropertyModel, d->model, sizeof d->model);
}

static void notify(const MIDINotification *n, void *refCon) {
    deckx_midi *m = (deckx_midi *)refCon;
    if (!m->hp) return;
    deckx_midi_event ev;
    if (n->messageID == kMIDIMsgObjectAdded || n->messageID == kMIDIMsgObjectRemoved) {
        const MIDIObjectAddRemoveNotification *a = (const MIDIObjectAddRemoveNotification *)n;
        if (a->childType != kMIDIObjectType_Source && a->childType != kMIDIObjectType_Destination) return;
        ev = n->messageID == kMIDIMsgObjectAdded ? DECKX_MIDI_ADDED : DECKX_MIDI_REMOVED;
        m->hp(m->hp_ctx, ev, uid_of(a->child), a->childType == kMIDIObjectType_Source);
    } else if (n->messageID == kMIDIMsgPropertyChanged) {
        const MIDIObjectPropertyChangeNotification *p = (const MIDIObjectPropertyChangeNotification *)n;
        if (p->objectType != kMIDIObjectType_Source && p->objectType != kMIDIObjectType_Destination) return;
        m->hp(m->hp_ctx, DECKX_MIDI_CHANGED, uid_of(p->object), p->objectType == kMIDIObjectType_Source);
    }
}

int deckx_midi_create(const char *name, deckx_midi_hotplug_fn hp, void *hp_ctx, deckx_midi **out) {
    if (!out) return -50;
    deckx_midi *m = (deckx_midi *)calloc(1, sizeof *m);
    m->hp = hp; m->hp_ctx = hp_ctx;
    CFStringRef n = CFStringCreateWithCString(NULL, name ? name : "deckx", kCFStringEncodingUTF8);
    OSStatus s = MIDIClientCreate(n, notify, m, &m->client);
    CFRelease(n);
    if (s) { free(m); return (int)s; }
    *out = m; return 0;
}
void deckx_midi_destroy(deckx_midi *m) { if (!m) return; MIDIClientDispose(m->client); free(m); }
void deckx_midi_pump(double sec) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, sec, false); }

int deckx_midi_list(deckx_midi *, deckx_midi_endpoint *out, int max) {
    int total = 0;
    for (int dir = 1; dir >= 0; --dir) {
        ItemCount c = dir ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
        for (ItemCount i = 0; i < c; ++i) {
            MIDIEndpointRef e = dir ? MIDIGetSource(i) : MIDIGetDestination(i);
            if (out && total < max) fill(e, dir, &out[total]);
            ++total;
        }
    }
    return total;
}

static MIDIEndpointRef find(uint32_t uid, bool source) {
    MIDIObjectRef o = 0; MIDIObjectType t;
    if (MIDIObjectFindByUniqueID((MIDIUniqueID)uid, &o, &t) != noErr) return 0;
    if (source ? t != kMIDIObjectType_Source : t != kMIDIObjectType_Destination) return 0;
    return (MIDIEndpointRef)o;
}

// ---- receive path: no allocation, no locks ----
static inline void emit(deckx_midi_in *in, const uint8_t *b, size_t n, uint64_t ts) { in->cb(in->ctx, b, n, ts); }

static void feed(deckx_midi_in *in, uint8_t b, uint64_t ts) {
    if (b >= 0xF8) { emit(in, &b, 1, ts); return; }              // realtime: never disturbs state
    if (b == 0xF0) { in->in_sx = true; in->sx_over = false; in->sx_len = 0; in->sx_ts = ts; in->sx[in->sx_len++] = b; in->have = 0; in->running = 0; return; }
    if (in->in_sx) {
        if (b < 0x80) { if (in->sx_len < DECKX_MIDI_MAX_SYSEX) in->sx[in->sx_len++] = b; else in->sx_over = true; return; }
        if (b == 0xF7) { in->in_sx = false; if (!in->sx_over && in->sx_len < DECKX_MIDI_MAX_SYSEX) { in->sx[in->sx_len++] = b; emit(in, in->sx, in->sx_len, in->sx_ts); } return; }
        in->in_sx = false;  // any other status aborts the SysEx
    }
    if (b & 0x80) {
        in->have = 0;
        if (b >= 0xF0) {
            in->running = 0;
            if (b == 0xF6) { emit(in, &b, 1, ts); return; }
            in->need = (b == 0xF1 || b == 0xF3) ? 2 : (b == 0xF2 ? 3 : 0);
            if (!in->need) return;
        } else { in->running = b; in->need = (b >= 0xC0 && b < 0xE0) ? 2 : 3; }
        in->msg[in->have++] = b; return;
    }
    if (!in->have) { if (!in->running) return; in->msg[0] = in->running; in->have = 1; in->need = (in->running >= 0xC0 && in->running < 0xE0) ? 2 : 3; }
    in->msg[in->have++] = b;
    if (in->have == in->need) { emit(in, in->msg, (size_t)in->need, ts); in->have = 0; }
}

static void readproc(const MIDIPacketList *pl, void *refCon, void *) {
    deckx_midi_in *in = (deckx_midi_in *)refCon;
    const MIDIPacket *p = &pl->packet[0];
    for (UInt32 i = 0; i < pl->numPackets; ++i) {
        uint64_t ts = to_ns(p->timeStamp ? p->timeStamp : mach_absolute_time());
        for (UInt16 j = 0; j < p->length; ++j) feed(in, p->data[j], ts);
        p = MIDIPacketNext(p);
    }
}

int deckx_midi_open_input(deckx_midi *m, uint32_t uid, deckx_midi_rx_fn cb, void *ctx, deckx_midi_in **out) {
    if (!m || !cb || !out) return -50;
    MIDIEndpointRef src = find(uid, true);
    if (!src) return kMIDIUnknownEndpoint;
    deckx_midi_in *in = (deckx_midi_in *)calloc(1, sizeof *in);
    in->sx = (uint8_t *)malloc(DECKX_MIDI_MAX_SYSEX); in->cb = cb; in->ctx = ctx; in->src = src;
    CFStringRef n = CFSTR("deckx-in");
    OSStatus s = MIDIInputPortCreate(m->client, n, readproc, in, &in->port);
    if (!s) s = MIDIPortConnectSource(in->port, src, NULL);
    if (s) { if (in->port) MIDIPortDispose(in->port); free(in->sx); free(in); return (int)s; }
    *out = in; return 0;
}
void deckx_midi_close_input(deckx_midi_in *in) {
    if (!in) return;
    MIDIPortDisconnectSource(in->port, in->src);
    MIDIPortDispose(in->port);   // synchronous: no callbacks after this returns
    free(in->sx); free(in);
}

int deckx_midi_open_output(deckx_midi *m, uint32_t uid, deckx_midi_out **out) {
    if (!m || !out) return -50;
    MIDIEndpointRef d = find(uid, false);
    if (!d) return kMIDIUnknownEndpoint;
    deckx_midi_out *o = (deckx_midi_out *)calloc(1, sizeof *o); o->dst = d;
    OSStatus s = MIDIOutputPortCreate(m->client, CFSTR("deckx-out"), &o->port);
    if (s) { free(o); return (int)s; }
    *out = o; return 0;
}
void deckx_midi_close_output(deckx_midi_out *o) { if (!o) return; MIDIPortDispose(o->port); free(o); }

int deckx_midi_send(deckx_midi_out *o, const uint8_t *b, size_t len) {
    if (!o || !b || !len || len > 65000) return -50;
    uint8_t stack[512]; uint8_t *buf = stack; size_t cap = sizeof stack;
    if (len + 32 > cap) { cap = len + 32; buf = (uint8_t *)malloc(cap); }
    MIDIPacketList *pl = (MIDIPacketList *)buf;
    MIDIPacket *p = MIDIPacketListInit(pl);
    p = MIDIPacketListAdd(pl, cap, p, 0, len, b);
    OSStatus s = p ? MIDISend(o->port, o->dst, pl) : -50;
    if (buf != stack) free(buf);
    return (int)s;
}
