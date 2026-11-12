import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

class _Workspace extends Fake implements WorkspaceRepository {
  _Workspace({this.failFirst = false});
  bool failFirst;
  @override
  String get mode => 'first-use-test';
  @override
  Future<Workspace?> load() async {
    if (failFirst) {
      failFirst = false;
      throw const RepositoryException('首次连接暂时失败，请重试。', offline: true);
    }
    return Workspace(
      revision: 1,
      platformSettings: const {'onboardingComplete': false},
    );
  }
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  for (final retry in [false, true]) {
    testWidgets(
      'new account reaches first-use settings${retry ? ' after connection retry' : ' after fast initialization'}',
      (tester) async {
        final auth =
            AuthRepository(
                apiBaseUrl: 'http://first-use.invalid',
                preferences: SharedPreferencesAsync(),
              )
              ..session = AuthSession(
                token: 'test-session',
                expiresAt: DateTime.now().add(const Duration(days: 1)),
                user: const AuthUser(
                  id: 'first-use',
                  username: 'first-use',
                  email: 'first-use@example.test',
                ),
              );
        final c = SeraController(
          repository: _Workspace(failFirst: retry),
          seedDemo: false,
        );
        addTearDown(auth.dispose);
        addTearDown(c.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: auth,
            child: SeraApp(controller: c, auth: auth, initialLocation: '/04'),
          ),
        );
        await tester.pumpAndSettle();
        if (retry) {
          expect(find.text('暂时无法读取数据'), findsOneWidget);
          await tester.tap(find.widgetWithText(SeraButton, '重试连接'));
          await tester.pumpAndSettle();
        }
        expect(find.widgetWithText(SeraButton, '继续，连接已有日历'), findsOneWidget);
        expect(find.text('今天的节奏'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
