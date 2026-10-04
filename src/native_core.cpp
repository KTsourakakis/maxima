#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

#if defined(_MSC_VER)
#  define MAXIMA_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#  define MAXIMA_EXPORT __attribute__((visibility("default")))
#else
#  define MAXIMA_EXPORT
#endif

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#elif defined(__APPLE__)
#  include <sys/proc.h>
#  include <sys/sysctl.h>
#  include <unistd.h>
#endif

struct alignas(64) FinKey {
    unsigned char k[32];
    std::atomic<bool> v;
};

static FinKey g_key = {{0}, false};
static_assert(alignof(FinKey) == 64, "FinKey must align to a 64-byte cache line");
static_assert(sizeof(FinKey) <= 64, "FinKey must fit inside one 64-byte cache line");

static void volatileZeroKey() {
    volatile unsigned char* p = g_key.k;
    for (std::size_t i = 0; i < sizeof(g_key.k); ++i) {
        p[i] = 0;
    }
}

static std::uint64_t cacheZeroBlockSize() {
#if defined(__aarch64__)
    std::uint64_t dczid = 0;
    asm volatile("mrs %0, dczid_el0" : "=r"(dczid));
    if ((dczid & (1ULL << 4)) != 0) {
        return 0;
    }
    return 4ULL << (dczid & 0xFULL);
#else
    return 0;
#endif
}

static bool zeroKeyCacheLine() {
#if defined(__aarch64__)
    const std::uint64_t blockSize = cacheZeroBlockSize();
    const std::uintptr_t address = reinterpret_cast<std::uintptr_t>(g_key.k);
    if (blockSize == 64 && (address & 63U) == 0) {
        asm volatile("dc zva, %0" :: "r"(address) : "memory");
        asm volatile("dsb ish" ::: "memory");
        asm volatile("isb" ::: "memory");
        return true;
    }
#endif
    return false;
}

static std::uint64_t counterNow() {
#if defined(__aarch64__)
    std::uint64_t value = 0;
    asm volatile("mrs %0, cntvct_el0" : "=r"(value));
    return value;
#else
    return static_cast<std::uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count()
    );
#endif
}

static std::uint64_t counterFrequency() {
#if defined(__aarch64__)
    std::uint64_t value = 0;
    asm volatile("mrs %0, cntfrq_el0" : "=r"(value));
    return value;
#else
    using Period = std::chrono::steady_clock::period;
    return static_cast<std::uint64_t>(Period::den / Period::num);
#endif
}

static bool debuggerDetected() {
#if defined(__linux__) || defined(__ANDROID__)
    std::ifstream status("/proc/self/status");
    std::string key;
    while (status >> key) {
        if (key == "TracerPid:") {
            int tracerPid = 0;
            status >> tracerPid;
            return tracerPid != 0;
        }
        status.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
    }
#elif defined(_WIN32)
    return IsDebuggerPresent() != 0;
#elif defined(__APPLE__)
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info{};
    std::size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, nullptr, 0) == 0) {
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    }
#endif
    return false;
}

// ---------------------------------------------------------------------------
// Lightweight spectral voice-print engine
//
// Derives a 22-dimension fingerprint per capture: per-frame log band
// energies (8 Goertzel probes), log-RMS, zero-crossing rate and a coarse
// spectral centroid, reduced to mean+stddev over the capture. Enrollment
// averages multiple captures; verification compares cosine similarity.
// This is a biometric gate, not a forensic speaker model.
// ---------------------------------------------------------------------------

static constexpr int kVoiceSampleRate = 16000;
static constexpr int kVoiceFrame = 400;   // 25 ms
static constexpr int kVoiceHop = 200;     // 50% overlap
static constexpr int kVoiceBands = 8;
static constexpr int kVoiceScalarFeats = 3;  // logRMS, ZCR, centroid
static constexpr int kVoiceDims = (kVoiceBands + kVoiceScalarFeats) * 2;
static constexpr int kMaxEnrollVectors = 32;
static constexpr double kProbeFreqs[kVoiceBands] = {
    200.0, 500.0, 900.0, 1400.0, 2000.0, 2700.0, 3500.0, 4500.0
};

