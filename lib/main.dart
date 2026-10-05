import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Directory,
        InternetAddressType,
        NetworkInterface,
        Platform,
        Socket;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services/access_control.dart';
import 'services/cognitive_search.dart';
import 'services/desktop_stt.dart';
import 'services/lan_gate.dart';
import 'services/mic_broker.dart';
import 'services/native_bridge.dart';
import 'services/remote_ai_gateway.dart';
import 'services/remote_host_gateway.dart';
import 'services/secure_recorder.dart';
import 'services/sip_client.dart';
import 'services/voice_print.dart';
import 'services/wake_on_lan.dart';
import 'services/wake_word_controller.dart';

void main() => runApp(const MaximaApp());

class MaximaApp extends StatelessWidget {
    const MaximaApp({super.key});

    @override
    Widget build(BuildContext context) {
        return MaterialApp(
            title: 'Aura Straton Maxima AI',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                brightness: Brightness.dark,
                useMaterial3: true,
                colorSchemeSeed: Colors.blueGrey,
            ),
            home: const InstallationGateway(),
        );
    }
}

class InstallationGateway extends StatefulWidget {
    const InstallationGateway({super.key});

    @override
    State<InstallationGateway> createState() => _InstallationGatewayState();
}

class _InstallationGatewayState extends State<InstallationGateway>
    with TickerProviderStateMixin {
    static const MethodChannel _platform =
        MethodChannel('aura.straton.maxima/accessibility');
    static const EventChannel _wakeWordEvents =
        EventChannel('aura.straton.maxima/wake_word');

    final NativeBridge? _native = NativeBridge.tryCreate();
    RemoteAiGateway? _aiGateway = RemoteAiGateway.fromEnvironment();
    RemoteHostGateway? _remoteHost = RemoteHostGateway.fromEnvironment();
    static const FlutterSecureStorage _settingsStore =
        FlutterSecureStorage();
    final WakeOnLan _wakeOnLan = const WakeOnLan();
    final SipClient _sip = SipClient();
    late final DesktopMicBroker _micBroker = DesktopMicBroker();
    late final SecureRecorder _recorder =
        SecureRecorder(broker: _micBroker);
    late final CognitiveSearch _search =
        CognitiveSearch(gateway: _aiGateway);
    late final WakeWordController _wakeController = WakeWordController(
        accessControl: _accessControl,
        nativeBridge: _native,
        search: _search,
        recorder: _recorder,
        sipClient: _sip,
        nativeEvents: _wakeWordEvents.receiveBroadcastStream(),
        onTranscript: _agentTranscript,
        onPartial: _livePartial,
        onStatus: _speechEngineStatus,
    );

    final TextEditingController _translationInput = TextEditingController();
    final TextEditingController _commandInput = TextEditingController();
    final TextEditingController _wolMacInput = TextEditingController();
    final TextEditingController _hostInput = TextEditingController();

    late final AnimationController _pulseController;
    late final Animation<double> _pulseAnimation;
    late final AnimationController _hueController;

    DesktopSttEngine? _desktopStt;
    AccessControl _accessControl = const AccessControl(ClientRank.premium);
    bool _installed = false;
    bool _expanded = false;
    bool _forceBlack = false;
    bool _requestingPermissions = false;
    bool _translating = false;
    bool _microphoneMuted = false;
    bool _agentMode = false;
    bool _agentBusy = false;

    /// Live (in-progress) recognition text — lets the user see speech
    /// being captured even before a final result exists.
    String _liveTranscript = '';
    Timer? _liveTranscriptTimer;

    /// Suppresses the agent briefly after it speaks so Maxima's own
    /// TTS output cannot retrigger a new query through the mic.
    DateTime _agentCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

    /// When true the core cycles through the hue spectrum; color
    /// commands (red/green/gold/blue) pin a fixed accent instead.
    bool _colorCycle = true;
    bool _greeted = false;

    /// Voice-identification protocol state. The enrolled owner print
    /// persists in secure storage; while [_enrollingVoice] is true,
    /// final transcripts collect samples instead of becoming queries.
    VoicePrint? _voicePrint;
    bool _enrollingVoice = false;
    final List<VoicePrint> _enrollSamples = [];
    String _voiceStatus = 'voice ID: not enrolled';

    /// Short-lived agent activity line ("thinking...", "voice
    /// rejected") so agent behavior is visible, not silent.
    String _agentStatus = '';
    Timer? _agentStatusTimer;

    String _speechModelStatus = 'speech model: not checked';
    String _speechLang = 'en';
    String? _installedModelLang;

    /// Small Vosk acoustic models (~40-60 MB), one per language — the
    /// complete set of lightweight offline models Vosk publishes. The
    /// recognizer holds a single model at a time; switching language
    /// downloads that model and restarts the engine.
    static const Map<String, String> _speechModels = {
        'en': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-en-us-0.15.zip',
        'en-IN': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-en-in-0.4.zip',
        'el': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-el-gr-0.7.zip',
        'es': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-es-0.42.zip',
        'fr': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-fr-0.22.zip',
        'de': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-de-0.15.zip',
        'it': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-it-0.22.zip',
        'pt': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-pt-0.3.zip',
        'nl': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-nl-0.22.zip',
        'ca': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-ca-0.4.zip',
        'pl': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-pl-0.22.zip',
        'uk': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-uk-0.22.zip',
        'ru': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-ru-0.22.zip',
        'tr': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-tr-0.3.zip',
        'ar': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-ar-0.22.zip',
        'fa': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-fa-0.5.zip',
        'hi': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-hi-0.22.zip',
        'gu': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-gu-0.42.zip',
        'ja': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-ja-0.22.zip',
        'ko': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-ko-0.22.zip',
        'zh': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-cn-0.22.zip',
        'vi': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-vn-0.4.zip',
        'uz': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-uz-0.22.zip',
        'kk': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-kz-0.15.zip',
        'cs': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-cs-0.4-rhasspy.zip',
        'sv': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-sv-rhasspy-0.15.zip',
        'eo': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-eo-0.42.zip',
        'br': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-br-0.7.zip',
        'tl': 'https://alphacephei.com/vosk/models/'
            'vosk-model-small-tl-ph-0.6.zip',
    };
    static const Map<String, String> _speechLangNames = {
        'en': 'English',
        'en-IN': 'English (India)',
        'el': 'Greek',
        'es': 'Spanish',
        'fr': 'French',
        'de': 'German',
        'it': 'Italian',
        'pt': 'Portuguese',
        'nl': 'Dutch',
        'ca': 'Catalan',
        'pl': 'Polish',
        'uk': 'Ukrainian',
        'ru': 'Russian',
        'tr': 'Turkish',
        'ar': 'Arabic',
        'fa': 'Persian',
        'hi': 'Hindi',
        'gu': 'Gujarati',
        'ja': 'Japanese',
        'ko': 'Korean',
        'zh': 'Chinese (Mandarin)',
        'vi': 'Vietnamese',
        'uz': 'Uzbek',
        'kk': 'Kazakh',
        'cs': 'Czech',
        'sv': 'Swedish',
        'eo': 'Esperanto',
        'br': 'Breton',
        'tl': 'Tagalog',
    };
    double _batteryThreshold = 15;
    String _name = 'MAXIMA';
    String _targetLanguage = 'Greek';
    String _translationOutput = 'No translated output yet.';
    String _timingOutput = 'Native timing has not been measured.';
    String _gatewayStatus = 'Checking remote AI gateway...';
    Color _color = Colors.blueGrey;

    /// The live accent: hue-cycled while [_colorCycle] is on, else the
    /// fixed color chosen by a voice/text command. Read inside the
    /// pulsing-core AnimatedBuilder so it tracks the animation frame.
    Color get _accent => _colorCycle
        ? HSVColor.fromAHSV(
                1, _hueController.value * 360, 0.85, 0.95)
            .toColor()
        : _color;

    @override
    void initState() {
        super.initState();
        _pulseController = AnimationController(
            duration: const Duration(seconds: 2),
            vsync: this,
        )..repeat(reverse: true);
        _pulseAnimation = Tween<double>(begin: 0.85, end: 1).animate(
            CurvedAnimation(
                parent: _pulseController,
                curve: Curves.easeInOut,
            ),
        );
        // Full-spectrum color morph: one revolution every ~9s,
        // independent of the breathing pulse.
        _hueController = AnimationController(
            duration: const Duration(milliseconds: 9000),
            vsync: this,
        )..repeat();
        unawaited(_restoreHost());
        unawaited(_checkGateway());
        unawaited(_seedKnowledge());
        unawaited(_resolveSecureStorage());
        _registerPlatformEvents();
    }

    bool get _isAndroid => Platform.isAndroid;

    /// True when the host implements the native method channel
    /// (Android and iOS AppDelegates).
    bool get _hasPlatformChannel => Platform.isAndroid || Platform.isIOS;

    /// Native -> Dart events (e.g. iOS battery-threshold trips).
    void _registerPlatformEvents() {
        _platform.setMethodCallHandler((call) async {
            if (call.method == 'batteryLow') {
                unawaited(_desktopStt?.stop());
                if (mounted) {
                    _showMessage(
                        'Battery below threshold; speech engine stopped.',
                    );
                }
            }
            return null;
        });
    }

    Future<void> _resolveSecureStorage() async {
        if (_hasPlatformChannel) {
            try {
                final dir =
                    await _platform.invokeMethod<String>('getAppFilesDir');
                if (dir != null && dir.isNotEmpty) {
                    _wakeController.recordingsDirectory = dir;
                    return;
                }
            } catch (_) {
            }
        }
        _wakeController.recordingsDirectory = Directory.systemTemp.path;
    }

    @override
    void dispose() {
        _translationInput.dispose();
        _commandInput.dispose();
        _wolMacInput.dispose();
        _hostInput.dispose();
        _liveTranscriptTimer?.cancel();
        _agentStatusTimer?.cancel();
        _pulseController.dispose();
        _hueController.dispose();
        _aiGateway?.close();
        _remoteHost?.close();
        unawaited(_desktopStt?.dispose());
        unawaited(_wakeController.dispose());
        super.dispose();
    }

    /// Restores the last successfully used LAN host IP so the app
    /// reconnects automatically across restarts.
    Future<void> _restoreHost() async {
        try {
            final saved = await _settingsStore.read(key: 'maxima_host_ip');
            final savedLang =
                await _settingsStore.read(key: 'maxima_speech_lang');
            _installedModelLang = await _settingsStore.read(
                key: 'maxima_speech_lang_installed',
            );
            final printJson =
                await _settingsStore.read(key: 'maxima_voiceprint');
            if (printJson != null) {
                _voicePrint = VoicePrint.fromJson(
                    jsonDecode(printJson) as Map<String, dynamic>,
                );
                _voiceStatus = 'voice ID: enrolled';
            }
            if (savedLang != null && _speechModels.containsKey(savedLang)) {
                _speechLang = savedLang;
            }
            if (saved != null && saved.isNotEmpty && mounted) {
                _hostInput.text = saved;
                _connectHost();
            }
        } catch (_) {
        }
        // Nothing configured by build or restore: probe the local
        // Wi-Fi so the laptop is found with zero typing.
        if (_aiGateway == null) {
            unawaited(_autoDiscoverHost());
        }
        // A completed first run skips the install gate entirely:
        // on every later launch the app boots straight into the
        // listening core and starts the voice-recognition protocol
        // (permissions are already granted, so this is immediate).
        try {
            final done =
                await _settingsStore.read(key: 'maxima_installed');
            if (done == '1' && !_installed && mounted) {
                setState(() => _installed = true);
                unawaited(_runInstall());
            }
        } catch (_) {
        }
    }

    /// Scans the phone's /24 Wi-Fi subnet for a live Ollama port
    /// (11434). First responsive host wins, then the normal connect
    /// path configures the gateway and host tunnel automatically.
    Future<void> _autoDiscoverHost() async {
        if (_aiGateway != null) return;
        if (mounted) {
            setState(() => _gatewayStatus =
                'Searching for a host on this network...');
        }
        try {
            final interfaces = await NetworkInterface.list(
                type: InternetAddressType.IPv4,
            );
            for (final iface in interfaces) {
                for (final addr in iface.addresses) {
                    final ip = addr.address;
                    if (!isPrivateLanHost(ip) || ip.startsWith('127.')) {
                        continue;
                    }
                    final found = await _scanSubnet(ip);
                    if (found != null && mounted) {
                        _hostInput.text = found;
                        _connectHost();
                        return;
                    }
                }
            }
        } catch (_) {
        }
        if (mounted && _aiGateway == null) {
            setState(() => _gatewayStatus =
                'No host found on this network. Enter the IP manually.');
        }
    }

    Future<String?> _scanSubnet(String localIp) async {
        final prefix = localIp.substring(0, localIp.lastIndexOf('.'));
        const batch = 64;
        for (var start = 1; start < 255; start += batch) {
            final probes = <Future<String?>>[];
            for (var i = start; i < start + batch && i < 255; i++) {
                final host = '$prefix.$i';
                if (host == localIp) continue;
                probes.add(_probeOllama(host));
            }
            for (final result in await Future.wait(probes)) {
                if (result != null) return result;
            }
            if (!mounted) return null;
        }
        return null;
    }

    Future<String?> _probeOllama(String host) async {
        try {
            final socket = await Socket.connect(
                host,
                11434,
                timeout: const Duration(milliseconds: 700),
            );
            socket.destroy();
            return host;
        } catch (_) {
            return null;
        }
    }

    /// Tailscale cannot be bundled or installed silently (Play Store +
    /// VPN consent are mandatory) — this opens its store listing so the
    /// user is two taps away from any-network access.
    Future<void> _openTailscaleStore() async {
        const id = 'com.tailscale.ipn';
        final web = Uri.parse(
            'https://play.google.com/store/apps/details?id=$id',
        );
        try {
            final market = Uri.parse('market://details?id=$id');
            if (await canLaunchUrl(market)) {
                await launchUrl(market);
                return;
            }
            await launchUrl(web, mode: LaunchMode.externalApplication);
        } catch (_) {
            try {
                await launchUrl(web, mode: LaunchMode.externalApplication);
            } catch (_) {
            }
        }
    }

    /// Points the AI gateway + host tunnel at a LAN machine entered
    /// in the REMOTE AI panel. Accepts `192.168.1.27`,
    /// `192.168.1.27:11434` or a full `http://` URL.
    void _connectHost() {
        var host = _hostInput.text.trim();
        if (host.isEmpty) return;
        host = host.replaceAll(RegExp(r'^[a-zA-Z]+://'), '').split('/').first;
        final hostOnly = host.split(':').first;

        try {
            _aiGateway?.close();
            _aiGateway = RemoteAiGateway(
                baseUri: Uri.parse(
                    'http://${host.contains(':') ? host : '$host:11434'}',
                ),
            );
            const token = String.fromEnvironment(
                'REMOTE_HOST_TOKEN',
                defaultValue: 'maxima-local',
            );
            _remoteHost?.close();
            _remoteHost = RemoteHostGateway(
                baseUri: Uri.parse('http://$hostOnly:8080'),
                authToken: token,
            );
            _search.gateway = _aiGateway;
            unawaited(
                _settingsStore.write(key: 'maxima_host_ip', value: host),
            );
            setState(() {
                _gatewayStatus = 'Checking remote AI gateway...';
            });
            unawaited(_checkGateway());
        } catch (error) {
            _showMessage('Invalid host "$host": $error');
        }
    }

    Future<void> _checkGateway() async {
        final gateway = _aiGateway;
        if (gateway == null) {
            if (mounted) {
                setState(() {
                    _gatewayStatus =
                        'Remote AI gateway not configured. Set OLLAMA_BASE_URL.';
                });
            }
            return;
        }

        final healthy = await gateway.isHealthy();
        if (!mounted) return;
        setState(() {
            _gatewayStatus = healthy
                ? 'Remote Qwen gateway online'
                : 'Remote Qwen gateway unreachable';
        });
    }

    Future<void> _seedKnowledge() async {
        await _search.ingestText(
            source: 'core-modules',
            text: 'Native C++23 secure memory purge uses ARM64 counter timing. '
                'The foreground microphone service is controlled by the Android '
                'battery threshold gateway. The Telecom layer exposes a '
                'self-managed VoIP ConnectionService. Remote Qwen inference is '
                'performed through OLLAMA_BASE_URL. Wake-on-LAN and secure '
                'recording are premium capabilities.',
        );
    }

    Future<void> _runInstall() async {
        if (_requestingPermissions) return;

        setState(() => _requestingPermissions = true);
        try {
            // Windows/macOS/Linux have no runtime-permission gate; mic
            // permission is requested by the record broker when the
            // STT engine starts. Android/iOS gate via the platform
            // channel (AVAudioApplication on iOS).
            final bool granted = _hasPlatformChannel
                ? (await _platform
                        .invokeMethod<bool>('requestSystemPermissions') ??
                    false)
                : true;

            if (!mounted) return;
            setState(() => _installed = granted);
            if (!granted) {
                _showMessage('Required permissions were not granted.');
            } else {
                unawaited(
                    _settingsStore.write(
                        key: 'maxima_installed',
                        value: '1',
                    ),
                );
                // FORCE_BLACK halts both animations; re-arm them so a
                // reinstall brings the pulse and color cycle back.
                if (!_pulseController.isAnimating) {
                    _pulseController.repeat(reverse: true);
                }
                if (!_hueController.isAnimating) {
                    _hueController.repeat();
                }
                unawaited(_ensureSpeechModelThenStart());
            }
        } on PlatformException catch (error) {
            if (!mounted) return;
            _showMessage(error.message ?? 'System permission request failed.');
        } finally {
            if (mounted) {
                setState(() => _requestingPermissions = false);
            }
        }
    }

    /// Ensures the Vosk speech model exists (downloading it on first
    /// run) before starting the wake-word engine. Without the model
    /// the recognizer never initializes and speech is silently dropped.
    Future<void> _ensureSpeechModelThenStart() async {
        if (!_hasPlatformChannel) {
            unawaited(_startWakeWordEngine());
            return;
        }
        try {
            final status =
                await _platform.invokeMethod<String>('voskModelStatus');
            final ready = status != null &&
                status.startsWith('ready') &&
                _installedModelLang == _speechLang;
            if (ready) {
                if (mounted) {
                    setState(() => _speechModelStatus = 'speech model: ready');
                }
                unawaited(_startWakeWordEngine());
                return;
            }
            if (mounted) {
                setState(() => _speechModelStatus =
                    'speech model: downloading '
                    '${_speechLangNames[_speechLang]}...');
                _showMessage(
                    'Downloading speech model '
                    '(${_speechLangNames[_speechLang]}, ~50 MB)...',
                );
            }
            await _platform.invokeMethod<String>(
                'downloadVoskModel',
                {'url': _speechModels[_speechLang]},
            );
            _installedModelLang = _speechLang;
            unawaited(
                _settingsStore.write(
                    key: 'maxima_speech_lang_installed',
                    value: _speechLang,
                ),
            );
            if (mounted) {
                setState(() => _speechModelStatus = 'speech model: ready');
                _showMessage('Speech model ready.');
            }
            // Stop any engine running with the previous model so the
            // recognizer reloads the new language.
            try {
                await _platform.invokeMethod<bool>('stopWakeWordEngine');
            } catch (_) {
            }
        } catch (error) {
            if (mounted) {
                setState(() => _speechModelStatus =
                    'speech model: download failed');
                _showMessage('Speech model download failed: $error');
            }
            return;
        }
        unawaited(_startWakeWordEngine());
    }

    void _selectSpeechLang(String? lang) {
        if (lang == null || lang == _speechLang) return;
        setState(() {
            _speechLang = lang;
            _speechModelStatus =
                'speech model: switching to ${_speechLangNames[lang]}...';
        });
        unawaited(
            _settingsStore.write(key: 'maxima_speech_lang', value: lang),
        );
        unawaited(_ensureSpeechModelThenStart());
    }

    /// Live partial transcript straight from Vosk — the proof on
    /// screen that speech is being captured word by word.
    void _livePartial(String transcript) {
        if (!mounted) return;
        _liveTranscriptTimer?.cancel();
        setState(() => _liveTranscript = transcript);
        _liveTranscriptTimer = Timer(
            const Duration(seconds: 4),
            () {
                if (mounted) setState(() => _liveTranscript = '');
            },
        );
    }

    /// Engine status events forwarded by [WakeWordController]:
    /// `model-missing`, `model-error`, `mic-error`, `listening`.
    void _speechEngineStatus(String status, String? detail) {
        if (!mounted) return;
        setState(() => _speechModelStatus = 'speech engine: $status');
        if (status == 'model-missing') {
            unawaited(_ensureSpeechModelThenStart());
        } else if (status == 'listening' && !_greeted) {
            // The voice-recognition protocol announces itself once per
            // app run. First run starts voice-ID enrollment; after
            // that it just confirms the mic is live.
            _greeted = true;
            if (_voicePrint == null) {
                _enrollingVoice = true;
                _enrollSamples.clear();
                setState(() => _voiceStatus =
                    'voice ID: enrolling — speak naturally (0/3)');
                unawaited(
                    _speak(
                        'Maxima online. Voice identification protocol. '
                        'Please say Maxima, then a short sentence, '
                        'three times.',
                        lang: _speechLang,
                    ),
                );
            } else {
                unawaited(
                    _speak(
                        'Maxima online. I am listening. '
                        'Say my name, then your question.',
                        lang: _speechLang,
                    ),
                );
            }
        }
    }

    /// The agent loop: an unmatched final transcript becomes a query
    /// to the remote Qwen gateway; the answer is spoken via TTS and
    /// shown in the output pane.
    ///
    /// Trigger rules: always respond when the transcript contains the
    /// wake name ("maxima"); otherwise only in agent mode (toggle in
    /// the MICROPHONE panel).
    /// Updates the short-lived agent status line under the core and
    /// in the MIC panel, then auto-clears.
    void _setAgentStatus(String status) {
        if (!mounted) return;
        _agentStatusTimer?.cancel();
        setState(() => _agentStatus = status);
        _agentStatusTimer = Timer(
            const Duration(seconds: 6),
            () {
                if (mounted) setState(() => _agentStatus = '');
            },
        );
    }

    /// Collects one voiceprint sample during enrollment. Three
    /// utterances become the stored owner print.
    Future<void> _enrollVoiceSample(Uint8List audio) async {
        final features = extractVoiceFeatures(audio);
        if (features == null) return;
        _enrollSamples.add(VoicePrint(Float64List.fromList(features)));
        final n = _enrollSamples.length;
        if (n < 3) {
            setState(() => _voiceStatus =
                'voice ID: enrolling — speak naturally ($n/3)');
            return;
        }
        _voicePrint = VoicePrint.average(_enrollSamples);
        _enrollSamples.clear();
        _enrollingVoice = false;
        setState(() => _voiceStatus = 'voice ID: enrolled');
        unawaited(
            _settingsStore.write(
                key: 'maxima_voiceprint',
                value: jsonEncode(_voicePrint!.toJson()),
            ),
        );
        await _speak(
            'Voice enrolled. I will only answer to you.',
            lang: _speechLang,
        );
    }

    /// Compares the utterance audio against the enrolled owner print.
    /// Utterances without usable audio are allowed through (engine
    /// builds without the ring buffer still work).
    bool _verifyVoice(Uint8List? audio) {
        final enrolled = _voicePrint;
        if (enrolled == null || audio == null || audio.length < 16000) {
            return true;
        }
        final features = extractVoiceFeatures(audio);
        if (features == null) return true;
        final score = enrolled.similarity(
            VoicePrint(Float64List.fromList(features)),
        );
        if (score >= voiceVerifyThreshold) return true;
        _setAgentStatus(
            'voice rejected (${score.toStringAsFixed(2)})',
        );
        return false;
    }

    /// Restarts the voice-ID enrollment (e.g. a different owner).
    void _reenrollVoice() {
        setState(() {
            _voicePrint = null;
            _enrollingVoice = true;
            _enrollSamples.clear();
            _voiceStatus =
                'voice ID: enrolling — speak naturally (0/3)';
        });
        unawaited(_settingsStore.delete(key: 'maxima_voiceprint'));
        unawaited(
            _speak(
                'Voice identification reset. Please say Maxima, '
                'then a short sentence, three times.',
                lang: _speechLang,
            ),
        );
    }

    Future<void> _agentTranscript(
        String transcript,
        Uint8List? audio,
    ) async {
        if (mounted) setState(() => _liveTranscript = '');
        if (_agentBusy) return;
        if (DateTime.now().isBefore(_agentCooldownUntil)) return;

        // Voice-ID enrollment consumes utterances instead of
        // answering them.
        if (_enrollingVoice) {
            if (audio != null && audio.length > 16000) {
                unawaited(_enrollVoiceSample(audio));
            }
            return;
        }
        if (!_verifyVoice(audio)) return;

        final lower = transcript.toLowerCase();
        // Tolerant wake-name match: small Vosk models split or bend
        // the name ("maxi ma", "max ima", "maximum", "maxine"), and
        // the Greek model transcribes it as "μάξιμα". Any word that
        // begins with "max"/"μάξ"/"μαξ" is treated as the wake name.
        final wakeMatch = RegExp(
            r'\b(max\w*|μάξιμα|μαξιμα|μάξιμ)\b',
        ).firstMatch(lower);
        String? query;
        if (wakeMatch != null) {
            var after = transcript.substring(wakeMatch.end).trim();
            // The tail of a split wake name ("ma", "i ma") sometimes
            // survives as a leading fragment of the query — drop it.
            after = after.replaceFirst(
                RegExp(r'^(ma|i\s*ma|ima|ina|imum|ine|ime)\b\s*'),
                '',
            );
            if (after.length < 3) {
                await _speak('I am listening.', lang: _speechLang);
                _agentCooldownUntil = DateTime.now().add(
                    const Duration(seconds: 3),
                );
                return;
            }
            query = after;
        } else if (_agentMode) {
            query = transcript.trim();
        }
        if (query == null || query.length < 3) return;

        final gateway = _aiGateway;
        if (gateway == null) {
            _setAgentStatus('no gateway — connect the host in REMOTE AI');
            _showMessage('Set the host IP in REMOTE AI to talk to Maxima.');
            return;
        }

        _setAgentStatus('thinking…');
        _agentBusy = true;
        try {
            final answer = await gateway.generate(
                query,
                system: 'You are Maxima, a concise voice assistant. '
                    'Answer briefly in plain spoken sentences, in the '
                    'same language the user spoke.',
            );
            if (!mounted || answer.isEmpty) return;
            setState(() => _translationOutput = 'You: $transcript\n\n$answer');
            _setAgentStatus('answered');
            await _speak(answer, lang: _speechLang);
        } catch (error) {
            _setAgentStatus('gateway error — check REMOTE AI status');
            _showMessage('Agent query failed: $error');
        } finally {
            _agentBusy = false;
            _agentCooldownUntil = DateTime.now().add(
                const Duration(seconds: 3),
            );
        }
    }

    Future<void> _speak(String text, {String? lang}) async {
        if (!_hasPlatformChannel) return;
        try {
            await _platform.invokeMethod<void>(
                'speakText',
                {'text': text, if (lang != null) 'lang': lang},
            );
        } catch (_) {
        }
    }

    Future<void> _startWakeWordEngine() async {
        if (!_isAndroid) {
            await _startDesktopStt();
            return;
        }
        try {
            await _platform.invokeMethod<bool>('startWakeWordEngine');
        } catch (error) {
            _showMessage('Wake-word engine unavailable.');
        }
    }

    /// Desktop/iOS speech path: `record` mic stream -> libvosk FFI
    /// recognizer -> wake-phrase events into [WakeWordController].
    Future<void> _startDesktopStt() async {
        final engine = _desktopStt ??= await DesktopSttEngine.tryCreateAsync(
            broker: _micBroker,
        );
        if (engine == null) {
            _showMessage(
                'Desktop speech stack needs libvosk and a model. '
                'Set MAXIMA_VOSK_LIB and MAXIMA_VOSK_MODEL, or place a '
                'model under models/vosk-model.',
            );
            return;
        }
        _wakeController.attach(engine.events);
        final ok = await engine.start();
        _showMessage(
            ok
                ? 'Desktop wake-word engine online.'
                : 'Microphone permission was denied.',
        );
    }

    Future<void> _executePurge() async {
        try {
            await _platform.invokeMethod<void>('stopSpeech');
        } catch (_) {
        }

        NativeTiming? timing;
        try {
            timing = _native?.measureSecureWipe();
        } catch (_) {
            timing = null;
        }
        _pulseController.stop();
        _hueController.stop();
        if (!mounted) return;
        setState(() {
            _timingOutput = timing == null
                ? 'Native bridge unavailable.'
                : '${timing.cycles} cycles / '
                    '${timing.nanoseconds.toStringAsFixed(2)} ns';
            _forceBlack = true;
            _expanded = false;
            _installed = false;
        });
    }

    void _measureTiming() {
        final native = _native;
        if (native == null) {
            setState(() => _timingOutput = 'Native bridge unavailable.');
            return;
        }

        try {
            final timing = native.measureSecureWipe();
            final thresholdCycles =
                (timing.frequency * 0.000000020).ceil();
            final compromised = !native.runtimeIntegrityOk ||
                native.purgeIfCompromised(timing.cycles, thresholdCycles);

            setState(() {
                _timingOutput =
                    '${timing.cycles} counter cycles / '
                    '${timing.nanoseconds.toStringAsFixed(2)} ns / '
                    'cache block ${timing.cacheZeroBlockSize} bytes';
                _forceBlack = compromised;
            });
        } catch (_) {
            setState(() => _timingOutput = 'Native timing call failed.');
        }
    }

    Future<void> _translate() async {
        final gateway = _aiGateway;
        final text = _translationInput.text.trim();
        if (gateway == null) {
            _showMessage('Set OLLAMA_BASE_URL before using remote translation.');
            return;
        }
        if (text.isEmpty) return;

        setState(() => _translating = true);
        try {
            final translated = await gateway.translate(
                text: text,
                targetLanguage: _targetLanguage,
            );
            if (!mounted) return;
            setState(() => _translationOutput = translated);
            await _speak(
                translated,
                lang: _targetLanguage == 'Greek' ? 'el' : 'en',
            );
        } catch (error) {
            if (!mounted) return;
            _showMessage('Translation failed: $error');
        } finally {
            if (mounted) setState(() => _translating = false);
        }
    }

    Future<void> _retrieve() async {
        final query = _translationInput.text.trim();
        if (query.isEmpty) return;

        final results = await _search.search(query);
        if (!mounted) return;
        setState(() {
            _translationOutput = results.isEmpty
                ? 'No indexed results.'
                : results
                    .map(
                        (result) =>
                            '[${result.score.toStringAsFixed(3)}] ${result.text}',
                    )
                    .join('\n\n');
        });
    }

    Future<void> _setMicrophoneMuted(bool muted) async {
        if (!_isAndroid) {
            // Desktop/iOS: the shared mic broker drops frames while
            // muted; on iOS the channel call is a bookkeeping no-op.
            _micBroker.muted = muted;
            if (Platform.isIOS) {
                try {
                    await _platform.invokeMethod<bool>(
                        'setMicrophoneMuted',
                        {'muted': muted},
                    );
                } catch (_) {
                }
            }
            setState(() => _microphoneMuted = muted);
            return;
        }
        try {
            final accepted = await _platform.invokeMethod<bool>(
                'setMicrophoneMuted',
                {'muted': muted},
            );
            if (!mounted) return;
            setState(() => _microphoneMuted = accepted == true);
        } on PlatformException catch (error) {
            _showMessage(error.message ?? 'Unable to change microphone state.');
        }
    }

    Future<void> _setBatteryThreshold(double value) async {
        setState(() => _batteryThreshold = value);
        if (!_hasPlatformChannel) return;
        try {
            await _platform.invokeMethod<void>(
                'setBatteryThreshold',
                {'threshold': value.round()},
            );
        } on PlatformException catch (error) {
            _showMessage(error.message ?? 'Unable to update battery threshold.');
        }
    }

    Future<void> _speakStatus() async {
        final text =
            '$_name core is active. Gateway status: $_gatewayStatus. '
            'Battery cutoff is ${_batteryThreshold.round()} percent.';
        if (!_hasPlatformChannel) {
            _showMessage('Text-to-speech is not available on this platform.');
            return;
        }
        try {
            await _platform.invokeMethod<void>('speakText', {'text': text});
        } on PlatformException catch (error) {
            _showMessage(error.message ?? 'Text-to-speech failed.');
        }
    }

    Future<void> _sendWakeOnLan() async {
        if (!_accessControl.allows(SecureCapability.wakeOnLan)) {
            _showMessage('Wake-on-LAN requires a premium rank.');
            return;
        }
        try {
            await _wakeOnLan.send(_wolMacInput.text.trim());
            _showMessage('Wake-on-LAN packet sent.');
        } catch (error) {
            _showMessage('Wake-on-LAN failed: $error');
        }
    }

    void _applyCommand() {
        final command = _commandInput.text.trim().toLowerCase();
        if (command.isEmpty) return;

        if (command.contains('purge') || command.contains('force black')) {
            unawaited(_executePurge());
        } else if (command.contains('expand')) {
            setState(() => _expanded = true);
        } else if (command.contains('collapse')) {
            setState(() => _expanded = false);
        } else if (command.startsWith('name ')) {
            setState(() {
                _name = _commandInput.text.substring(5).trim().toUpperCase();
            });
        } else if (command.contains('rainbow') ||
            command.contains('spectrum') ||
            command.contains('auto color')) {
            setState(() => _colorCycle = true);
        } else if (command.contains('red')) {
            setState(() {
                _color = Colors.redAccent;
                _colorCycle = false;
            });
        } else if (command.contains('green')) {
            setState(() {
                _color = Colors.greenAccent;
                _colorCycle = false;
            });
        } else if (command.contains('gold')) {
            setState(() {
                _color = Colors.amberAccent;
                _colorCycle = false;
            });
        } else if (command.contains('blue')) {
            setState(() {
                _color = Colors.lightBlueAccent;
                _colorCycle = false;
            });
        }
        _commandInput.clear();
    }

    void _showMessage(String message) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
        );
    }

    @override
    Widget build(BuildContext context) {
        if (_forceBlack) {
            return const Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                    child: Text(
                        'FORCE_BLACK ACTIVE',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                        ),
                    ),
                ),
            );
        }

        return Scaffold(
            backgroundColor: Colors.black,
            body: Center(
                child: !_installed
                    ? ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                        ),
                        onPressed:
                            _requestingPermissions ? null : _runInstall,
                        child: Text(
                            _requestingPermissions
                                ? 'ΓΙΝΕΤΑΙ ΕΓΚΑΤΑΣΤΑΣΗ...'
                                : 'ΑΠΟΔΟΧΗ & ΕΓΚΑΤΑΣΤΑΣΗ',
                            style: const TextStyle(fontSize: 18),
                        ),
                    )
                    : _buildPulsingCore(),
            ),
        );
    }

    Widget _buildPulsingCore() {
        return AnimatedBuilder(
            animation: Listenable.merge([_pulseController, _hueController]),
            builder: (context, child) {
                final hue = _hueController.value * 360;
                // Default mode morphs through the full spectrum; a
                // fixed color command (red/green/gold/blue) pins it.
                final accent = _colorCycle
                    ? HSVColor.fromAHSV(1, hue, 0.85, 0.95).toColor()
                    : _color;
                final complement = _colorCycle
                    ? HSVColor.fromAHSV(1, (hue + 140) % 360, 0.9, 0.85)
                        .toColor()
                    : _color;
                final pulse = _pulseAnimation.value;
                return Container(
                    width: double.infinity,
                    height: double.infinity,
                    decoration: BoxDecoration(
                        // The morphing color field wraps the whole
                        // screen, not just the circle.
                        gradient: RadialGradient(
                            radius: 1.4,
                            colors: [
                                accent.withAlpha(
                                    (55 + 110 * pulse).round(),
                                ),
                                complement.withAlpha(
                                    (20 + 45 * pulse).round(),
                                ),
                                Colors.black,
                            ],
                            stops: const [0.0, 0.55, 1.0],
                        ),
                    ),
                    child: Center(
                        child: AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            width: _expanded
                                ? MediaQuery.sizeOf(context).width * 0.96
                                : MediaQuery.sizeOf(context).width * 0.45,
                            height: _expanded
                                ? MediaQuery.sizeOf(context).height * 0.94
                                : MediaQuery.sizeOf(context).width * 0.45,
                            decoration: BoxDecoration(
                                color: Colors.black.withAlpha(210),
                                // Always a rectangle: the collapsed
                                // "circle" is just a borderRadius
                                // clamped to half the box, so the
                                // expand/collapse lerp never mixes
                                // BoxShape.circle with a radius.
                                borderRadius: BorderRadius.circular(
                                    _expanded ? 16 : 2000,
                                ),
                                border: Border.all(
                                    color: accent,
                                    width: 1.5 + 3 * pulse,
                                ),
                                boxShadow: [
                                    BoxShadow(
                                        color: accent.withAlpha(
                                            (60 +
                                                    190 * pulse)
                                                .round(),
                                        ),
                                        blurRadius: 30 + 70 * pulse,
                                        spreadRadius: 3 + 12 * pulse,
                                    ),
                                    BoxShadow(
                                        color: complement.withAlpha(
                                            (40 + 120 * pulse).round(),
                                        ),
                                        blurRadius: 60 + 90 * pulse,
                                        spreadRadius: 8 + 18 * pulse,
                                    ),
                                ],
                            ),
                            child: Center(
                                child: _expanded
                                    ? _buildDashboard()
                                    : GestureDetector(
                                        onTap: () => setState(
                                            () => _expanded = true,
                                        ),
                                        child: Padding(
                                            padding:
                                                const EdgeInsets.all(12),
                                            child: Column(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: [
                                                    Text(
                                                        _name,
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: TextStyle(
                                                            color: accent,
                                                            fontSize: 22,
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold,
                                                            letterSpacing: 2,
                                                            shadows: [
                                                                Shadow(
                                                                    color: accent
                                                                        .withAlpha(
                                                                            220,
                                                                        ),
                                                                    blurRadius:
                                                                        22,
                                                                ),
                                                                Shadow(
                                                                    color:
                                                                        complement,
                                                                    blurRadius:
                                                                        8,
                                                                ),
                                                            ],
                                                        ),
                                                    ),
                                                    const SizedBox(
                                                        height: 6,
                                                    ),
                                                    Text(
                                                        _liveTranscript
                                                                .isNotEmpty
                                                            ? _liveTranscript
                                                            : _agentStatus
                                                                    .isNotEmpty
                                                                ? _agentStatus
                                                                : _enrollingVoice
                                                                    ? 'ENROLL YOUR VOICE'
                                                                    : 'LISTENING',
                                                        textAlign:
                                                            TextAlign.center,
                                                        maxLines: 2,
                                                        overflow:
                                                            TextOverflow
                                                                .ellipsis,
                                                        style: TextStyle(
                                                            color:
                                                                (_liveTranscript
                                                                            .isNotEmpty ||
                                                                        _agentStatus
                                                                            .isNotEmpty ||
                                                                        _enrollingVoice)
                                                                    ? accent
                                                                    : Colors
                                                                        .white38,
                                                            fontSize: 11,
                                                            fontStyle:
                                                                _liveTranscript
                                                                        .isNotEmpty
                                                                    ? FontStyle
                                                                        .normal
                                                                    : _enrollingVoice
                                                                        ? FontStyle
                                                                            .normal
                                                                        : FontStyle
                                                                            .italic,
                                                            letterSpacing: 1,
                                                        ),
                                                    ),
                                                ],
                                            ),
                                        ),
                                    ),
                            ),
                        ),
                    ),
                );
            },
        );
    }

    Widget _buildDashboard() {
        return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                children: [
                    Row(
                        children: [
                            Expanded(
                                child: Text(
                                    '$_name CORE - ONLINE',
                                    style: TextStyle(
                                        color: _accent,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                    ),
                                ),
                            ),
                            DropdownButton<ClientRank>(
                                value: _accessControl.rank,
                                onChanged: (rank) {
                                    if (rank == null) return;
                                    setState(() {
                                        _accessControl = AccessControl(rank);
                                    });
                                },
                                items: const [
                                    DropdownMenuItem(
                                        value: ClientRank.standard,
                                        child: Text('STANDARD'),
                                    ),
                                    DropdownMenuItem(
                                        value: ClientRank.premium,
                                        child: Text('PREMIUM'),
                                    ),
                                ],
                            ),
                            IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    setState(() => _expanded = false),
                            ),
                        ],
                    ),
                    TextField(
                        controller: _commandInput,
                        decoration: InputDecoration(
                            labelText: 'Voice-command text bridge',
                            hintText:
                                'expand, collapse, name AURA, red, purge',
                            suffixIcon: IconButton(
                                icon: const Icon(Icons.play_arrow),
                                onPressed: _applyCommand,
                            ),
                        ),
                        onSubmitted: (_) => _applyCommand(),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                        child: LayoutBuilder(
                            builder: (context, constraints) {
                                final left = _translationPane();
                                final right = _operationsPane();
                                if (constraints.maxWidth >= 760) {
                                    return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                            Expanded(child: left),
                                            const SizedBox(width: 10),
                                            Expanded(
                                                child:
                                                    SingleChildScrollView(
                                                    child: right,
                                                ),
                                            ),
                                        ],
                                    );
                                }
                                return ListView(
                                    children: [
                                        SizedBox(height: 460, child: left),
                                        const SizedBox(height: 10),
                                        right,
                                    ],
                                );
                            },
                        ),
                    ),
                ],
            ),
        );
    }

    Widget _translationPane() {
        return Card(
            color: Colors.grey[950],
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        Text(
                            'TRANSLATION / RETRIEVAL',
                            style: TextStyle(
                                color: _accent,
                                fontWeight: FontWeight.bold,
                            ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                            flex: 2,
                            child: TextField(
                                controller: _translationInput,
                                maxLines: null,
                                expands: true,
                                decoration: const InputDecoration(
                                    hintText:
                                        'Enter text in any supported language',
                                    border: OutlineInputBorder(),
                                ),
                            ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                                SizedBox(
                                    width: 160,
                                    child: DropdownButtonFormField<String>(
                                        initialValue: _targetLanguage,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                            labelText: 'Target language',
                                        ),
                                        items: const [
                                            DropdownMenuItem(
                                                value: 'Greek',
                                                child: Text('Greek'),
                                            ),
                                            DropdownMenuItem(
                                                value: 'English',
                                                child: Text('English'),
                                            ),
                                        ],
                                        onChanged: (value) {
                                            if (value == null) return;
                                            setState(() {
                                                _targetLanguage = value;
                                            });
                                        },
                                    ),
                                ),
                                FilledButton(
                                    onPressed:
                                        _translating ? null : _translate,
                                    child: const Text('Translate'),
                                ),
                                OutlinedButton(
                                    onPressed: _retrieve,
                                    child: const Text('Retrieve'),
                                ),
                            ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                            flex: 3,
                            child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white24),
                                    borderRadius: BorderRadius.circular(8),
                                ),
                                child: SingleChildScrollView(
                                    child: SelectableText(
                                        _translationOutput,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                        ),
                                    ),
                                ),
                            ),
                        ),
                    ],
                ),
            ),
        );
    }

    Widget _operationsPane() {
        return LayoutBuilder(
            builder: (context, constraints) {
                final twoCols = constraints.maxWidth >= 520;
                final tileWidth = twoCols
                    ? (constraints.maxWidth - 10) / 2
                    : constraints.maxWidth;
                Widget tile(Widget child) =>
                    SizedBox(width: tileWidth, child: child);
                return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        _panel(
                            title: 'HARDWARE TIMING',
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    Text(
                                        _timingOutput,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                        ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                            FilledButton.tonal(
                                                onPressed: _measureTiming,
                                                child: const Text(
                                                    'Measure purge',
                                                ),
                                            ),
                                            FilledButton(
                                                style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.red,
                                                ),
                                                onPressed: _executePurge,
                                                child: const Text(
                                                    'FORCE_BLACK',
                                                ),
                                            ),
                                        ],
                                    ),
                                ],
                            ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                                tile(
                                    _panel(
                                        title: 'MICROPHONE',
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                                Row(
                                                    children: [
                                                        const Expanded(
                                                            child: Text(
                                                                'Compliant mute',
                                                                style:
                                                                    TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                ),
                                                            ),
                                                        ),
                                                        Switch(
                                                            value:
                                                                _microphoneMuted,
                                                            onChanged:
                                                                _setMicrophoneMuted,
                                                        ),
                                                    ],
                                                ),
                                                Row(
                                                    children: [
                                                        const Expanded(
                                                            child: Text(
                                                                'Agent mode (all speech -> Qwen)',
                                                                style:
                                                                    TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                ),
                                                            ),
                                                        ),
                                                        Switch(
                                                            value: _agentMode,
                                                            onChanged: (v) =>
                                                                setState(() =>
                                                                    _agentMode =
                                                                        v),
                                                        ),
                                                    ],
                                                ),
                                                Row(
                                                    children: [
                                                        const Expanded(
                                                            child: Text(
                                                                'Speech language',
                                                                style:
                                                                    TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                ),
                                                            ),
                                                        ),
                                                        DropdownButton<String>(
                                                            value:
                                                                _speechLang,
                                                            isDense: true,
                                                            underline:
                                                                const SizedBox
                                                                    .shrink(),
                                                            items:
                                                                _speechLangNames
                                                                    .entries
                                                                    .map(
                                                                (e) =>
                                                                    DropdownMenuItem(
                                                                    value:
                                                                        e.key,
                                                                    child: Text(
                                                                        e.value,
                                                                        style:
                                                                            const TextStyle(
                                                                            fontSize:
                                                                                12,
                                                                        ),
                                                                    ),
                                                                ),
                                                            )
                                                                    .toList(),
                                                            onChanged:
                                                                _selectSpeechLang,
                                                        ),
                                                    ],
                                                ),
                                                if (_liveTranscript
                                                    .isNotEmpty)
                                                    Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Text(
                                                            'hearing: '
                                                            '$_liveTranscript',
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                color: Colors
                                                                    .cyanAccent,
                                                                fontSize: 11,
                                                            ),
                                                        ),
                                                    ),
                                                if (_agentStatus.isNotEmpty)
                                                    Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Text(
                                                            'agent: '
                                                            '$_agentStatus',
                                                            style:
                                                                const TextStyle(
                                                                color: Colors
                                                                    .amberAccent,
                                                                fontSize: 11,
                                                            ),
                                                        ),
                                                    ),
                                                Row(
                                                    children: [
                                                        Expanded(
                                                            child: Text(
                                                                _voiceStatus,
                                                                style:
                                                                    const TextStyle(
                                                                    color: Colors
                                                                        .white38,
                                                                    fontSize:
                                                                        10,
                                                                ),
                                                            ),
                                                        ),
                                                        TextButton(
                                                            onPressed:
                                                                _reenrollVoice,
                                                            child: const Text(
                                                                'Re-enroll',
                                                                style:
                                                                    TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                ),
                                                            ),
                                                        ),
                                                    ],
                                                ),
                                                Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: Text(
                                                        _speechModelStatus,
                                                        style: const TextStyle(
                                                            color:
                                                                Colors.white38,
                                                            fontSize: 10,
                                                        ),
                                                    ),
                                                ),
                                            ],
                                        ),
                                    ),
                                ),
                                tile(
                                    _panel(
                                        title: 'BATTERY GATEWAY',
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                                Text(
                                                    '${_batteryThreshold.round()}%',
                                                    style: const TextStyle(
                                                        color: Colors.white70,
                                                    ),
                                                ),
                                                Slider(
                                                    value: _batteryThreshold,
                                                    min: 5,
                                                    max: 95,
                                                    divisions: 18,
                                                    onChanged:
                                                        _setBatteryThreshold,
                                                ),
                                            ],
                                        ),
                                    ),
                                ),
                                tile(
                                    _panel(
                                        title: 'REMOTE AI',
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                                Text(
                                                    '$_gatewayStatus\nHost tunnel: '
                                                    '${_remoteHost == null ? 'not configured' : 'configured'}',
                                                    style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 11,
                                                    ),
                                                ),
                                                const SizedBox(height: 4),
                                                TextField(
                                                    controller: _hostInput,
                                                    keyboardType:
                                                        TextInputType.url,
                                                    decoration:
                                                        const InputDecoration(
                                                        isDense: true,
                                                        hintText:
                                                            'Host IP e.g. 192.168.1.27',
                                                    ),
                                                    onSubmitted: (_) =>
                                                        _connectHost(),
                                                ),
                                                const SizedBox(height: 4),
                                                FilledButton.tonal(
                                                    onPressed: _connectHost,
                                                    child: const Text(
                                                        'Connect',
                                                    ),
                                                ),
                                                Row(
                                                    children: [
                                                        Expanded(
                                                            child:
                                                                TextButton(
                                                                onPressed:
                                                                    _autoDiscoverHost,
                                                                child:
                                                                    const Text(
                                                                    'Find on Wi-Fi',
                                                                    style:
                                                                        TextStyle(
                                                                        fontSize:
                                                                            10,
                                                                    ),
                                                                ),
                                                            ),
                                                        ),
                                                        Expanded(
                                                            child:
                                                                TextButton(
                                                                onPressed:
                                                                    _openTailscaleStore,
                                                                child:
                                                                    const Text(
                                                                    'Anywhere via Tailscale',
                                                                    style:
                                                                        TextStyle(
                                                                        fontSize:
                                                                            10,
                                                                        ),
                                                                    ),
                                                            ),
                                                        ),
                                                    ],
                                                ),
                                            ],
                                        ),
                                    ),
                                ),
                                tile(
                                    _panel(
                                        title: 'VOIP / TELECOM',
                                        child: Text(
                                            !_accessControl.allows(
                                                    SecureCapability
                                                        .voipPipeline)
                                                ? 'Premium capability locked'
                                                : (_native?.voipPipelineReady ==
                                                        true
                                                    ? 'PJSIP native link active'
                                                    : 'ConnectionService registered'),
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 11,
                                            ),
                                        ),
                                    ),
                                ),
                                tile(
                                    _panel(
                                        title: 'TTS ANALYTICS',
                                        child: FilledButton.tonal(
                                            onPressed: _speakStatus,
                                            child: const Text('Speak status'),
                                        ),
                                    ),
                                ),
                                tile(
                                    _panel(
                                        title: 'WAKE-ON-LAN',
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                                TextField(
                                                    controller: _wolMacInput,
                                                    decoration:
                                                        const InputDecoration(
                                                        isDense: true,
                                                        hintText:
                                                            'AA:BB:CC:DD:EE:FF',
                                                    ),
                                                ),
                                                const SizedBox(height: 4),
                                                FilledButton.tonal(
                                                    onPressed: _sendWakeOnLan,
                                                    child: const Text('Send'),
                                                ),
                                            ],
                                        ),
                                    ),
                                ),
                            ],
                        ),
                    ],
                );
            },
        );
    }

    Widget _panel({required String title, required Widget child}) {
        return Card(
            color: Colors.grey[900],
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Text(
                            title,
                            style: TextStyle(
                                color: _accent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                            ),
                        ),
                        const SizedBox(height: 8),
                        child,
                    ],
                ),
            ),
        );
    }
}
