import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/access_control.dart';
import 'services/cognitive_search.dart';
import 'services/desktop_stt.dart';
import 'services/mic_broker.dart';
import 'services/native_bridge.dart';
import 'services/remote_ai_gateway.dart';
import 'services/remote_host_gateway.dart';
import 'services/secure_recorder.dart';
import 'services/sip_client.dart';
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
    final RemoteAiGateway? _aiGateway = RemoteAiGateway.fromEnvironment();
    final RemoteHostGateway? _remoteHost = RemoteHostGateway.fromEnvironment();
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
    );

    final TextEditingController _translationInput = TextEditingController();
    final TextEditingController _commandInput = TextEditingController();
    final TextEditingController _wolMacInput = TextEditingController();

    late final AnimationController _pulseController;
    late final Animation<double> _pulseAnimation;

    DesktopSttEngine? _desktopStt;
    AccessControl _accessControl = const AccessControl(ClientRank.premium);
    bool _installed = false;
    bool _expanded = false;
    bool _forceBlack = false;
    bool _requestingPermissions = false;
    bool _translating = false;
    bool _microphoneMuted = false;
    double _batteryThreshold = 15;
    String _name = 'MAXIMA';
    String _targetLanguage = 'Greek';
    String _translationOutput = 'No translated output yet.';
    String _timingOutput = 'Native timing has not been measured.';
    String _gatewayStatus = 'Checking remote AI gateway...';
    Color _color = Colors.blueGrey;

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
        _pulseController.dispose();
        _aiGateway?.close();
        _remoteHost?.close();
        unawaited(_desktopStt?.dispose());
        unawaited(_wakeController.dispose());
        super.dispose();
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
                unawaited(_startWakeWordEngine());
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
            if (_hasPlatformChannel) {
                await _platform.invokeMethod<void>(
                    'speakText',
                    {'text': translated},
                );
            }
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
        } else if (command.contains('red')) {
            setState(() => _color = Colors.redAccent);
        } else if (command.contains('green')) {
            setState(() => _color = Colors.greenAccent);
        } else if (command.contains('gold')) {
            setState(() => _color = Colors.amberAccent);
        } else if (command.contains('blue')) {
            setState(() => _color = Colors.lightBlueAccent);
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
            animation: _pulseAnimation,
            builder: (context, child) {
                return Container(
                    width: double.infinity,
                    height: double.infinity,
                    color: _color.withAlpha(
                        (12 * _pulseAnimation.value).round(),
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
                                color: Colors.black,
                                shape: _expanded
                                    ? BoxShape.rectangle
                                    : BoxShape.circle,
                                border: Border.all(
                                    color: _color,
                                    width: 3 * _pulseAnimation.value,
                                ),
                                borderRadius: _expanded
                                    ? BorderRadius.circular(16)
                                    : null,
                            ),
                            child: Center(
                                child: _expanded
                                    ? _buildDashboard()
                                    : GestureDetector(
                                        onTap: () => setState(
                                            () => _expanded = true,
                                        ),
                                        child: Text(
                                            _name,
                                            style: TextStyle(
                                                color: _color,
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 2,
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
                                        color: _color,
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
                                            CrossAxisAlignment.stretch,
                                        children: [
                                            Expanded(child: left),
                                            const SizedBox(width: 10),
                                            Expanded(child: right),
                                        ],
                                    );
                                }
                                return ListView(
                                    children: [
                                        SizedBox(height: 360, child: left),
                                        const SizedBox(height: 10),
                                        SizedBox(height: 560, child: right),
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
                                color: _color,
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
                        Row(
                            children: [
                                Expanded(
                                    child: DropdownButtonFormField<String>(
                                        initialValue: _targetLanguage,
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
                                const SizedBox(width: 8),
                                FilledButton(
                                    onPressed:
                                        _translating ? null : _translate,
                                    child: const Text('Translate'),
                                ),
                                const SizedBox(width: 8),
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
        return Column(
            children: [
                SizedBox(
                    height: 170,
                    child: _panel(
                        title: 'HARDWARE TIMING',
                        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Text(
                                _timingOutput,
                                style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                                spacing: 8,
                                children: [
                                    FilledButton.tonal(
                                        onPressed: _measureTiming,
                                        child: const Text('Measure purge'),
                                    ),
                                    FilledButton(
                                        style: FilledButton.styleFrom(
                                            backgroundColor: Colors.red,
                                        ),
                                        onPressed: _executePurge,
                                        child: const Text('FORCE_BLACK'),
                                    ),
                                ],
                            ),
                        ],
                    ),
                ),
                ),
                const SizedBox(height: 10),
                Expanded(
                    child: GridView.count(
                        crossAxisCount: 2,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 1.55,
                        children: [
                            _panel(
                                title: 'MICROPHONE',
                                child: SwitchListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                        'Compliant mute',
                                        style: TextStyle(fontSize: 12),
                                    ),
                                    value: _microphoneMuted,
                                    onChanged: _setMicrophoneMuted,
                                ),
                            ),
                            _panel(
                                title: 'BATTERY GATEWAY',
                                child: Column(
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
                                            onChanged: _setBatteryThreshold,
                                        ),
                                    ],
                                ),
                            ),
                            _panel(
                                title: 'REMOTE AI',
                                child: Text(
                                    '$_gatewayStatus\nHost tunnel: '
                                    '${_remoteHost == null ? 'not configured' : 'configured'}',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                    ),
                                ),
                            ),
                            _panel(
                                title: 'VOIP / TELECOM',
                                child: Text(
                                    !_accessControl.allows(
                                            SecureCapability.voipPipeline)
                                        ? 'Premium capability locked'
                                        : (_native?.voipPipelineReady == true
                                            ? 'PJSIP native link active'
                                            : 'ConnectionService registered'),
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                    ),
                                ),
                            ),
                            _panel(
                                title: 'TTS ANALYTICS',
                                child: FilledButton.tonal(
                                    onPressed: _speakStatus,
                                    child: const Text('Speak status'),
                                ),
                            ),
                            _panel(
                                title: 'WAKE-ON-LAN',
                                child: Column(
                                    children: [
                                        TextField(
                                            controller: _wolMacInput,
                                            decoration: const InputDecoration(
                                                isDense: true,
                                                hintText: 'AA:BB:CC:DD:EE:FF',
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
                        ],
                    ),
                ),
            ],
        );
    }

    Widget _panel({required String title, required Widget child}) {
        return Card(
            color: Colors.grey[900],
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Text(
                            title,
                            style: TextStyle(
                                color: _color,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                            ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(child: child),
                    ],
                ),
            ),
        );
    }
}
