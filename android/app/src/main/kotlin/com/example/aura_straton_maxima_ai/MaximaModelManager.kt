package com.example.aura_straton_maxima_ai

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

/**
 * Fetches and unpacks Vosk acoustic models into per-language
 * directories `<filesDir>/models/vosk-model-<lang>`.
 *
 * A `models/active.txt` marker names the language the recognizer
 * should load, so switching back to a previously downloaded
 * language is instant — no re-download, and a failed download can
 * never leave the engine running the wrong language.
 */
object MaximaModelManager {
    const val DEFAULT_MODEL_URL =
        "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

    @Volatile
    private var downloading = false

    fun modelsRoot(context: Context): File =
        File(context.filesDir, "models")

    fun modelDir(context: Context, lang: String): File =
        File(modelsRoot(context), "vosk-model-$lang")

    /** The language tag the engine should currently load. */
    fun activeLang(context: Context): String {
        val marker = File(modelsRoot(context), "active.txt")
        if (!marker.exists()) {
            // Migrate a pre-multilingual install: the flat model
            // directory becomes the English model.
            val legacy = File(modelsRoot(context), "vosk-model")
            if (legacy.isDirectory &&
                legacy.listFiles()?.isNotEmpty() == true
            ) {
                try {
                    legacy.renameTo(modelDir(context, "en"))
                } catch (_: Exception) {
                }
            }
            try {
                modelsRoot(context).mkdirs()
                marker.writeText("en")
            } catch (_: Exception) {
            }
        }
        return try {
            marker.readText().trim().ifEmpty { "en" }
        } catch (_: Exception) {
            "en"
        }
    }

    /** Marks [lang] as the model the recognizer loads on next start. */
    fun setActive(context: Context, lang: String) {
        try {
            modelsRoot(context).mkdirs()
            File(modelsRoot(context), "active.txt").writeText(lang)
        } catch (_: Exception) {
        }
    }

    fun isReady(context: Context, lang: String): Boolean {
        val dir = modelDir(context, lang)
        return dir.isDirectory &&
            (dir.listFiles()?.isNotEmpty() == true)
    }

    /**
     * Downloads [url] and unpacks it into the per-language model
     * directory for [lang]. [callback] runs on the main thread.
     */
    fun download(
        context: Context,
        url: String,
        lang: String,
        callback: (Boolean, String) -> Unit,
    ) {
        if (downloading) {
            callback(false, "A model download is already in progress")
            return
        }
        downloading = true
        val appContext = context.applicationContext
        Thread({
            val result = try {
                fetchAndUnpack(appContext, url, lang)
            } catch (error: Exception) {
                "error:${error.message}"
            }
            downloading = false
            Handler(Looper.getMainLooper()).post {
                if (result == "ok") {
                    callback(true, modelDir(appContext, lang).absolutePath)
                } else {
                    callback(false, result)
                }
            }
        }, "maxima-model-download").start()
    }

    private fun fetchAndUnpack(
        context: Context,
        url: String,
        lang: String,
    ): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15000
        connection.readTimeout = 60000
        connection.instanceFollowRedirects = true
        connection.connect()
        try {
            if (connection.responseCode !in 200..299) {
                return "http:${connection.responseCode}"
            }
            val target = modelDir(context, lang)
            val staging = File(
                context.cacheDir,
                "vosk-model-${System.currentTimeMillis()}"
            )
            staging.mkdirs()
            ZipInputStream(connection.inputStream).use { zip ->
                var entry: ZipEntry? = zip.nextEntry
                while (entry != null) {
                    // Flatten "<model-root>/" so the archive root becomes
                    // the model directory itself.
                    val name = entry.name.substringAfter('/')
                    if (name.isNotEmpty()) {
                        val outFile = File(staging, name)
                        if (entry.isDirectory) {
                            outFile.mkdirs()
                        } else {
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { out ->
                                zip.copyTo(out)
                            }
                        }
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
            if (target.exists()) target.deleteRecursively()
            target.parentFile?.mkdirs()
            if (!staging.renameTo(target)) {
                staging.copyRecursively(target, overwrite = true)
                staging.deleteRecursively()
            }
            return "ok"
        } finally {
            connection.disconnect()
        }
    }
}
