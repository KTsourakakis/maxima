package com.example.aura_straton_maxima_ai

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer

/// Fan-out between the Dart UI and the background wake-word engine.
object MaximaWakeWordBus {
    @Volatile
    var sink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun emit(payload: Map<String, Any?>) {
        mainHandler.post {
            try {
                sink?.success(payload)
            } catch (_: Exception) {
            }
        }
    }
}

/**
 * Single-owner microphone pipeline for the foreground service.
 *
 * One AudioRecord feed fans out to:
 *  - the Vosk recognizer (wake-word + STT)
 *  - an optional PCM16 recording sink (sealed later by Dart AES-GCM)
 *  - ad-hoc voice-print capture requests (buffered float samples)
 *
 * When the compliant mute flag is set, zeros are fed to every
 * consumer — recording and recognition see silence while the
 * foreground stream (and Android's privacy indicator) stays up.
 */
class MaximaAudioPipeline(private val context: Context) {

    data class VoiceCaptureRequest(
        val durationMs: Int,
        val callback: (ByteArray?) -> Unit,
    )

    companion object {
        const val SAMPLE_RATE = 16000

        /** Normalized wake-phrase keys reported to Dart. */
        val DEFAULT_PHRASES: Map<String, String> = mapOf(
            "distress" to "distress",
            "emergency" to "distress",
            "panic" to "distress",
            "purge" to "purge",
            "force black" to "purge",
            "wipe keys" to "purge",
            "log this" to "log",
            "note this" to "log",
            "secure record" to "record",
            "start recording" to "record",
        )
    }

    @Volatile
    var phrases: Map<String, String> = DEFAULT_PHRASES

    @Volatile
    var muted: Boolean = false

    private val modelDir: File
        get() = File(context.filesDir, "models/vosk-model")

    @Volatile
    private var running = false
    private var worker: Thread? = null
    private var recorderFile: AtomicReference<FileOutputStream?> =
        AtomicReference(null)
    private var recorderPath: AtomicReference<String?> = AtomicReference(null)
    private var voiceCapture: AtomicReference<VoiceCaptureRequest?> =
        AtomicReference(null)
    private var voiceBuffer = ArrayList<Byte>()
    private var voiceRemainingMs = 0
    private val lastFiredAt = HashMap<String, Long>()
    @Volatile
    private var lastPartialEmittedAt = 0L

    val isRunning: Boolean get() = running

    fun start() {
        if (running) return
        running = true
        worker = Thread({ runLoop() }, "maxima-audio").apply { start() }
    }

    fun stop() {
        running = false
        worker?.join(2000)
        worker = null
        stopPcmRecording()
        voiceCapture.getAndSet(null)?.callback?.let { callback ->
            Handler(Looper.getMainLooper()).post { callback(null) }
        }
    }

    /** Begins writing raw PCM16 to a new cache file. */
    fun startPcmRecording(): String {
        val file = File(
            context.cacheDir,
            "maxima_capture_${System.currentTimeMillis()}.pcm"
        )
        recorderPath.set(file.absolutePath)
        recorderFile.set(FileOutputStream(file))
        return file.absolutePath
    }

    /** Stops writing and returns the PCM file path (or null). */
    fun stopPcmRecording(): String? {
        val stream = recorderFile.getAndSet(null)
        try {
            stream?.close()
        } catch (_: Exception) {
        }
        val path = recorderPath.getAndSet(null)
        if (path != null && stream == null) return null
        return path
    }

    /** Requests a buffered voice-print sample; callback on main thread. */
    fun requestVoiceCapture(durationMs: Int, callback: (ByteArray?) -> Unit) {
        val clamped = durationMs.coerceIn(500, 15000)
        voiceBuffer = ArrayList()
        voiceRemainingMs = clamped
        voiceCapture.set(VoiceCaptureRequest(clamped, callback))
    }

    fun modelStatus(): String {
        return if (File(modelDir, "am").exists() ||
            File(modelDir, "graph").exists() ||
            modelDir.listFiles()?.isNotEmpty() == true
        ) {
            "ready:${modelDir.absolutePath}"
        } else {
            "missing:${modelDir.absolutePath}"
        }
    }