static std::mutex g_voiceMutex;
static std::vector<std::vector<double>> g_enrollVectors;
static std::vector<double> g_voiceTemplate;  // normalized, kVoiceDims

static std::vector<double> voiceFeatures(const float* pcm, int samples) {
    if (pcm == nullptr || samples < kVoiceFrame) {
        return {};
    }

    const int featureCount = kVoiceBands + kVoiceScalarFeats;
    double sum[kVoiceBands + kVoiceScalarFeats] = {};
    double sumSq[kVoiceBands + kVoiceScalarFeats] = {};
    int frames = 0;

    for (int off = 0; off + kVoiceFrame <= samples; off += kVoiceHop) {
        const float* frame = pcm + off;

        double energy = 0.0;
        int crossings = 0;
        for (int i = 0; i < kVoiceFrame; ++i) {
            const double x = frame[i];
            energy += x * x;
            if (i > 0 && ((frame[i - 1] < 0) != (x < 0))) ++crossings;
        }
        const double rms = std::sqrt(energy / kVoiceFrame);

        double feat[kVoiceBands + kVoiceScalarFeats];
        feat[0] = std::log10(rms + 1e-6);
        feat[1] = static_cast<double>(crossings) / (kVoiceFrame - 1);

        double centroidNum = 0.0;
        double centroidDen = 0.0;
        for (int b = 0; b < kVoiceBands; ++b) {
            // Goertzel magnitude at the probe frequency.
            const double w = 2.0 * 3.14159265358979323846 *
                kProbeFreqs[b] / kVoiceSampleRate;
            const double coeff = 2.0 * std::cos(w);
            double s1 = 0.0, s2 = 0.0;
            for (int i = 0; i < kVoiceFrame; ++i) {
                const double s = frame[i] + coeff * s1 - s2;
                s2 = s1;
                s1 = s;
            }
            const double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
            feat[2 + b] = std::log10(power / kVoiceFrame + 1e-12);
            centroidNum += kProbeFreqs[b] * power;
            centroidDen += power;
        }
        feat[2 + kVoiceBands] = centroidDen > 0.0
            ? (centroidNum / centroidDen) / (kVoiceSampleRate / 2.0)
            : 0.0;

        for (int i = 0; i < featureCount; ++i) {
            sum[i] += feat[i];
            sumSq[i] += feat[i] * feat[i];
        }
        ++frames;
    }

    if (frames == 0) return {};

    std::vector<double> out(kVoiceDims, 0.0);
    for (int i = 0; i < featureCount; ++i) {
        const double mean = sum[i] / frames;
        const double variance = sumSq[i] / frames - mean * mean;
        out[i] = mean;
        out[featureCount + i] = std::sqrt(variance > 0.0 ? variance : 0.0);
    }
    return out;
}

