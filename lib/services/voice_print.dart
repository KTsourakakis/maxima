import 'dart:math' as math;
import 'dart:typed_data';

/// Lightweight on-device speaker fingerprint.
///
/// Not a biometric-grade verifier — it compares coarse acoustic
/// features (energy, zero-crossing rate, spectral centroid and band
/// energy distribution) with cosine similarity, which is enough to
/// gate "answer only to the enrolled voice" without cloud services.
class VoicePrint {
    VoicePrint(this.features);

    /// Mean of several enrollment prints — averages out noise.
    factory VoicePrint.average(List<VoicePrint> prints) {
        final dims = prints.first.features.length;
        final mean = Float64List(dims);
        for (final p in prints) {
            for (var i = 0; i < dims; i++) {
                mean[i] += p.features[i] / prints.length;
            }
        }
        return VoicePrint(mean);
    }

    factory VoicePrint.fromJson(Map<String, dynamic> json) {
        final raw = (json['features'] as List).cast<num>();
        return VoicePrint(Float64List.fromList(
            raw.map((e) => e.toDouble()).toList(),
        ));
    }

    final Float64List features;

    /// Cosine similarity in [0,1]; ~1 means same speaker.
    double similarity(VoicePrint other) {
        var dot = 0.0, a = 0.0, b = 0.0;
        final n = math.min(features.length, other.features.length);
        for (var i = 0; i < n; i++) {
            dot += features[i] * other.features[i];
            a += features[i] * features[i];
            b += other.features[i] * other.features[i];
        }
        if (a == 0 || b == 0) return 0;
        return dot / (math.sqrt(a) * math.sqrt(b));
    }

    Map<String, dynamic> toJson() => {'features': features.toList()};
}

/// Acceptance gate for [VoicePrint.similarity]. Deliberately
/// forgiving — coarse features vary with distance, volume and mic.
const double voiceVerifyThreshold = 0.72;

/// Extracts a speaker fingerprint from little-endian PCM16 mono
/// audio (16 kHz). Returns null when the clip is too short or
/// effectively silent.
List<double>? extractVoiceFeatures(Uint8List pcm16) {
    final count = pcm16.length ~/ 2;
    if (count < 2048) return null;
    final samples = Int16List.view(
        pcm16.buffer,
        pcm16.offsetInBytes,
        count,
    );

    const frame = 512; // 32 ms @ 16 kHz
    const hop = 256;
    final re = Float64List(frame);
    final im = Float64List(frame);

    var rmsSum = 0.0, zcrSum = 0.0, centroidSum = 0.0;
    var centroidSqSum = 0.0;
    final bands = List<double>.filled(4, 0.0);
    var voiced = 0;

    for (var start = 0; start + frame <= count; start += hop) {
        var energy = 0.0, zc = 0.0;
        var prev = samples[start].toDouble();
        for (var i = 0; i < frame; i++) {
            final s = samples[start + i] / 32768.0;
            energy += s * s;
            // Hann window to reduce spectral leakage.
            final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (frame - 1));
            re[i] = s * w;
            im[i] = 0.0;
            if (i > 0 &&
                ((prev >= 0) != (samples[start + i] >= 0))) {
                zc += 1;
            }
            prev = samples[start + i].toDouble();
        }
        final rms = math.sqrt(energy / frame);
        if (rms < 0.005) continue; // silence / muted frame

        _fft(re, im);

        var magSum = 0.0, weighted = 0.0;
        final bandSum = List<double>.filled(4, 0.0);
        const binHz = 16000.0 / frame; // 31.25 Hz per bin
        for (var b = 1; b < frame ~/ 2; b++) {
            final mag = math.sqrt(re[b] * re[b] + im[b] * im[b]);
            magSum += mag;
            final hz = b * binHz;
            weighted += mag * hz;
            final idx = hz < 1000
                ? 0
                : hz < 2000
                    ? 1
                    : hz < 4000
                        ? 2
                        : 3;
            bandSum[idx] += mag;
        }
        if (magSum <= 0) continue;

        voiced++;
        rmsSum += rms;
        zcrSum += zc / frame;
        final centroid = (weighted / magSum) / 8000.0; // normalize
        centroidSum += centroid;
        centroidSqSum += centroid * centroid;
        for (var i = 0; i < 4; i++) {
            bands[i] += bandSum[i] / magSum;
        }
    }

    if (voiced < 4) return null;
    final centroidMean = centroidSum / voiced;
    final centroidVar = (centroidSqSum / voiced) - centroidMean * centroidMean;
    return [
        rmsSum / voiced,
        zcrSum / voiced,
        centroidMean,
        math.sqrt(math.max(centroidVar, 0.0)),
        bands[0] / voiced,
        bands[1] / voiced,
        bands[2] / voiced,
        bands[3] / voiced,
    ];
}

/// Iterative radix-2 FFT; [re]/[im] must be the same power-of-two
/// length and are transformed in place.
void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
        var bit = n >> 1;
        for (; j & bit != 0; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            final tr = re[i];
            re[i] = re[j];
            re[j] = tr;
            final ti = im[i];
            im[i] = im[j];
            im[j] = ti;
        }
    }
    for (var len = 2; len <= n; len <<= 1) {
        final ang = -2 * math.pi / len;
        final wr = math.cos(ang), wi = math.sin(ang);
        for (var i = 0; i < n; i += len) {
            var curR = 1.0, curI = 0.0;
            for (var k = 0; k < len ~/ 2; k++) {
                final j = i + k, h = j + len ~/ 2;
                final vR = re[h] * curR - im[h] * curI;
                final vI = re[h] * curI + im[h] * curR;
                re[h] = re[j] - vR;
                im[h] = im[j] - vI;
                re[j] += vR;
                im[j] += vI;
                final nextR = curR * wr - curI * wi;
                curI = curR * wi + curI * wr;
                curR = nextR;
            }
        }
    }
}