    private fun runLoop() {
        LibVosk.setLogLevel(LogLevel.WARNINGS)

        var recognizer: Recognizer? = null
        var model: Model? = null
        var reportedMissing = false

        // The model may still be downloading when the service starts.
        // Keep retrying so the recognizer self-heals instead of running
        // deaf with a live microphone until the next cold start.
        while (running && recognizer == null) {
            try {
                if (File(modelDir, "am").exists() ||
                    File(modelDir, "conf/model.conf").exists() ||
                    modelDir.listFiles()?.isNotEmpty() == true
                ) {
                    model = Model(modelDir.absolutePath)
                    recognizer = Recognizer(model, SAMPLE_RATE.toFloat())
                    recognizer.setWords(true)
                    recognizer.setPartialWords(true)
                    MaximaWakeWordBus.emit(
                        mapOf("status" to "listening")
                    )
                }
            } catch (error: Exception) {
                try {
                    recognizer?.close()
                } catch (_: Exception) {
                }
                recognizer = null
                try {
                    model?.close()
                } catch (_: Exception) {
                }
                model = null
                if (!reportedMissing) {
                    reportedMissing = true
                    MaximaWakeWordBus.emit(
                        mapOf(
                            "status" to "model-error",
                            "detail" to (error.message ?: "model load failed"),
                        )
                    )
                }
            }
            if (recognizer == null) {
                if (!reportedMissing) {
                    reportedMissing = true
                    MaximaWakeWordBus.emit(
                        mapOf(
                            "status" to "model-missing",
                            "path" to modelDir.absolutePath,
                        )
                    )
                }
                try {
                    Thread.sleep(2000)
                } catch (_: InterruptedException) {
                }
            }
        }
        if (!running) {
            recognizer?.close()
            model?.close()
            return
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val audioRecord = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuffer, SAMPLE_RATE),
            )
        } catch (error: Exception) {
            model?.close()
            MaximaWakeWordBus.emit(
                mapOf(
                    "status" to "mic-error",
                    "detail" to (error.message ?: "AudioRecord failed"),
                )
            )
            return
        }

        try {
            audioRecord.startRecording()
        } catch (_: Exception) {
            audioRecord.release()
            model?.close()
            return
        }

        val frame = ShortArray(2048)
        try {
            while (running) {
                val read = audioRecord.read(frame, 0, frame.size)
                if (read <= 0) continue

                val pcm = if (muted) ShortArray(read) else
                    frame.copyOf(read)

                feedVoiceCapture(pcm)
                feedRecording(pcm)
                recognizer?.let { feedRecognizer(it, pcm) }
            }
        } finally {
            try {
                audioRecord.stop()
            } catch (_: Exception) {
            }
            audioRecord.release()
            recognizer?.close()
            model?.close()
        }
    }

    private fun feedVoiceCapture(pcm: ShortArray) {
        val request = voiceCapture.get() ?: return
        for (sample in pcm) {
            voiceBuffer.add((sample.toInt() and 0xff).toByte())
            voiceBuffer.add((sample.toInt() shr 8 and 0xff).toByte())
        }
        voiceRemainingMs -= pcm.size * 1000 / SAMPLE_RATE
        if (voiceRemainingMs <= 0) {
            voiceCapture.set(null)
            val bytes = ByteArray(voiceBuffer.size) { i -> voiceBuffer[i] }
            voiceBuffer = ArrayList()
            Handler(Looper.getMainLooper()).post { request.callback(bytes) }
        }
    }

    private fun feedRecording(pcm: ShortArray) {
        val stream = recorderFile.get() ?: return
        val bytes = ByteArray(pcm.size * 2)
        for (i in pcm.indices) {
            bytes[i * 2] = (pcm[i].toInt() and 0xff).toByte()
            bytes[i * 2 + 1] = (pcm[i].toInt() shr 8 and 0xff).toByte()
        }
        try {
            stream.write(bytes)
        } catch (_: Exception) {
        }
    }

    private fun feedRecognizer(recognizer: Recognizer, pcm: ShortArray) {
        val complete = recognizer.acceptWaveForm(pcm, pcm.size)
        val json = if (complete) recognizer.result else recognizer.partialResult
        val transcript = try {
            val obj = JSONObject(json)
            obj.optString(if (complete) "text" else "partial")
        } catch (_: Exception) {
            ""
        }
        if (transcript.isBlank()) return

        var matched = false
        for ((phrase, key) in phrases) {
            if (!transcript.lowercase().contains(phrase)) continue
            matched = true
            val now = System.currentTimeMillis()
            val last = lastFiredAt[key] ?: 0L
            if (!complete && now - last < 2000) continue
            lastFiredAt[key] = now
            MaximaWakeWordBus.emit(
                mapOf(
                    "phrase" to key,
                    "transcript" to transcript,
                    "final" to complete,
                )
            )
        }

        // Unmatched transcripts reach Dart: finals drive the agent
        // loop; partials are throttled so the UI can show live
        // "hearing: ..." feedback without flooding the channel.
        if (!matched) {
            if (complete) {
                MaximaWakeWordBus.emit(
                    mapOf(
                        "phrase" to "",
                        "transcript" to transcript,
                        "final" to true,
                    )
                )
            } else {
                val now = System.currentTimeMillis()
                if (now - lastPartialEmittedAt > 350) {
                    lastPartialEmittedAt = now
                    MaximaWakeWordBus.emit(
                        mapOf(
                            "phrase" to "",
                            "transcript" to transcript,
                            "final" to false,
                        )
                    )
                }
            }
        }
    }
}