[[maybe_unused]] static double cosineSimilarity(const std::vector<double>& a,
                               const std::vector<double>& b) {
    double dot = 0.0, na = 0.0, nb = 0.0;
    const std::size_t n = std::min(a.size(), b.size());
    for (std::size_t i = 0; i < n; ++i) {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if (na <= 0.0 || nb <= 0.0) return 0.0;
    return dot / (std::sqrt(na) * std::sqrt(nb));
}

static void normalize(std::vector<double>& v) {
    double norm = 0.0;
    for (double x : v) norm += x * x;
    norm = std::sqrt(norm);
    if (norm <= 0.0) return;
    for (double& x : v) x /= norm;
}

extern "C" {

MAXIMA_EXPORT void maxima_voice_enroll_begin() {
    std::lock_guard<std::mutex> lock(g_voiceMutex);
    g_enrollVectors.clear();
    g_voiceTemplate.clear();
}

MAXIMA_EXPORT int maxima_voice_enroll_add(
    const float* pcm, int samples) {
    auto features = voiceFeatures(pcm, samples);
    if (features.empty()) return -1;
    std::lock_guard<std::mutex> lock(g_voiceMutex);
    if (g_enrollVectors.size() >= kMaxEnrollVectors) return -2;
    g_enrollVectors.push_back(std::move(features));
    return static_cast<int>(g_enrollVectors.size());
}

MAXIMA_EXPORT int maxima_voice_enroll_commit() {
    std::lock_guard<std::mutex> lock(g_voiceMutex);
    if (g_enrollVectors.empty()) return 0;
    std::vector<double> mean(kVoiceDims, 0.0);
    for (const auto& v : g_enrollVectors) {
        for (int i = 0; i < kVoiceDims; ++i) mean[i] += v[i];
    }
    for (double& x : mean) x /= static_cast<double>(g_enrollVectors.size());
    normalize(mean);
    g_voiceTemplate = std::move(mean);
    g_enrollVectors.clear();
    return kVoiceDims;
}

MAXIMA_EXPORT bool maxima_voice_is_enrolled() {
    std::lock_guard<std::mutex> lock(g_voiceMutex);
    return !g_voiceTemplate.empty();
}

MAXIMA_EXPORT bool maxima_voice_verify(
    const float* pcm, int samples, float threshold) {
    auto features = voiceFeatures(pcm, samples);
    if (features.empty()) return false;
    normalize(features);
    std::lock_guard<std::mutex> lock(g_voiceMutex);
    if (g_voiceTemplate.empty()) return false;
    // Both vectors normalized: dot == cosine similarity.
    double dot = 0.0;
    for (int i = 0; i < kVoiceDims; ++i) {
        dot += features[i] * g_voiceTemplate[i];
    }
    return dot >= static_cast<double>(threshold);
}

MAXIMA_EXPORT void clearSecureMemoryCache() {
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (!zeroKeyCacheLine()) {
        volatileZeroKey();
    }
    g_key.v.store(false, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

MAXIMA_EXPORT void terminateActiveSession(const char* geolocation) {
    (void)geolocation;
    clearSecureMemoryCache();
}

MAXIMA_EXPORT bool verify_lowlevel_voice_print(const float* buffer, int samples) {
    return maxima_voice_verify(buffer, samples, 0.85F);
}

MAXIMA_EXPORT int analyze_breath_and_emotion(const float* buffer, int samples) {
    return buffer != nullptr && samples > 0 ? 1 : 0;
}

MAXIMA_EXPORT std::uint64_t maxima_counter_now() {
    return counterNow();
}

MAXIMA_EXPORT std::uint64_t maxima_counter_frequency() {
    return counterFrequency();
}

MAXIMA_EXPORT std::uint64_t maxima_cache_zero_block_size() {
    return cacheZeroBlockSize();
}

MAXIMA_EXPORT bool maxima_runtime_integrity_ok() {
    return !debuggerDetected();
}

MAXIMA_EXPORT std::uint64_t maxima_measure_secure_wipe_cycles() {
    const std::uint64_t start = counterNow();
    clearSecureMemoryCache();
    const std::uint64_t end = counterNow();
    return end >= start ? end - start : 0;
}

MAXIMA_EXPORT bool maxima_hardware_purge_if_compromised(
    std::uint64_t lastWipeCycles,
    std::uint64_t thresholdCycles
) {
    const bool timingDilation =
        thresholdCycles > 0 && lastWipeCycles > thresholdCycles;
    if (timingDilation || debuggerDetected()) {
        clearSecureMemoryCache();
        return true;
    }
    return false;
}

MAXIMA_EXPORT bool maxima_voip_pipeline_ready() {
#if defined(MAXIMA_WITH_PJSIP)
    return true;
#else
    return false;
#endif
}

}
