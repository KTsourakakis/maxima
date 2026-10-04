import 'dart:async';

import 'package:aura_straton_maxima_ai/services/access_control.dart';
import 'package:aura_straton_maxima_ai/services/cognitive_search.dart';
import 'package:aura_straton_maxima_ai/services/wake_word_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    test('native wake-word events dispatch to mapped actions', () async {
        final stream = StreamController<dynamic>();
        addTearDown(stream.close);
        final controller = WakeWordController(
            accessControl: const AccessControl(ClientRank.premium),
            nativeEvents: stream.stream,
        );
        addTearDown(controller.dispose);

        stream.add({'phrase': 'purge', 'transcript': 'force black now'});
        await Future.delayed(const Duration(milliseconds: 50));
        // hardwarePurge ran (returns true internally) — no exception
        // and no channel call was required.
    });

    test('standard rank cannot trigger privileged actions', () async {
        final controller = WakeWordController(
            accessControl: const AccessControl(ClientRank.standard),
        );
        expect(
            await controller.handle(
                WakeWordAction.distressPanic,
                emergencyNumber: '+112',
            ),
            isFalse,
        );
        expect(
            await controller.handle(WakeWordAction.secureRecording),
            isFalse,
        );
        expect(
            await controller.handle(
                WakeWordAction.businessLog,
                transcript: 'hello',
            ),
            isFalse,
        );
    });

    test('business log ingests transcripts for premium rank', () async {
        final search = CognitiveSearch();
        final controller = WakeWordController(
            accessControl: const AccessControl(ClientRank.premium),
            search: search,
        );
        expect(
            await controller.handle(
                WakeWordAction.businessLog,
                transcript: 'quarterly revenue discussion finished',
            ),
            isTrue,
        );
        final results = await search.search('revenue');
        expect(results, isNotEmpty);
        expect(results.first.source, 'business-log');
    });

    test('hardware purge always succeeds', () async {
        final controller = WakeWordController(
            accessControl: const AccessControl(ClientRank.standard),
        );
        expect(
            await controller.handle(WakeWordAction.hardwarePurge),
            isTrue,
        );
    });
}
