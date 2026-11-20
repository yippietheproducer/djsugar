#include "controllers/midi/coremidicontroller.h"

#include <cstring>

#include "controllers/midi/midiutils.h"
#include "moc_coremidicontroller.cpp"
#include "util/time.h"

namespace {

/// Number of data bytes that follow a status byte
int dataLength(unsigned char status) {
    if (status < 0xF0) {
        switch (status >> 4) {
        case 0xC: // program change
        case 0xD: // channel pressure
            return 1;
        default:
            return 2;
        }
    }
    switch (status) {
    case 0xF1: // MIDI time code quarter frame
    case 0xF3: // Song select
        return 1;
    case 0xF2: // Song position pointer
        return 2;
    default:
        return 0;
    }
}

} // namespace

CoreMidiController::CoreMidiController(deckx_midi* pClient,
        const QString& deviceName,
        const QString& manufacturer,
        const QString& model,
        uint32_t inputId,
        uint32_t outputId)
        : MidiController(deviceName),
          m_pClient(pClient),
          m_pIn(nullptr),
          m_pOut(nullptr),
          m_manufacturer(manufacturer),
          m_model(model),
          m_inputId(inputId),
          m_outputId(outputId),
          m_ring(kRingSize),
          m_dropped(0) {
    setInputDevice(inputId != 0);
    setOutputDevice(outputId != 0);
}

CoreMidiController::~CoreMidiController() {
    if (isOpen()) {
        close();
    }
}

// static, CoreMIDI thread
void CoreMidiController::rxThunk(
        void* ctx, const uint8_t* bytes, size_t len, uint64_t hostTimeNs) {
    auto* self = static_cast<CoreMidiController*>(ctx);
    if (len == 0 || len > kMaxBytes) {
        self->m_dropped.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    RxRecord rec;
    rec.hostTimeNs = hostTimeNs;
    rec.length = static_cast<uint16_t>(len);
    std::memcpy(rec.bytes, bytes, len);
    if (!self->m_ring.try_push(rec)) {
        self->m_dropped.fetch_add(1, std::memory_order_relaxed);
    }
}

int CoreMidiController::open(const QString& resourcePath) {
    if (isOpen()) {
        qCWarning(m_logBase) << "CoreMIDI device" << getName() << "already open";
        return -1;
    }
    while (m_ring.front()) {
        m_ring.pop();
    }
    if (m_inputId != 0) {
        const int rc = deckx_midi_open_input(m_pClient, m_inputId, &CoreMidiController::rxThunk, this, &m_pIn);
        if (rc != 0) {
            qCWarning(m_logBase) << "Unable to open the MIDI input of" << getName()
                                 << deckx_midi_status_name(rc);
            m_pIn = nullptr;
            return -2;
        }
    }
    if (m_outputId != 0) {
        const int rc = deckx_midi_open_output(m_pClient, m_outputId, &m_pOut);
        if (rc != 0) {
            qCWarning(m_logBase) << "Unable to open the MIDI output of" << getName()
                                 << deckx_midi_status_name(rc);
            m_pOut = nullptr;
        }
    }
    if (!m_pIn && !m_pOut) {
        return -2;
    }
    qCInfo(m_logBase) << "Opened CoreMIDI device" << getName()
                      << "input:" << (m_pIn != nullptr) << "output:" << (m_pOut != nullptr);
    // Open before applying the mapping: its init script sends the initial LED states
    setOpen(true);
    startEngine();
    applyMapping(resourcePath);
    return 0;
}

int CoreMidiController::close() {
    if (!isOpen()) {
        qCWarning(m_logBase) << "CoreMIDI device" << getName() << "already closed";
        return -1;
    }
    stopEngine();
    MidiController::close();
    // After close_input returns no rx callback runs any more
    if (m_pIn) {
        deckx_midi_close_input(m_pIn);
        m_pIn = nullptr;
    }
    if (m_pOut) {
        deckx_midi_close_output(m_pOut);
        m_pOut = nullptr;
    }
    setOpen(false);
    const uint32_t dropped = m_dropped.exchange(0);
    if (dropped > 0) {
        qCWarning(m_logBase) << dropped << "MIDI messages were dropped (ring full or SysEx too long)";
    }
    return 0;
}

bool CoreMidiController::poll() {
    bool received = false;
    // Map the CoreMIDI packet time onto Mixxx's clock
    const mixxx::Duration nowMixxx = mixxx::Time::elapsed();
    const uint64_t nowNs = deckx_midi_now_ns();
    while (const RxRecord* pRec = m_ring.front()) {
        const uint64_t ageNs = nowNs > pRec->hostTimeNs ? nowNs - pRec->hostTimeNs : 0;
        const mixxx::Duration ts = nowMixxx - mixxx::Duration::fromNanos(static_cast<qint64>(ageNs));
        const uint8_t status = pRec->bytes[0];
        if (status == 0xF0) {
            receive(QByteArray(reinterpret_cast<const char*>(pRec->bytes), pRec->length), ts);
        } else if (status >= 0x80) {
            const int n = dataLength(status);
            receivedShortMessage(status,
                    n >= 1 && pRec->length > 1 ? pRec->bytes[1] : 0,
                    n >= 2 && pRec->length > 2 ? pRec->bytes[2] : 0,
                    ts);
        }
        m_ring.pop();
        received = true;
    }
    return received;
}

void CoreMidiController::sendShortMsg(
        unsigned char status, unsigned char byte1, unsigned char byte2) {
    if (!m_pOut) {
        return;
    }
    const uint8_t message[3] = {status, byte1, byte2};
    const size_t length = 1 + static_cast<size_t>(dataLength(status));
    const int rc = deckx_midi_send(m_pOut, message, length);
    if (rc != 0) {
        qCWarning(m_logOutput) << "Error sending short message"
                               << MidiUtils::formatMidiOpCode(getName(),
                                          status,
                                          byte1,
                                          byte2,
                                          MidiUtils::channelFromStatus(status),
                                          MidiUtils::opCodeFromStatus(status))
                               << deckx_midi_status_name(rc);
    }
}

bool CoreMidiController::sendBytes(const QByteArray& data) {
    if (!m_pOut || data.isEmpty()) {
        return false;
    }
    const int rc = deckx_midi_send(
            m_pOut, reinterpret_cast<const uint8_t*>(data.constData()), static_cast<size_t>(data.size()));
    if (rc != 0) {
        qCWarning(m_logOutput) << "Error sending SysEx message:"
                               << MidiUtils::formatSysexMessage(getName(), data)
                               << deckx_midi_status_name(rc);
        return false;
    }
    return true;
}
