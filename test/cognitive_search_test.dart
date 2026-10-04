import 'package:aura_straton_maxima_ai/services/cognitive_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    test('lexical search returns the most relevant chunk', () async {
        final search = CognitiveSearch();
        await search.ingestText(
            source: 'docs',
            text:
                'The battery gateway stops the microphone service below '
                'the configured threshold. The native purge clears the '
                'FinKey buffer using ARM64 cycle counters. '
                'VoIP calls route through the SIP trunk client.',
        );
        await search.ingestText(
            source: 'notes',
            text:
                'Greek translation output and text-to-speech dictation '
                'are rendered in the dashboard pane.',
        );

        final results = await search.search('battery threshold');
        expect(results, isNotEmpty);
        expect(results.first.source, 'docs');
        expect(results.first.score, greaterThan(0));
    });

    test('index stays bounded and evicts the oldest entries', () async {
        final search = CognitiveSearch(maxNodes: 4, chunkSize: 40);
        for (var i = 0; i < 10; ++i) {
            await search.ingestText(
                source: 'doc$i',
                text: 'unique probe token number $i padding padding padding',
            );
        }
        final results = await search.search('probe token number 9');
        expect(results, isNotEmpty);
        // Oldest documents must have been evicted.
        final sources = results.map((r) => r.source).toSet();
        expect(sources.contains('doc0'), isFalse);
    });
}
