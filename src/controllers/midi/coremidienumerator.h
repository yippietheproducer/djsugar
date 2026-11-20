#pragma once

#include <functional>

#include "controllers/midi/midienumerator.h"
#include "deckx_midi.h"

class CoreMidiController;

/// Lists CoreMIDI devices (iOS). Pairs the input and output endpoints of the
/// same device into one controller. The list is refreshed on every call so
/// devices can be plugged in and out while Mixxx is running.
class CoreMidiEnumerator : public MidiEnumerator {
    Q_OBJECT
  public:
    /// `onHotplug` is called (from any thread) when CoreMIDI reports a change.
    explicit CoreMidiEnumerator(std::function<void()> onHotplug = {});
    ~CoreMidiEnumerator() override;

    QList<Controller*> queryDevices() override;

  private:
    static void hotplugThunk(void* ctx, deckx_midi_event ev, uint32_t uniqueId, int isInput);

    deckx_midi* m_pClient;
    std::function<void()> m_onHotplug;
    QList<CoreMidiController*> m_devices;
    // Unplugged devices are only deleted on shutdown, because the GUI may
    // still hold pointers to them until it processed devicesChanged().
    QList<Controller*> m_removedDevices;
};
