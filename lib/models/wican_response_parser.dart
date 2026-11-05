import '../services/debug_logger.dart';
import 'obd_pid_config.dart';

/// Byte-layout-compatible parser for WiCAN community vehicle profiles (issue #12).
///
/// WiCAN profiles index bytes (`B0`, `B1`, `[B4:B5]`, …) against the buffer built
/// by WiCAN firmware's `parse_elm327_response()` (`main/autopid.c`), which:
///
/// 1. splits the ELM327 response into frames on `\r\n`,
/// 2. drops everything up to and including the first space of each frame — i.e.
///    only the per-frame CAN ID header is removed,
/// 3. concatenates every remaining byte verbatim.
///
/// Crucially that keeps the ISO-TP framing bytes in the buffer: the first-frame
/// PCI/length bytes (`10 LL`), the service byte (`62`), the PID echo, and the
/// consecutive-frame sequence bytes (`21`, `22`, `23`, …). This is why WiCAN
/// profiles put the first cell voltage of e.g. Hyundai/Kia `220102` at `B10`
/// and skip `B16`/`B24`/`B32`/`B40` — those are sequence bytes, not data.
///
/// [OBDPIDConfig.parseWithFormula] instead strips the first CAN header and the
/// ISO-TP prefixes, which is correct for the app's built-in single-frame PIDs
/// but shifts every index on multi-frame community PIDs. Built-in PIDs keep
/// using that parser; community profiles must use [parse] so their `B` offsets
/// stay aligned with the profile author's intent.
///
/// Assumes the adapter is in header mode (`ATH1`), which is what the app uses:
/// each frame looks like `7EC 10 1E 62 01 02 FF FF FF`.
class WiCanResponseParser {
  static final _logger = DebugLogger.instance;

  /// Build WiCAN's `data[]` buffer: every byte after each frame's CAN ID.
  ///
  /// Returns an empty list for adapter error responses (`NO DATA`, `ERROR`, …)
  /// and for responses with no usable bytes.
  static List<int> extractBytes(String response) {
    final bytes = <int>[];

    for (final rawLine in response.split(RegExp(r'\r\n|\r|\n'))) {
      var line = rawLine.trim();

      // Strip ELM327 prompt characters ('>').
      while (line.endsWith('>')) {
        line = line.substring(0, line.length - 1).trim();
      }
      if (line.isEmpty) continue;

      final upper = line.toUpperCase();
      if (upper.contains('NO DATA') ||
          upper.contains('ERROR') ||
          upper.contains('STOPPED') ||
          upper.contains('SEARCHING') ||
          upper.contains('UNABLE') ||
          upper.contains('?')) {
        return const <int>[];
      }

      // WiCAN drops everything before the first space (the CAN ID header). When
      // a line carries no header (CAF0-style adapters) keep the whole line.
      final spaceIdx = line.indexOf(' ');
      final payload = spaceIdx > 0 ? line.substring(spaceIdx + 1) : line;

      final hex = payload.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      for (var i = 0; i + 1 < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
    }

    return bytes;
  }

  /// Evaluate a WiCAN profile expression against WiCAN's byte layout.
  ///
  /// Returns `double.nan` when the response carries no data or is a negative
  /// response (`7F`), so [OBDService] discards it instead of publishing a zero.
  static double parse(String response, String formula) {
    final bytes = extractBytes(response);
    if (bytes.isEmpty) {
      _logger.log('[WiCAN Parser] No usable bytes in response: $response');
      return double.nan;
    }

    // Single-frame negative response: <len> 7F <service> <code>.
    if (bytes.length > 1 && bytes[1] == 0x7F) {
      _logger.log('[WiCAN Parser] Negative response (7F): $response');
      return double.nan;
    }

    _logger.log(
      '[WiCAN Parser] Bytes (${bytes.length}): '
      '${bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}',
    );
    _logger.log('[WiCAN Parser] Formula: $formula');

    // Formulas without byte references are not byte-layout dependent.
    if (!_usesByteNotation(formula)) {
      return OBDPIDConfig.parseWithFormula(response, formula);
    }

    var evalFormula = formula;

    // Ranges first, e.g. [B4:B5] / [B10:B11] -> big-endian value.
    evalFormula = evalFormula.replaceAllMapped(RegExp(r'\[B(\d+):B(\d+)\]'), (match) {
      final startIdx = int.parse(match.group(1)!);
      final endIdx = int.parse(match.group(2)!);
      if (startIdx >= bytes.length || endIdx >= bytes.length) return '0';

      var value = 0;
      for (var i = startIdx; i <= endIdx; i++) {
        value = (value << 8) | bytes[i];
      }
      return value.toString();
    });

    // Then individual byte references, e.g. B10.
    evalFormula = evalFormula.replaceAllMapped(RegExp(r'B(\d+)'), (match) {
      final idx = int.parse(match.group(1)!);
      return idx < bytes.length ? bytes[idx].toString() : '0';
    });

    final result = OBDPIDConfig.evaluateNumericFormula(evalFormula);
    _logger.log('[WiCAN Parser] $evalFormula = $result');
    return result;
  }

  /// WiCAN-layout hex string (no separators) for HA `rawBytes` publishing.
  /// Returns '' when the response carries no usable bytes.
  static String bytesToHex(String response) {
    final bytes = extractBytes(response);
    if (bytes.length < 2) return '';
    return bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join();
  }

  static bool _usesByteNotation(String formula) {
    return formula.contains('B') && (formula.contains('[B') || RegExp(r'B\d').hasMatch(formula));
  }
}
