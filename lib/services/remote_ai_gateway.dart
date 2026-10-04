import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lan_gate.dart';

class RemoteAiGateway {
    RemoteAiGateway({
        required this.baseUri,
        this.generationModel = 'qwen2.5:7b-instruct',
        this.embeddingModel = 'nomic-embed-text',
        http.Client? client,
    }) : _client = client ?? http.Client() {
        assertEndpointAllowed(baseUri);
    }

    static RemoteAiGateway? fromEnvironment() {
        const configuredBase = String.fromEnvironment('OLLAMA_BASE_URL');
        if (configuredBase.isEmpty) return null;
        try {
            final gateway =
                RemoteAiGateway(baseUri: Uri.parse(configuredBase));
            return gateway;
        } catch (_) {
            return null;
        }
    }

    final Uri baseUri;
    final String generationModel;
    final String embeddingModel;
    final http.Client _client;

    Uri _endpoint(String path) {
        return baseUri.replace(path: path);
    }

    Future<bool> isHealthy() async {
        try {
            final response = await _client
                .get(_endpoint('/api/tags'))
                .timeout(const Duration(seconds: 5));
            return response.statusCode == 200;
        } catch (_) {
            return false;
        }
    }

    Future<String> generate(
        String prompt, {
        String? system,
        Duration timeout = const Duration(seconds: 60),
    }) async {
        final response = await _client
            .post(
                _endpoint('/api/generate'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                    'model': generationModel,
                    'prompt': prompt,
                    if (system != null) 'system': system,
                    'stream': false,
                }),
            )
            .timeout(timeout);

        if (response.statusCode != 200) {
            throw StateError('AI gateway returned ${response.statusCode}');
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
            throw const FormatException('Unexpected AI gateway response');
        }
        return decoded['response'] as String? ?? '';
    }

    Future<List<double>> embed(String input) async {
        final response = await _client
            .post(
                _endpoint('/api/embed'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                    'model': embeddingModel,
                    'input': input,
                }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
            throw StateError('Embedding gateway returned ${response.statusCode}');
        }

        final decoded = jsonDecode(response.body);
        final embeddings = decoded is Map<String, dynamic>
            ? decoded['embeddings']
            : null;
        if (embeddings is! List || embeddings.isEmpty) {
            throw const FormatException('Embedding response did not contain vectors');
        }
        final first = embeddings.first;
        if (first is! List) {
            throw const FormatException('Embedding vector had an invalid format');
        }
        return first.map((value) => (value as num).toDouble()).toList();
    }

    Future<String> translate({
        required String text,
        required String targetLanguage,
        String sourceLanguage = 'auto',
    }) {
        return generate(
            'Translate the following text from $sourceLanguage to $targetLanguage. '
            'Return only the translated text.\n\n$text',
            system:
                'You are a precise translation engine. Do not add explanations.',
        );
    }

    void close() => _client.close();
}
