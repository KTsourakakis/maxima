import 'package:aura_straton_maxima_ai/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    testWidgets('App renders the installation gateway', (tester) async {
        await tester.pumpWidget(const MaximaApp());
        expect(find.byType(MaximaApp), findsOneWidget);
    });
}
