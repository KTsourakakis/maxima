import 'package:aura_straton_maxima_ai/services/access_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    const standard = AccessControl(ClientRank.standard);
    const premium = AccessControl(ClientRank.premium);

    test('standard rank keeps translation and analytics', () {
        expect(standard.allows(SecureCapability.translation), isTrue);
        expect(standard.allows(SecureCapability.analytics), isTrue);
    });

    test('standard rank is denied privileged capabilities', () {
        for (final cap in [
            SecureCapability.businessLog,
            SecureCapability.secureRecording,
            SecureCapability.voipPipeline,
            SecureCapability.wakeOnLan,
            SecureCapability.updateRobot,
        ]) {
            expect(standard.allows(cap), isFalse, reason: cap.name);
        }
    });

    test('premium rank allows every capability', () {
        for (final cap in SecureCapability.values) {
            expect(premium.allows(cap), isTrue, reason: cap.name);
        }
    });
}
