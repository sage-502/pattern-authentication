# Pattern Authentication

스마트폰의 3×3 패턴과 입력 중 수집한 가속도계·자이로스코프 신호를 결합하는 Android 연구용 인증 프로토타입입니다.

사용자가 등록한 패턴을 첫 번째 단계로 확인합니다. 최초 등록 10회와 이후 성공 로그인 30회로 유효 기록 40개가 모이면 행동 모델을 학습하고, 그다음 로그인부터 두 번째 단계를 적용합니다. 실제 휴대폰 잠금이나 검증된 보안 제품이 아닙니다.

## 저장소 구성

- `sensor-app/`: Flutter Android 앱과 테스트
- `pattern-ml/`: 가중 거리 모델의 학습·평가 Python 코드
- `sensor-app/BUILD.md`: 개발 환경, 검사, APK·AAB 빌드 방법

이 공개 저장소에는 연구 참가자의 원본 센서 데이터, 실제 인증 fixture, 개인 식별 정보, OAuth 자격 증명을 포함하지 않습니다.

## 앱 실행

```powershell
cd sensor-app
flutter pub get
flutter analyze lib test
flutter test
flutter run -d DEVICE_ID
```

Google Drive 로그인을 사용할 때만 Web OAuth Client ID를 빌드 시점에 전달합니다.

```powershell
flutter run -d DEVICE_ID `
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_GOOGLE_WEB_CLIENT_ID
```

상세 절차와 release 서명 주의사항은 [`sensor-app/BUILD.md`](sensor-app/BUILD.md)를 참고하세요.

## 모델 학습 코드

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r pattern-ml/requirements.txt
python pattern-ml/tune_claimant_weighted_distance.py YOUR_PRIVATE_DATA_ARCHIVE.zip `
  --out LOCAL_RESULT.json
```

학습 입력과 결과에는 행동 생체정보가 포함될 수 있습니다. 공개 저장소에 커밋하지 말고 본인의 개인정보·연구 동의 정책에 따라 별도로 관리하세요.

## 보안 및 연구 한계

- 현재 임계값과 특징 가중치는 제한된 연구 조건에서 도출됐으며 일반적인 보안 성능을 보장하지 않습니다.
- 사용자 수, 기기, 날짜, 자세가 달라지는 독립 데이터로 FAR·FRR·EER을 다시 측정해야 합니다.

## 라이선스

[MIT License](LICENSE)
