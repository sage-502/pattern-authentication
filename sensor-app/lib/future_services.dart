/// Connection points reserved for later stages (development spec v3 §6).
///
/// Since v3.2 the behavioral second factor (feature extraction, template,
/// threshold) has a prototype implementation in behavior_auth.dart and
/// EnrollmentRepository.trainModel / verifyBehavior. The interfaces below are
/// still not implemented. The app must never treat
/// [FeatureStatus.notImplemented] as a pass.
library;

enum FeatureStatus { notImplemented }

/// Failed-attempt counting and 30 s / 1 min / 3 min / 5 min / admin lockout
/// (planned stage 5).
abstract interface class LockoutService {
  FeatureStatus get status;
}

/// Accumulating sensor data on each login up to 40 records (planned stage 2).
abstract interface class AuthCollectionService {
  FeatureStatus get status;
}
