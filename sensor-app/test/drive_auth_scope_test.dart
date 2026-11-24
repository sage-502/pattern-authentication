import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/google_auth_service.dart';

void main() {
  test('both Drive scopes are requested for an existing account', () async {
    var prompts = 0;
    final result = await authorizeDriveScopes<String>(
      current: (scopes) async {
        expect(scopes, [driveFileScope, driveMetadataReadScope]);
        return null; // Existing session only has the original drive.file grant.
      },
      request: (scopes) async {
        prompts++;
        expect(scopes, [driveFileScope, driveMetadataReadScope]);
        return 'new-token';
      },
      interactive: true,
    );
    expect(result, 'new-token');
    expect(prompts, 1);
  });

  test('an existing grant is reused without another consent prompt', () async {
    final result = await authorizeDriveScopes<String>(
      current: (scopes) async => 'existing-token',
      request: (_) async => fail('Consent must not be repeated'),
      interactive: true,
    );
    expect(result, 'existing-token');
  });

  test('background authorization never opens the consent screen', () async {
    await expectLater(
      authorizeDriveScopes<String>(
        current: (_) async => null,
        request: (_) async => fail('No background consent prompt'),
        interactive: false,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
