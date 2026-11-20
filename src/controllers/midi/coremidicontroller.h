#pragma once

#include <atomic>
#include <cstdint>
#include <optional>

#include "controllers/midi/midicontroller.h"
#include "deckx_midi.h"
#include "rigtorp/SPSCQueue.h"

/// MIDI controller over CoreMIDI (iOS), built on the engine-agnostic
/// deckx_midi module. The CoreMIDI thread only pushes raw messages into a
/// lock-free SPSC ring; poll() drains it on Mixxx's controller thread.
class CoreMidiController : public MidiController {
    Q_OBJECT
  public:
    /// `inputId` / `outputId` are CoreMIDI unique ids, 0 = no such endpoint.
    CoreMidiController(deckx_midi* pClient,
            const QString& deviceName,
            const QString& manufacturer,
            const QString& model,
            uint32_t inputId,
            uint32_t outputId);
    ~CoreMidiController() override;

    uint32_t inputId() const {
        return m_inputId;
    }
    uint32_t outputId() const {
        return m_outputId;
    }

    PhysicalTransportProtocol getPhysicalTransportProtocol() const override {
        return PhysicalTransportProtocol::USB;
    }
    QString getVendorString() const override {
        return m_manufacturer;
    }
    QString getProductString() const override {
        return m_model;
    }
    std::optional<uint16_t> getVendorId() const override {
        return std::nullopt;
    }
    std::optional<uint16_t> getProductId() const override {
        return std::nullopt;
    }
    QString getSerialNumber() const override {
        return QString();
    }
    std::optional<uint8_t> getUsbInterfaceNumber() const override {
        return std::nullopt;
    }

  private slots:
    bool poll() override;

  protected:
    void sendShortMsg(unsigned char status,
            unsigned char byte1,
            unsigned char byte2) override;

  private:
    // One complete message as delivered by deckx_midi. Messages longer than
    // kMaxBytes (SysEx) are dropped on the CoreMIDI thread and counted.
    static constexpr size_t kMaxBytes = 256;
    struct RxRecord {
        uint64_t hostTimeNs;
        uint16_t length;
        uint8_t bytes[kMaxBytes];
    };
    static constexpr size_t kRingSize = 1024;

    // CoreMIDI thread. No Qt, no locks, no allocation.
    static void rxThunk(void* ctx, const uint8_t* bytes, size_t len, uint64_t hostTimeNs);

    int open(const QString& resourcePath) override;
    int close() override;
    bool sendBytes(const QByteArray& data) override;
    bool isPolling() const override {
        return true;
    }

    deckx_midi* m_pClient;
    deckx_midi_in* m_pIn;
    deckx_midi_out* m_pOut;
    QString m_manufacturer;
    QString m_model;
    uint32_t m_inputId;
    uint32_t m_outputId;
    rigtorp::SPSCQueue<RxRecord> m_ring;
    std::atomic<uint32_t> m_dropped;
};
