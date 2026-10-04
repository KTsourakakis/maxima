package com.example.aura_straton_maxima_ai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

class MaximaAccessibilityService : AccessibilityService() {
    companion object {
        const val DEFAULT_GLOBAL_ACTION = AccessibilityService.GLOBAL_ACTION_HOME
        private const val LONG_PRESS_MS = 900L

        @Volatile
        private var activeService: MaximaAccessibilityService? = null

        fun attach(service: MaximaAccessibilityService) {
            activeService = service
        }

        fun detach(service: MaximaAccessibilityService) {
            if (activeService === service) activeService = null
        }

        fun performGlobal(action: Int): Boolean {
            return activeService?.performGlobalAction(action) == true
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var pendingVolumeKeyCode: Int? = null
    private var longPressRunnable: Runnable? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        attach(this)
        serviceInfo = serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() {
        cancelPendingLongPress()
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val direction = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> AudioManager.ADJUST_RAISE
            KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER
            else -> return super.onKeyEvent(event)
        }

        when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (event.repeatCount == 0) {
                    scheduleLongPress(event.keyCode)
                }
                return true
            }
            KeyEvent.ACTION_UP -> {
                val shortPress = pendingVolumeKeyCode == event.keyCode
                cancelPendingLongPress()
                if (shortPress) {
                    adjustVolume(direction)
                }
                return true
            }
        }
        return super.onKeyEvent(event)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        cancelPendingLongPress()
        detach(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        cancelPendingLongPress()
        detach(this)
        super.onDestroy()
    }

    private fun scheduleLongPress(keyCode: Int) {
        cancelPendingLongPress()
        pendingVolumeKeyCode = keyCode
        longPressRunnable = Runnable {
            pendingVolumeKeyCode = null
            toggleMicrophoneMute()
        }.also { handler.postDelayed(it, LONG_PRESS_MS) }
    }

    private fun cancelPendingLongPress() {
        longPressRunnable?.let(handler::removeCallbacks)
        longPressRunnable = null
    }

    private fun adjustVolume(direction: Int) {
        getSystemService(AudioManager::class.java)?.adjustStreamVolume(
            AudioManager.STREAM_MUSIC,
            direction,
            AudioManager.FLAG_SHOW_UI
        )
    }

    private fun toggleMicrophoneMute() {
        val audioManager = getSystemService(AudioManager::class.java) ?: return
        val muted = !audioManager.isMicrophoneMute
        audioManager.isMicrophoneMute = muted
        MaximaBackgroundService.setMicrophoneMuted(muted)
    }
}
