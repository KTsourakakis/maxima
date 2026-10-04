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
 * Fetches and unpacks a Vosk acoustic model into
 * `<filesDir>/models/vosk-model`.
 *
 * Small models (~40-50 MB) such as `vosk-model-small-en-us-0.15` or
 * `vosk-model-small-el` fit comfortably; the zip root folder is
 * flattened into `vosk-model`.
 */
object MaximaModelManager {
    const val DEFAULT_MODEL_URL =
        "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

    @Volatile
    private var downloading = false

    fun modelDir(context: Context): File =
        File(context.filesDir, "models/vosk-model")

    fun isReady(context: Context): Boolean {
        val dir = modelDir(context)
        return dir.isDirectory &&
            (dir.listFiles()?.isNotEmpty() == true)
    }

    /**
     * Downloads [url] and unpacks it into the model directory.
     * [callback] runs on the main thread with a status string.
     */
    fun download(
        context: Context,
        url: String,
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
                fetchAndUnpack(appContext, url)
            } catch (error: Exception) {
                "error:${error.message}"
            }
            downloading = false
            Handler(Looper.getMainLooper()).post {
                if (result == "ok") {
                    callback(true, modelDir(appContext).absolutePath)
                } else {
                    callback(false, result)
                }
            }
        }, "maxima-model-download").start()
    }

    private fun fetchAndUnpack(context: Context, url: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15000
        connection.readTimeout = 60000
        connection.instanceFollowRedirects = true
        connection.connect()
        try {
            if (connection.responseCode !in 200..299) {
                return "http:${connection.responseCode}"
            }
            val target = modelDir(context)
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
