// Flat C bridge over pjsua-lib for desktop SIP trunk operation.
//
// This translation unit is always compiled into native_core so the FFI
// surface (maxima_sip_*) is stable across platforms and builds. When the
// project is configured with -DMAXIMA_WITH_PJSIP=ON and a pjsua library
// is found, the real implementation is used; otherwise every entry point
// returns MAXIMA_SIP_UNAVAILABLE so callers can degrade cleanly.
//
// Error contract (all functions):
//     >= 0 : success (call/account handles are >= 0)
//     -1   : generic failure (pj_status_t errors are mapped to -1)
//     -2   : PJSIP not compiled in (MAXIMA_SIP_UNAVAILABLE)
//     -3   : invalid arguments
//
// The bridge is intentionally small: register one account, place one call,
// hang up. Multi-call conferencing is out of scope for the trunk client.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>

#if defined(MAXIMA_WITH_PJSIP)
#include <pjsua-lib/pjsua.h>
#endif

#if defined(_MSC_VER)
#  define MAXIMA_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#  define MAXIMA_EXPORT __attribute__((visibility("default")))
#else
#  define MAXIMA_EXPORT
#endif

namespace {

constexpr int kMaximaSipOk = 0;
constexpr int kMaximaSipError = -1;
constexpr int kMaximaSipUnavailable = -2;
constexpr int kMaximaSipBadArgs = -3;

constexpr int kTransportUdp = 0;
constexpr int kTransportTls = 1;

std::atomic<bool> g_started{false};
std::atomic<int> g_accId{-1};
std::atomic<int> g_callId{-1};

#if defined(MAXIMA_WITH_PJSIP)

pj_str_t pjStr(const char* s) {
    pj_str_t out;
    out.ptr = const_cast<char*>(s);
    out.slen = static_cast<pj_ssize_t>(std::strlen(s));
    return out;
}

#endif

}  // namespace

extern "C" {

// transport: 0 = UDP, 1 = TLS. localPort: 0 = ephemeral.
MAXIMA_EXPORT int maxima_sip_init(int transport, int localPort) {
#if defined(MAXIMA_WITH_PJSIP)
    if (g_started.load()) {
        return kMaximaSipOk;
    }

    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) {
        return kMaximaSipError;
    }

    pjsua_config cfg;
    pjsua_config_default(&cfg);
    cfg.max_calls = 4;
    cfg.thread_cnt = 1;

    pjsua_logging_config log_cfg;
    pjsua_logging_config_default(&log_cfg);
    log_cfg.msg_logging = PJ_TRUE;
    log_cfg.level = 3;
    log_cfg.console_level = 3;

    pjsua_media_config med_cfg;
    pjsua_media_config_default(&med_cfg);
    med_cfg.clock_rate = 16000;
    med_cfg.snd_clock_rate = 0;         // use platform default playback rate
    med_cfg.no_vad = PJ_FALSE;
    med_cfg.ec_tail_len = 200;          // ms of acoustic echo tail

    status = pjsua_init(&cfg, &log_cfg, &med_cfg);
    if (status != PJ_SUCCESS) {
        pjsua_destroy();
        return kMaximaSipError;
    }

    pjsua_transport_config tcfg;
    pjsua_transport_config_default(&tcfg);
    tcfg.port = localPort > 0 ? static_cast<unsigned>(localPort) : 0;

    const pjsip_transport_type_e type =
        transport == kTransportTls ? PJSIP_TRANSPORT_TLS : PJSIP_TRANSPORT_UDP;
    status = pjsua_transport_create(type, &tcfg, nullptr);
    if (status != PJ_SUCCESS) {
        pjsua_destroy();
        return kMaximaSipError;
    }

    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        pjsua_destroy();
        return kMaximaSipError;
    }

    g_started.store(true);
    return kMaximaSipOk;
#else
    (void)transport;
    (void)localPort;
    return kMaximaSipUnavailable;
#endif
}

