#include "controllers/midi/coremidienumerator.h"

#include <QMap>
#include <QSet>
#include <QString>
#include <vector>

#include "controllers/midi/coremidicontroller.h"
#include "moc_coremidienumerator.cpp"

namespace {

struct Pair {
    QString name;
    QString manufacturer;
    QString model;
    uint32_t in = 0;
    uint32_t out = 0;
};

} // namespace

CoreMidiEnumerator::CoreMidiEnumerator(std::function<void()> onHotplug)
        : m_pClient(nullptr),
          m_onHotplug(std::move(onHotplug)) {
    const int rc = deckx_midi_create("Mixxx", &CoreMidiEnumerator::hotplugThunk, this, &m_pClient);
    if (rc != 0) {
        qWarning() << "CoreMIDI client creation failed:" << deckx_midi_status_name(rc);
        m_pClient = nullptr;
    }
}

CoreMidiEnumerator::~CoreMidiEnumerator() {
    qDebug() << "Deleting CoreMIDI devices...";
    qDeleteAll(m_devices);
    m_devices.clear();
    qDeleteAll(m_removedDevices);
    m_removedDevices.clear();
    if (m_pClient) {
        deckx_midi_destroy(m_pClient);
        m_pClient = nullptr;
    }
}

// static; runs on the run loop of the thread that created the client
void CoreMidiEnumerator::hotplugThunk(void* ctx, deckx_midi_event, uint32_t, int) {
    auto* self = static_cast<CoreMidiEnumerator*>(ctx);
    if (self->m_onHotplug) {
        self->m_onHotplug();
    }
}

QList<Controller*> CoreMidiEnumerator::queryDevices() {
    if (!m_pClient) {
        return {};
    }
    std::vector<deckx_midi_endpoint> eps(64);
    int total = deckx_midi_list(m_pClient, eps.data(), static_cast<int>(eps.size()));
    if (total > static_cast<int>(eps.size())) {
        eps.resize(static_cast<size_t>(total));
        total = deckx_midi_list(m_pClient, eps.data(), static_cast<int>(eps.size()));
    }
    eps.resize(static_cast<size_t>(qMin(total, static_cast<int>(eps.size()))));

    // Pair the n-th input with the n-th output of the same name
    QMap<QString, QList<Pair>> byName;
    for (const auto& ep : eps) {
        if (!ep.online) {
            continue;
        }
        const QString name = QString::fromUtf8(ep.name);
        QList<Pair>& list = byName[name];
        Pair* pPair = nullptr;
        for (auto& p : list) {
            if ((ep.is_input ? p.in : p.out) == 0) {
                pPair = &p;
                break;
            }
        }
        if (!pPair) {
            list.append(Pair{name,
                    QString::fromUtf8(ep.manufacturer),
                    QString::fromUtf8(ep.model),
                    0,
                    0});
            pPair = &list.last();
        }
        (ep.is_input ? pPair->in : pPair->out) = ep.unique_id;
    }

    QSet<QString> usedNames;
    for (const auto* pDevice : std::as_const(m_devices)) {
        usedNames.insert(pDevice->getName());
    }
    QSet<uint64_t> present;
    for (auto it = byName.cbegin(); it != byName.cend(); ++it) {
        for (const Pair& p : it.value()) {
            const uint64_t key = (static_cast<uint64_t>(p.in) << 32) | p.out;
            present.insert(key);
            const bool known = std::any_of(m_devices.cbegin(),
                    m_devices.cend(),
                    [&](const CoreMidiController* c) {
                        return c->inputId() == p.in && c->outputId() == p.out;
                    });
            if (known) {
                continue;
            }
            QString name = p.name;
            for (int n = 2; usedNames.contains(name); ++n) {
                name = QStringLiteral("%1 #%2").arg(p.name, QString::number(n));
            }
            usedNames.insert(name);
            qInfo() << "Found CoreMIDI device:" << name << "in" << p.in << "out" << p.out;
            m_devices.append(new CoreMidiController(
                    m_pClient, name, p.manufacturer, p.model, p.in, p.out));
        }
    }

    for (int i = m_devices.size() - 1; i >= 0; --i) {
        CoreMidiController* pDevice = m_devices.at(i);
        const uint64_t key =
                (static_cast<uint64_t>(pDevice->inputId()) << 32) | pDevice->outputId();
        if (present.contains(key)) {
            continue;
        }
        // ControllerManager closes controllers that disappeared from the list
        qInfo() << "CoreMIDI device removed:" << pDevice->getName();
        m_devices.removeAt(i);
        m_removedDevices.append(pDevice);
    }

    QList<Controller*> result;
    result.reserve(m_devices.size());
    for (auto* pDevice : std::as_const(m_devices)) {
        result.append(pDevice);
    }
    return result;
}
