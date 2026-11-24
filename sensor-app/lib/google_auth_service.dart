import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

const driveFileScope = 'https://www.googleapis.com/auth/drive.file';
const driveMetadataReadScope =
    'https://www.googleapis.com/auth/drive.metadata.readonly';
const driveScopes = <String>[driveFileScope, driveMetadataReadScope];
const androidWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

abstract interface class DriveAuthProvider {
  String? get accountRef;
  Future<String> driveAccessToken({required bool interactive});
}

/// Checks the full scope set, including on accounts signed in before an
/// additional scope was introduced. Only an explicit user action can prompt.
Future<T> authorizeDriveScopes<T>({
  required Future<T?> Function(List<String>) current,
  required Future<T> Function(List<String>) request,
  required bool interactive,
}) async {
  final existing = await current(driveScopes);
  if (existing != null) return existing;
  if (!interactive) throw StateError('Drive 권한 추가 승인이 필요합니다.');
  return request(driveScopes);
}

class GoogleAuthService extends ChangeNotifier implements DriveAuthProvider {
  GoogleAuthService._();
  static final instance = GoogleAuthService._();
  static const _iosConfigChannel =
      MethodChannel('pattern_sensor/google_config');
  final GoogleSignIn _signIn = GoogleSignIn.instance;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  Future<void>? _initialization;
  String? _resolvedIosClientId;
  GoogleSignInAccount? account;

  bool get configured => Platform.isAndroid
      ? androidWebClientId.isNotEmpty
      : Platform.isIOS && _resolvedIosClientId != null;
  bool get connected => account != null;
  @override
  String? get accountRef => account?.id;
  String? get displayName => account?.displayName;

  Future<void> initialize() => _initialization ??= _initializeOnce();
  Future<void> _initializeOnce() async {
    if (Platform.isIOS) {
      String? bundledClientId;
      try {
        bundledClientId =
            await _iosConfigChannel.invokeMethod<String>('iosClientId');
      } on MissingPluginException {
        bundledClientId = null;
      } on PlatformException {
        bundledClientId = null;
      }
      if (bundledClientId != null &&
          (iosClientId.isEmpty || iosClientId == bundledClientId)) {
        _resolvedIosClientId = bundledClientId;
      }
      notifyListeners();
    }
    if (!configured) return;
    await _signIn.initialize(
      clientId: Platform.isIOS ? _resolvedIosClientId : null,
      serverClientId: Platform.isAndroid ? androidWebClientId : null,
    );
    _events = _signIn.authenticationEvents.listen(
      (event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          account = event.user;
        } else if (event is GoogleSignInAuthenticationEventSignOut) {
          account = null;
        }
        notifyListeners();
      },
      onError: (Object _) {
        account = null;
        notifyListeners();
      },
    );
    try {
      account = await _signIn.attemptLightweightAuthentication();
    } catch (_) {
      account = null;
    }
    notifyListeners();
  }

  /// Interactive calls originate only from explicit account/transfer buttons.
  Future<void> connect() async {
    await initialize();
    if (!configured) throw StateError('Google OAuth client ID 설정이 필요합니다.');
    if (account == null) {
      if (!_signIn.supportsAuthenticate()) {
        throw StateError('이 플랫폼에서 Google 계정 선택을 지원하지 않습니다.');
      }
      account = await _signIn.authenticate();
      notifyListeners();
    }
    await authorization(interactive: true);
  }

  Future<GoogleSignInClientAuthorization> authorization({
    required bool interactive,
  }) async {
    await initialize();
    final user = account;
    if (user == null) throw StateError('Google 계정을 연결해 주세요.');
    return authorizeDriveScopes<GoogleSignInClientAuthorization>(
      current: user.authorizationClient.authorizationForScopes,
      request: user.authorizationClient.authorizeScopes,
      interactive: interactive,
    );
  }

  @override
  Future<String> driveAccessToken({required bool interactive}) async =>
      (await authorization(interactive: interactive)).accessToken;

  Future<void> disconnect() async {
    if (configured) {
      await initialize();
      await _signIn.signOut();
    }
    account = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
