package com.example.aura_straton_maxima_ai

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class MaximaBackgroundService : Service() {
    companion object {
        private const val NOTIFICATION_ID = 1
        private const val DEFAULT_BATTERY_THRESHOLD = 15

        @Volatile
        private var batteryThresholdPercent = DEFAULT_BATTERY_THRESHOLD

        @Volatile
        private var microphoneMuted = false

        @Volatile
        private var activeInstance: MaximaBackgroundService? = null

        @Volatile
        private var wakeWordPhrases: Map<String, String>? = null

        fun setBatteryThreshold(percent: Int) {
            batteryThresholdPercent = percent.coerceIn(5, 95)
            activeInstance?.evaluateBatteryThreshold()
        }

        fun setMicrophoneMuted(muted: Boolean) {
            microphoneMuted = muted
            activeInstance?.applyMicrophoneMute(muted)
        }

        /** Applies a phrase map and enables the Vosk wake-word engine. */
        fun configureWakeWords(phrases: Map<String, String>?) {
            wakeWordPhrases = phrases
            activeInstance?.audioPipeline?.let { pipeline ->
                if (phrases != null) pipeline.phrases = phrases
                pipeline.start()
            }
        }

        fun stopWakeWords() {
            wakeWordPhrases = null
        }

        /** Shared audio pipeline, null until the service is running. */
        fun pipeline(): MaximaAudioPipeline? = activeInstance?.audioPipeline

        fun isActive(): Boolean = activeInstance != null
    }

    private val channelId = "MaximaSecureChannel"

    /** Shared mic feed; also drives Vosk, PCM capture and voice ID. */
    val audioPipeline: MaximaAudioPipeline by lazy {
        MaximaAudioPipeline(this)
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            evaluateBatteryThreshold()
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        if (!hasRecordAudioPermission()) {
            stopSelf()
            return
        }

        createNotificationChannel()
        startForegroundServiceNotification()
        registerBatteryReceiver()
        audioPipeline.muted = microphoneMuted
        audioPipeline.start()
        evaluateBatteryThreshold()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!hasRecordAudioPermission()) {
            stopSelf()
            return START_NOT_STICKY
        }
        audioPipeline.start()
        evaluateBatteryThreshold()
        return START_STICKY
    }

    override fun onDestroy() {
        audioPipeline.stop()
        getSystemService(AudioManager::class.java)?.isMicrophoneMute = false
        activeInstance = null
        try {
            unregisterReceiver(batteryReceiver)
        } catch (_: IllegalArgumentException) {
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun hasRecordAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun registerBatteryReceiver() {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(batteryReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(batteryReceiver, filter)
        }
    }

    private fun evaluateBatteryThreshold() {
        val batteryStatus = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        ) ?: return

        val level = batteryStatus.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = batteryStatus.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val status = batteryStatus.getIntExtra(
            BatteryManager.EXTRA_STATUS,
            BatteryManager.BATTERY_STATUS_UNKNOWN
        )
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL

        if (level >= 0 && scale > 0 && !charging) {
            val percent = level * 100 / scale
            if (percent <= batteryThresholdPercent) {
                stopSelf()
            }
        }
    }

    private fun applyMicrophoneMute(muted: Boolean) {
        getSystemService(AudioManager::class.java)?.isMicrophoneMute = muted
        audioPipeline.muted = muted
        updateNotification()
    }

    private fun startForegroundServiceNotification() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)?.notify(
            NOTIFICATION_ID,
            buildNotification()
        )
    }

    private fun buildNotification(): Notification {
        val state = if (microphoneMuted) "Muted" else "Listening"
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Maxima System Active")
            .setContentText("Secure foreground assistant: $state")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                channelId,
                "Maxima Security Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(serviceChannel)
        }
    }
}
