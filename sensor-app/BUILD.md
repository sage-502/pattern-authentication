# Android 빌드 방법

## 준비 사항

- Flutter stable 채널
- Dart SDK `>=3.4.0 <4.0.0`
- Android SDK
- Java 17

개발 환경을 먼저 확인한다.

```powershell
flutter doctor -v
flutter --version
java -version
```

이 프로젝트에는 Android 플랫폼 코드만 포함되어 있다.

## 의존성 설치와 검사

저장소의 `sensor-app` 디렉터리에서 실행한다.

```powershell
cd sensor-app
flutter pub get
flutter analyze lib test
flutter test
```

## Debug APK 빌드

Google Drive 로그인이 필요하지 않은 빌드:

```powershell
flutter build apk --debug
```

Google Drive 로그인을 사용하는 빌드:

```powershell
flutter build apk --debug `
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_GOOGLE_WEB_CLIENT_ID
```

결과 파일:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

OAuth Client ID를 넣지 않아도 로컬 등록, 로그인, 센서 수집과 파일 공유 기능은 사용할 수 있다. Google Drive 로그인과 업로드에는 Client ID가 필요하다.

## 기기에서 실행

USB 디버깅을 활성화한 Android 기기를 연결한 뒤 실행한다.

```powershell
flutter devices
flutter run -d DEVICE_ID `
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_GOOGLE_WEB_CLIENT_ID
```

Google Drive 기능이 필요하지 않으면 `--dart-define` 옵션을 생략한다.

이미 만든 APK를 ADB로 설치할 수도 있다.

```powershell
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Release APK 빌드

현재 설정 그대로 release APK를 만들 수 있다.

```powershell
flutter build apk --release `
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_GOOGLE_WEB_CLIENT_ID
```

결과 파일:

```text
build/app/outputs/flutter-apk/app-release.apk
```

현재 `android/app/build.gradle.kts`의 release 빌드는 debug 키를 사용한다. 테스트·내부 배포 용도로만 사용하고, 외부 배포 전에는 별도의 release keystore와 서명 설정을 적용해야 한다.

Google Play 배포용 App Bundle도 같은 방식으로 생성한다.

```powershell
flutter build appbundle --release `
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_GOOGLE_WEB_CLIENT_ID
```

결과 파일:

```text
build/app/outputs/bundle/release/app-release.aab
```

## 현재 앱 식별 정보

- Android application ID: `com.example.pattern_authentication`
- `pubspec.yaml` 버전: `4.0.0+16`

정식 배포 전에는 application ID, 앱 버전, release 서명 설정이 배포 대상과 맞는지 확인한다.
