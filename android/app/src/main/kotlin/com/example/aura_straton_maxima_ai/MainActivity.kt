package com.example.aura_straton_maxima_ai

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.telephony.SmsManager
import android.text.TextUtils
import android.util.Base64
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val channelName = "aura.straton.maxima/accessibility"
    private val wakeWordEventChannel = "aura.straton.maxima/wake_word"
    private val permissionsRequestCode = 6101
    private var pendingPermissionsResult: MethodChannel.Result? = null
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        textToSpeech = TextToSpeech(this, this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestSystemPermissions" -> requestSystemPermissions(result)
                "executeGlobalAction" -> {
                    val action = call.argument<Number>("action")?.toInt()
                        ?: MaximaAccessibilityService.DEFAULT_GLOBAL_ACTION
                    result.success(MaximaAccessibilityService.performGlobal(action))
                }
                "sendEmergencySms" -> {
                    val number = call.argument<String>("number")
                    val message = call.argument<String>("message")
                    if (number.isNullOrBlank() || message.isNullOrBlank()) {
                        result.error(
                            "INVALID_SOS_PAYLOAD",
                            "Expected number and message.",
                            null
                        )
                    } else if (ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.SEND_SMS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(false)
                    } else {
                        try {
                            SmsManager.getDefault().sendTextMessage(
                                number,
                                null,
                                message,
                                null,
                                null
                            )
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("SMS_FAILED", error.message, null)
                        }
                    }
                }
                "startEmergencyCall" -> {
                    val number = call.argument<String>("number")
                    if (number.isNullOrBlank()) {
                        result.error("INVALID_NUMBER", "Expected phone number.", null)
                    } else if (ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.CALL_PHONE
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(false)
                    } else {
                        startActivity(
                            Intent(
                                Intent.ACTION_CALL,
                                Uri.fromParts("tel", number, null)
                            )
                        )
                        result.success(true)
                    }
                }
                "setBatteryThreshold" -> {
                    val threshold = call.argument<Number>("threshold")?.toInt()
                    if (threshold == null) {
                        result.error("INVALID_THRESHOLD", "Expected integer threshold.", null)
                    } else {
                        MaximaBackgroundService.setBatteryThreshold(threshold)
                        result.success(true)
                    }
                }
                "setMicrophoneMuted" -> {
                    val muted = call.argument<Boolean>("muted")
                    if (muted == null) {
                        result.error("INVALID_MUTE_STATE", "Expected boolean muted value.", null)
                    } else {
                        val audioManager = getSystemService(AudioManager::class.java)
                        audioManager?.isMicrophoneMute = muted
                        MaximaBackgroundService.setMicrophoneMuted(muted)
                        result.success(audioManager?.isMicrophoneMute == muted)
                    }
                }
                "speakText" -> {
                    val text = call.argument<String>("text")
                    when {
                        text.isNullOrBlank() -> result.error(
                            "INVALID_TEXT",
                            "Expected non-empty text.",
                            null
                        )
                        !textToSpeechReady -> result.error(
                            "TTS_NOT_READY",
                            "Text-to-speech is still initializing.",
                            null
                        )
                        else -> {
                            textToSpeech?.speak(
                                text,
                                TextToSpeech.QUEUE_FLUSH,
                                null,
                                "maxima-tts"
                            )
                            result.success(true)
                        }
                    }
                }
                "stopSpeech" -> {
                    textToSpeech?.stop()
                    result.success(true)
                }
                "getAppFilesDir" -> result.success(filesDir.absolutePath)
                "isAccessibilityServiceEnabled" -> result.success(
                    isAccessibilityServiceEnabled()
                )
                "openAccessibilitySettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    )
                    result.success(true)
                }
                "startWakeWordEngine" -> {
                    @Suppress("UNCHECKED_CAST")
                    val phrases = call.argument<Map<String, String>>("phrases")
                    MaximaBackgroundService.configureWakeWords(
                        phrases ?: MaximaAudioPipeline.DEFAULT_PHRASES
                    )
                    startMaximaService()
                    result.success(true)
                }
                "stopWakeWordEngine" -> {
                    MaximaBackgroundService.stopWakeWords()
                    result.success(true)
                }
                "voskModelStatus" -> result.success(
                    MaximaBackgroundService.pipeline()?.modelStatus()
                        ?: if (MaximaModelManager.isReady(this)) "ready"
                        else "missing"
                )
                "downloadVoskModel" -> {
                    val url = call.argument<String>("url")
                        ?: MaximaModelManager.DEFAULT_MODEL_URL
                    MaximaModelManager.download(this, url) { ok, detail ->
                        if (ok) result.success(detail)
                        else result.error("MODEL_DOWNLOAD_FAILED", detail, null)
                    }
                }
                "startSecureRecording" -> {
                    startMaximaService()
                    Handler(Looper.getMainLooper()).postDelayed({
                        val pipeline = MaximaBackgroundService.pipeline()
                        if (pipeline == null) {
                            result.error(
                                "SERVICE_NOT_READY",
                                "Foreground service is still starting.",
                                null
                            )
                        } else {
                            result.success(pipeline.startPcmRecording())
                        }
                    }, 400)
                }
                "stopSecureRecording" -> {
                    result.success(
                        MaximaBackgroundService.pipeline()
                            ?.stopPcmRecording()
                    )
                }
                "captureVoicePrint" -> {
                    val durationMs =
                        call.argument<Number>("durationMs")?.toInt() ?: 3000
                    startMaximaService()
                    Handler(Looper.getMainLooper()).postDelayed({
                        val pipeline = MaximaBackgroundService.pipeline()
                        if (pipeline == null) {
                            result.error(
                                "SERVICE_NOT_READY",
                                "Foreground service is still starting.",
                                null
                            )
                        } else {
                            pipeline.requestVoiceCapture(durationMs) { pcm ->
                                if (pcm == null) {
                                    result.error(
                                        "CAPTURE_FAILED",
                                        "Voice capture was cancelled.",
                                        null
                                    )
                                } else {
                                    result.success(pcm)
                                }
                            }
                        }
                    }, 400)
                }
                "wrapDataKey" -> {
                    val keyBase64 = call.argument<String>("key")
                    try {
                        result.success(
                            MaximaKeyVault.wrapDataKey(
                                Base64.decode(keyBase64, Base64.NO_WRAP)
                            )
                        )
                    } catch (error: Exception) {
                        result.error("KEY_WRAP_FAILED", error.message, null)
                    }
                }
                "unwrapDataKey" -> {
                    val wrapped = call.argument<String>("wrapped")
                    try {
                        result.success(
                            Base64.encodeToString(
                                MaximaKeyVault.unwrapDataKey(wrapped ?: ""),
                                Base64.NO_WRAP
                            )
                        )
                    } catch (error: Exception) {
                        result.error("KEY_UNWRAP_FAILED", error.message, null)
                    }
                }
                "sipRegister" -> {
                    val server = call.argument<String>("server")
                    val username = call.argument<String>("username")
                    val password = call.argument<String>("password")
                    if (server.isNullOrBlank() || username.isNullOrBlank() ||
                        password.isNullOrBlank()
                    ) {
                        result.error(
                            "INVALID_SIP_CONFIG",
                            "Expected server, username and password.",
                            null
                        )
                    } else {
                        val callerId = call.argument<String>("callerId")
                        val transport =
                            call.argument<String>("transport") ?: "tls"
                        val port =
                            call.argument<Number>("port")?.toInt() ?: 5061
                        MaximaSipClient.runAsync({
                            MaximaSipClient.register(
                                server, username, password,
                                callerId, transport, port
                            )
                        }) { ok, detail ->
                            if (ok) result.success(detail)
                            else result.error("SIP_REGISTER_FAILED", detail, null)
                        }
                    }
                }
                "sipCall" -> {
                    val destination = call.argument<String>("destination")
                    if (destination.isNullOrBlank()) {
                        result.error(
                            "INVALID_DESTINATION",
                            "Expected a SIP destination.",
                            null
                        )
                    } else {
                        MaximaSipClient.runAsync({
                            MaximaSipClient.callDestination(destination)
                        }) { ok, detail ->
                            if (ok) result.success(detail)
                            else result.error("SIP_CALL_FAILED", detail, null)
                        }
                    }
                }
                "sipHangup" -> MaximaSipClient.runAsync({
                    MaximaSipClient.hangup()
                }) { ok, detail ->
                    if (ok) result.success(detail)
                    else result.error("SIP_HANGUP_FAILED", detail, null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wakeWordEventChannel
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink?
            ) {
                MaximaWakeWordBus.sink = events
            }

            override fun onCancel(arguments: Any?) {
                MaximaWakeWordBus.sink = null
            }
        })
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val expected = "$packageName/.MaximaAccessibilityService"
        val expectedFull =
            "$packageName/$packageName.MaximaAccessibilityService"
        return enabled.split(':').any {
            TextUtils.equals(it, expected) || TextUtils.equals(it, expectedFull)
        }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            textToSpeech?.setLanguage(Locale.getDefault())
            textToSpeechReady = true
        }
    }

    private fun requestSystemPermissions(result: MethodChannel.Result) {
        if (pendingPermissionsResult != null) {
            result.error("PERMISSIONS_PENDING", "A permission request is already active.", null)
            return
        }

        val missingPermissions = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missingPermissions.isEmpty()) {
            startMaximaService()
            result.success(true)
            return
        }

        pendingPermissionsResult = result
        ActivityCompat.requestPermissions(
            this,
            missingPermissions.toTypedArray(),
            permissionsRequestCode
        )
    }

    private fun requiredPermissions(): List<String> {
        val permissions = mutableListOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_PHONE_NUMBERS,
            Manifest.permission.CALL_PHONE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return permissions
    }

    private fun startMaximaService() {
        val intent = Intent(this, MaximaBackgroundService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionsRequestCode) return

        val granted = grantResults.isNotEmpty() && grantResults.all {
            it == PackageManager.PERMISSION_GRANTED
        }
        if (granted) {
            startMaximaService()
        }
        pendingPermissionsResult?.success(granted)
        pendingPermissionsResult = null
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        super.onDestroy()
    }
}
