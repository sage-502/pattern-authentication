import 'dart:convert';

import 'device_identity.dart';

String safeDeviceLabel(String label) {
  var value = label
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (value.length > 24) value = value.substring(0, 24);
  if (value.isEmpty ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
        caseSensitive: false,
      ).hasMatch(value)) {
    return 'device';
  }
  return value;
}

String exportFilename(
  DeviceIdentity identity,
  DateTime time,
  String exportId, {
  required String participantId,
  required String patternId,
}) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(exportId)) {
    throw ArgumentError('Unsafe export ID');
  }
  // The full IDs and UTC timestamp remain in export_manifest.csv. The random
  // 48-bit request suffix plus the stable 48-bit installation prefix keep the
  // visible name short without relying on a device-local counter.
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${safeParticipantToken(participantId)}_${safePatternToken(patternId)}_'
      '${identity.tag.substring(0, 12)}_${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}_${exportId.substring(0, 12)}.zip';
}

String safeParticipantToken(String participantId) {
  final source = participantId.trim();
  var visible = source
      .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\<>:"|?*\s]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  if (visible.isEmpty ||
      RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false)
          .hasMatch(visible)) {
    visible = 'participant';
  }
  if (visible.runes.length > 32) {
    visible = String.fromCharCodes(visible.runes.take(32));
  }
  // The readable prefix is followed by a stable checksum so sanitizing or
  // shortening different anonymous IDs does not give them the same token.
  var checksum = 0x811c9dc5;
  for (final byte in utf8.encode(source)) {
    checksum = ((checksum ^ byte) * 0x01000193) & 0xffffffff;
  }
  return '${visible}_${checksum.toRadixString(16).padLeft(8, '0')}';
}

String safePatternToken(String patternId) {
  if (RegExp(r'^[1-9](?:-[1-9]){2,8}$').hasMatch(patternId)) {
    return patternId;
  }
  return 'multi-pattern';
}