// Registers a digest-auth account. callerId, when non-empty, becomes the
// From display name: "callerId" <sip:user@domain>.
MAXIMA_EXPORT int maxima_sip_register(const char* user, const char* domain,
                                    const char* password, const char* callerId) {
#if defined(MAXIMA_WITH_PJSIP)
    if (!g_started.load() || user == nullptr || domain == nullptr ||
        password == nullptr) {
        return g_started.load() ? kMaximaSipBadArgs : kMaximaSipError;
    }

    pjsua_acc_config acfg;
    pjsua_acc_config_default(&acfg);

    char id_buf[320];
    char reg_buf[256];
    if (callerId != nullptr && callerId[0] != '\0') {
        std::snprintf(id_buf, sizeof(id_buf), "\"%s\" <sip:%s@%s>",
                      callerId, user, domain);
    } else {
        std::snprintf(id_buf, sizeof(id_buf), "sip:%s@%s", user, domain);
    }
    std::snprintf(reg_buf, sizeof(reg_buf), "sip:%s", domain);

    acfg.id = pjStr(id_buf);
    acfg.reg_uri = pjStr(reg_buf);
    acfg.register_on_acc_add = PJ_TRUE;
    acfg.cred_count = 1;
    acfg.cred_info[0].realm = pjStr("*");
    acfg.cred_info[0].scheme = pjStr("digest");
    acfg.cred_info[0].username = pjStr(user);
    acfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acfg.cred_info[0].data = pjStr(password);

    pjsua_acc_id acc_id = PJSUA_INVALID_ID;
    const pj_status_t status = pjsua_acc_add(&acfg, PJ_TRUE, &acc_id);
    if (status != PJ_SUCCESS) {
        return kMaximaSipError;
    }

    g_accId.store(static_cast<int>(acc_id));
    return static_cast<int>(acc_id);
#else
    (void)user;
    (void)domain;
    (void)password;
    (void)callerId;
    return kMaximaSipUnavailable;
#endif
}

// Places an outbound call on the registered account. sipUri may be a bare
// number (dialled through the registered domain) or a full sip: URI.
MAXIMA_EXPORT int maxima_sip_call(const char* sipUri) {
#if defined(MAXIMA_WITH_PJSIP)
    const int acc = g_accId.load();
    if (!g_started.load() || acc < 0 || sipUri == nullptr) {
        return g_started.load() ? kMaximaSipBadArgs : kMaximaSipError;
    }

    pj_str_t dst = pjStr(sipUri);
    pjsua_call_id call_id = PJSUA_INVALID_ID;
    const pj_status_t status = pjsua_call_make_call(
        static_cast<pjsua_acc_id>(acc), &dst, 0, nullptr, nullptr, &call_id);
    if (status != PJ_SUCCESS) {
        return kMaximaSipError;
    }

    g_callId.store(static_cast<int>(call_id));
    return static_cast<int>(call_id);
#else
    (void)sipUri;
    return kMaximaSipUnavailable;
#endif
}

MAXIMA_EXPORT int maxima_sip_hangup(int callId) {
#if defined(MAXIMA_WITH_PJSIP)
    if (!g_started.load() || callId < 0) {
        return kMaximaSipBadArgs;
    }
    const pj_status_t status = pjsua_call_hangup(
        static_cast<pjsua_call_id>(callId), 0, nullptr, nullptr);
    g_callId.store(-1);
    return status == PJ_SUCCESS ? kMaximaSipOk : kMaximaSipError;
#else
    (void)callId;
    return kMaximaSipUnavailable;
#endif
}

// 1 = registered (200), 0 = not yet/failed, -2 = unavailable.
MAXIMA_EXPORT int maxima_sip_registered() {
#if defined(MAXIMA_WITH_PJSIP)
    const int acc = g_accId.load();
    if (!g_started.load() || acc < 0) {
        return g_started.load() ? 0 : kMaximaSipError;
    }
    pjsua_acc_info info;
    if (pjsua_acc_get_info(static_cast<pjsua_acc_id>(acc), &info) != PJ_SUCCESS) {
        return kMaximaSipError;
    }
    return info.status == PJSIP_SC_OK ? 1 : 0;
#else
    return kMaximaSipUnavailable;
#endif
}

MAXIMA_EXPORT int maxima_sip_shutdown() {
#if defined(MAXIMA_WITH_PJSIP)
    if (!g_started.load()) {
        return kMaximaSipOk;
    }
    g_accId.store(-1);
    g_callId.store(-1);
    g_started.store(false);
    pjsua_destroy();
    return kMaximaSipOk;
#else
    return kMaximaSipUnavailable;
#endif
}

}
