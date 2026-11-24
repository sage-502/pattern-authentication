import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// Parsing for research-collector export ZIPs (v3.1 training data import).
///
/// Expected layout (files at the archive root):
///   trials.csv               trial_id,participant_id,pattern,node_timestamps,...
///   sensor_events.csv        trial_id,timestamp,ax,ay,az,gx,gy,gz
///   fixed_window_metadata.csv  (optional)
///   export_manifest.csv        (optional)
///
/// Rows are kept as the original text lines so imported data stays
/// byte-for-byte comparable with the source export. Nothing is resampled,
/// filtered or re-formatted.
class ResearchExport {
  final String trialsHeader;
  final String sensorHeader;
  final String? metadataHeader;
  final String? manifestText;
  final String? exportId;
  final List<ExportTrial> trials;
  final Map<String, List<String>> sensorLines;
  final Map<String, String> metadataLines;

  const ResearchExport({
    required this.trialsHeader,
    required this.sensorHeader,
    required this.metadataHeader,
    required this.manifestText,
    required this.exportId,
    required this.trials,
    required this.sensorLines,
    required this.metadataLines,
  });
}

class ExportTrial {
  final String trialId;
  final String participantId;
  final List<int> pattern;
  final String line;
  const ExportTrial(this.trialId, this.participantId, this.pattern, this.line);
}

class ImportFormatException implements Exception {
  final String message;
  const ImportFormatException(this.message);
  @override
  String toString() => message;
}

/// Limits protect the app from oversized or malicious archives.
const maxImportArchiveBytes = 50 * 1024 * 1024;
const maxImportEntryBytes = 80 * 1024 * 1024;

const _trialsColumns = ['trial_id', 'participant_id', 'pattern'];
const _sensorColumns = [
  'trial_id',
  'timestamp',
  'ax',
  'ay',
  'az',
  'gx',
  'gy',
  'gz'
];
final _trialIdPattern = RegExp(r'^T[\w-]{1,80}$');

ResearchExport parseResearchExport(Uint8List bytes) {
  if (bytes.length > maxImportArchiveBytes) {
    throw const ImportFormatException('zip 파일이 너무 큽니다(최대 50MB).');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const ImportFormatException('zip 파일을 열 수 없습니다.');
  }
  String? read(String name) {
    // Only exact root-level names are read; no archive path is ever used to
    // build a file system path.
    final matches = archive.files.where((f) => f.isFile && f.name == name);
    if (matches.isEmpty) return null;
    final entry = matches.first;
    if (entry.size > maxImportEntryBytes) {
      throw ImportFormatException('$name 파일이 너무 큽니다.');
    }
    try {
      return utf8.decode(entry.content as List<int>);
    } catch (_) {
      throw ImportFormatException('$name 파일을 읽을 수 없습니다.');
    }
  }

  final trialsText = read('trials.csv');
  final sensorText = read('sensor_events.csv');
  if (trialsText == null || sensorText == null) {
    throw const ImportFormatException(
        '연구용 수집 앱 내보내기 zip이 아닙니다(trials.csv, sensor_events.csv 필요).');
  }
  final trialLines = _lines(trialsText);
  final sensorLinesAll = _lines(sensorText);
  if (trialLines.isEmpty || sensorLinesAll.isEmpty) {
    throw const ImportFormatException('CSV 파일이 비어 있습니다.');
  }
  final trialHeader = parseCsvLine(trialLines.first);
  if (!_startsWith(trialHeader, _trialsColumns)) {
    throw const ImportFormatException('trials.csv 형식이 다릅니다.');
  }
  final sensorHeader = parseCsvLine(sensorLinesAll.first);
  if (!_startsWith(sensorHeader, _sensorColumns)) {
    throw const ImportFormatException('sensor_events.csv 형식이 다릅니다.');
  }

  final trials = <ExportTrial>[];
  final seen = <String>{};
  for (final line in trialLines.skip(1)) {
    final fields = parseCsvLine(line);
    if (fields.length < 3) continue;
    final id = fields[0];
    if (!_trialIdPattern.hasMatch(id) || !seen.add(id)) continue;
    final nodes = fields[2]
        .split('-')
        .map((part) => int.tryParse(part.trim()))
        .whereType<int>()
        .toList();
    trials.add(ExportTrial(id, fields[1], nodes, line));
  }

  final sensorLines = <String, List<String>>{};
  for (final line in sensorLinesAll.skip(1)) {
    final comma = line.indexOf(',');
    if (comma <= 0) continue;
    final id = line.substring(0, comma);
    if (!seen.contains(id)) continue;
    final values = line.substring(comma + 1).split(',');
    if (values.length < 7 ||
        values.take(7).any((v) => double.tryParse(v)?.isFinite != true)) {
      throw ImportFormatException('sensor_events.csv에 잘못된 값이 있습니다: $id');
    }
    (sensorLines[id] ??= []).add(line);
  }

  String? metadataHeader;
  final metadataLines = <String, String>{};
  final metadataText = read('fixed_window_metadata.csv');
  if (metadataText != null) {
    final lines = _lines(metadataText);
    if (lines.isNotEmpty) {
      metadataHeader = lines.first;
      for (final line in lines.skip(1)) {
        final comma = line.indexOf(',');
        if (comma > 0) metadataLines[line.substring(0, comma)] = line;
      }
    }
  }

  final manifestText = read('export_manifest.csv');
  String? exportId;
  if (manifestText != null) {
    final lines = _lines(manifestText);
    if (lines.length >= 2) {
      final header = parseCsvLine(lines[0]);
      final values = parseCsvLine(lines[1]);
      final i = header.indexOf('export_id');
      if (i >= 0 && i < values.length) exportId = values[i];
    }
  }

  return ResearchExport(
    trialsHeader: trialLines.first,
    sensorHeader: sensorLinesAll.first,
    metadataHeader: metadataHeader,
    manifestText: manifestText,
    exportId: exportId,
    trials: trials,
    sensorLines: sensorLines,
    metadataLines: metadataLines,
  );
}

List<String> _lines(String text) => const LineSplitter()
    .convert(text.startsWith('﻿') ? text.substring(1) : text)
    .where((line) => line.trim().isNotEmpty)
    .toList();

bool _startsWith(List<String> header, List<String> expected) {
  if (header.length < expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (header[i].trim() != expected[i]) return false;
  }
  return true;
}

/// Minimal RFC 4180 line parser (quoted fields, doubled quotes).
List<String> parseCsvLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        buffer.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      fields.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  fields.add(buffer.toString());
  return fields;
}

/// A ZIP chosen in the system document picker, copied into the app cache.
class PickedZip {
  final String name;
  final String path;
  const PickedZip(this.name, this.path);
}

/// Opens the Android document picker (multiple ZIP selection).
class ZipPicker {
  static const _channel = MethodChannel('pattern_sensor/capture');

  Future<List<PickedZip>> pick() async {
    final picked = await _channel.invokeMethod<List>('pickZips') ?? const [];
    return [
      for (final item in picked)
        if (item is Map)
          PickedZip(item['name']?.toString() ?? 'data.zip',
              item['path']?.toString() ?? ''),
    ].where((zip) => zip.path.isNotEmpty).toList();
  }
}
