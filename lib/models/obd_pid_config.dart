import '../services/debug_logger.dart';

/// PID polling priority levels
/// High priority PIDs are polled every cycle (5 seconds)
/// Low priority PIDs are polled less frequently (configurable interval)
enum PIDPriority {
  high,  // Poll every cycle (default)
  low,   // Poll every N cycles (e.g., every 5 minutes for SOH)
}

/// OBD-II PID configuration model
/// Allows users to define custom PIDs for their vehicle
class OBDPIDConfig {
  final String name;
  final String pid;
  final String description;
  final OBDPIDType type;
  final String? formula; // Custom formula for parsing (e.g., "A" or "(A*256+B)/4" or "A*0.001")
  final String? header; // ECU header for this PID (e.g., "704" for BMS, "7E0" for VCU)
  final PIDPriority priority; // Polling priority (high = every cycle, low = less frequent)
  final double Function(String response) parser;

  static final _logger = DebugLogger.instance;

  const OBDPIDConfig({
    required this.name,
    required this.pid,
    required this.description,
    required this.type,
    this.formula,
    this.header,
    this.priority = PIDPriority.high, // Default to high priority
    required this.parser,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'pid': pid,
      'description': description,
      'type': type.toString(),
      'formula': formula,
      'header': header,
      'priority': priority.toString(),
    };
  }

  /// Create from JSON
  factory OBDPIDConfig.fromJson(Map<String, dynamic> json) {
    final type = OBDPIDType.values.firstWhere(
      (e) => e.toString() == json['type'],
      orElse: () => OBDPIDType.speed,
    );
    final formula = json['formula'] as String?;
    final header = json['header'] as String?;
    final priority = PIDPriority.values.firstWhere(
      (e) => e.toString() == json['priority'],
      orElse: () => PIDPriority.high, // Default to high if not specified
    );

    return OBDPIDConfig(
      name: json['name'] as String,
      pid: json['pid'] as String,
      description: json['description'] as String,
      type: type,
      formula: formula,
      header: header,
      priority: priority,
      parser: formula != null && formula.isNotEmpty
          ? (response) => parseWithFormula(response, formula)
          : getParserForType(type),
    );
  }

  /// Parse OBD response using formula notation
  /// Supports two formats:
  /// 1. WiCAN notation: B3 = byte 3, [B3:B4] = bytes 3-4 as 16-bit value
  /// 2. A/B/C/D notation: A = first data byte, B = second, etc.
  /// Examples: "B3", "[B4:B5]/10", "A<<8+B", "(A*256+B)/10", "A-40"
  static double parseWithFormula(String response, String formula) {
    try {
      // Remove spaces, prompt character, and trim
      String parts = response.replaceAll(' ', '').replaceAll('>', '').trim().toUpperCase();

      // Check for error messages from OBD adapter
      if (parts.contains('ERROR') ||
          parts.contains('STOPPED') ||
          parts.contains('SEARCHING') ||
          parts.contains('UNABLE') ||
          parts.contains('NO DATA') ||
          parts.contains('?') ||
          parts.length < 6) {
        return double.nan; // Return NaN to indicate error
      }

      // Check for OBD-II negative response (7F = negative response service ID)
      // Format: [CAN ID][length]7F[service][error code] - e.g., "7E8 03 7F 22 31" means "request out of range"
      // The 7F must be at the service byte position (after CAN ID and length byte)
      // Don't match 7F that appears in data bytes (e.g., SOC value 027F = 63.9%)

      // Check for 3-nibble CAN header to find the correct position
      bool hasHeader = parts.length >= 7 && RegExp(r'^7[0-9A-F]{2}').hasMatch(parts.substring(0, 3));

      // Negative response check: after CAN ID (3 chars) and length byte (2 chars), service byte is at position 5-6
      // Format: 7E8 03 7F 22 31 -> position 5-6 should be "7F" for negative response
      if (hasHeader && parts.length >= 7) {
        final serviceByte = parts.substring(5, 7);
        if (serviceByte == '7F') {
          _logger.log('[Parser] Negative response detected (7F at service position): $response');
          return double.nan; // Return NaN to indicate error/unsupported PID
        }
      } else if (!hasHeader && parts.length >= 4) {
        // No CAN header: check if first byte after length is 7F
        // Format: 03 7F 22 31
        final serviceByte = parts.substring(2, 4);
        if (serviceByte == '7F') {
          _logger.log('[Parser] Negative response detected (7F): $response');
          return double.nan;
        }
      }

      // Handle CAN response format with 3-nibble ECU ID (e.g., "784056211090350")
      // CAN responses from XPENG start with 3-nibble ID like "784", "7E8", etc.
      // WiCAN formulas expect byte indexing AFTER the 3-nibble header is stripped
      // Format: [3-nibble ID][length][service][PID echo][data...]
      // Example: 784 05 62 1109 034F -> ECU 0x784, 5 bytes, service 0x62, PID 0x1109, data 0x034F

      // Check if this looks like a CAN response with 3-nibble header
      bool hasThreeNibbleHeader = false;
      if (parts.length >= 7) {
        // Check if first 3 chars look like a CAN ID (starts with 7)
        final firstThree = parts.substring(0, 3);
        if (RegExp(r'^7[0-9A-F]{2}$').hasMatch(firstThree)) {
          hasThreeNibbleHeader = true;
        }
      }

      // If 3-nibble header detected, skip it to align bytes properly
      if (hasThreeNibbleHeader) {
        parts = parts.substring(3); // Skip the 3-nibble CAN ID
      }

      // Extract ALL bytes from the response
      // For ISO-TP responses (e.g., XPENG): "05621109034F" (after removing header)
      // For standard OBD-II: "41 0D 5A" (after removing spaces: "410D5A")
      final allBytes = <int>[];

      // If odd length, truncate last incomplete character
      if (parts.length % 2 != 0) {
        parts = parts.substring(0, parts.length - 1);
      }

      // Parse all hex pairs into bytes
      for (int i = 0; i < parts.length - 1; i += 2) {
        try {
          final hexByte = parts.substring(i, i + 2);
          if (RegExp(r'^[0-9A-F]{2}$').hasMatch(hexByte)) {
            allBytes.add(int.parse(hexByte, radix: 16));
          }
        } catch (e) {
          break;
        }
      }

      if (allBytes.isEmpty) {
        return 0.0;
      }

      // Debug: Log the parsed bytes for troubleshooting (ENABLED for testing)
      _logger.log('[Parser] Raw: ${response.replaceAll(' ', '').replaceAll('>', '').trim()}${hasThreeNibbleHeader ? ' (CAN header stripped)' : ''}');
      _logger.log('[Parser] Bytes: ${allBytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}');
      _logger.log('[Parser] Formula: $formula');

      String evalFormula = formula;

      // Detect which notation is used
      final usesWiCANNotation = formula.contains('B') && (formula.contains('[B') || RegExp(r'B\d').hasMatch(formula));
      final usesABCDNotation = RegExp(r'[ABCD]').hasMatch(formula) && !formula.contains('[B');

      if (usesWiCANNotation) {
        // WiCAN notation: [BX:BY] and BX references
        // Use ABSOLUTE byte positions from the start of response

        // Handle byte ranges like [B4:B5], [B3:B6], etc.
        final rangeRegex = RegExp(r'\[B(\d+):B(\d+)\]');
        evalFormula = evalFormula.replaceAllMapped(rangeRegex, (match) {
          final startIdx = int.parse(match.group(1)!);
          final endIdx = int.parse(match.group(2)!);

          if (startIdx >= allBytes.length || endIdx >= allBytes.length) {
            return '0';
          }

          // Use absolute byte positions from response start
          // Combine bytes as big-endian multi-byte value
          int value = 0;
          for (int i = startIdx; i <= endIdx; i++) {
            value = (value << 8) | allBytes[i];
          }
          return value.toString();
        });

        // Handle individual byte references like B3, B4, etc.
        final byteRegex = RegExp(r'B(\d+)');
        evalFormula = evalFormula.replaceAllMapped(byteRegex, (match) {
          final idx = int.parse(match.group(1)!);
          if (idx >= allBytes.length) {
            return '0';
          }
          return allBytes[idx].toString();
        });
      } else if (usesABCDNotation) {
        // A/B/C/D notation: Extract data bytes (skip header/response code)
        // For ISO-TP (XPENG): skip first few bytes to get to actual data
        // For standard OBD-II: skip mode+PID response (first 2-4 bytes)

        // Try to find '62' response code (ISO-TP positive response)
        int dataStart = parts.indexOf('62');
        if (dataStart >= 0) {
          // Skip '62' and any PID echo - take last 4-8 bytes as data
          // This handles variable-length ISO-TP headers
          final dataBytes = allBytes.sublist((allBytes.length >= 8) ? allBytes.length - 4 : 0);

          // Replace A, B, C, D with data bytes
          if (dataBytes.isNotEmpty) evalFormula = evalFormula.replaceAll(RegExp(r'\bA\b'), dataBytes[0].toString());
          if (dataBytes.length > 1) evalFormula = evalFormula.replaceAll(RegExp(r'\bB\b'), dataBytes[1].toString());
          if (dataBytes.length > 2) evalFormula = evalFormula.replaceAll(RegExp(r'\bC\b'), dataBytes[2].toString());
          if (dataBytes.length > 3) evalFormula = evalFormula.replaceAll(RegExp(r'\bD\b'), dataBytes[3].toString());
        } else {
          // Standard OBD-II: skip first 2 bytes (mode+PID response)
          final dataBytes = allBytes.sublist(2.clamp(0, allBytes.length));

          if (dataBytes.isNotEmpty) evalFormula = evalFormula.replaceAll(RegExp(r'\bA\b'), dataBytes[0].toString());
          if (dataBytes.length > 1) evalFormula = evalFormula.replaceAll(RegExp(r'\bB\b'), dataBytes[1].toString());
          if (dataBytes.length > 2) evalFormula = evalFormula.replaceAll(RegExp(r'\bC\b'), dataBytes[2].toString());
          if (dataBytes.length > 3) evalFormula = evalFormula.replaceAll(RegExp(r'\bD\b'), dataBytes[3].toString());
        }
      }

      // Evaluate the formula (supports <<, >>, +, -, *, /, parentheses)
      final result = _evaluateFormula(evalFormula);
      _logger.log('[Parser] Evaluated formula: $evalFormula = $result');
      return result;
    } catch (e) {
      _logger.log('[Parser] Error: $e');
      return 0.0;
    }
  }

  /// Formula evaluator supporting arithmetic and bitwise operations
  /// Supports: +, -, *, /, <<, >>, parentheses
  static double _evaluateFormula(String formula) {
    try {
      // Remove whitespace
      formula = formula.replaceAll(' ', '');

      // Handle parentheses recursively
      while (formula.contains('(')) {
        final start = formula.lastIndexOf('(');
        final end = formula.indexOf(')', start);
        if (end == -1) break;

        final inner = formula.substring(start + 1, end);
        final result = _evaluateFormula(inner);
        formula = formula.substring(0, start) + result.toString() + formula.substring(end + 1);
      }

      // Order of operations: bitshift, then multiply/divide, then add/subtract
      formula = _handleOperators(formula, ['<<', '>>']);
      formula = _handleOperators(formula, ['*', '/']);
      formula = _handleOperators(formula, ['+', '-']);

      return double.parse(formula);
    } catch (e) {
      return 0.0;
    }
  }

  static String _handleOperators(String formula, List<String> operators) {
    for (final op in operators) {
      while (formula.contains(op)) {
        final regex = RegExp(r'(-?\d+\.?\d*)' + RegExp.escape(op) + r'(-?\d+\.?\d*)');
        final match = regex.firstMatch(formula);
        if (match == null) break;

        final left = double.parse(match.group(1)!);
        final right = double.parse(match.group(2)!);
        double result;

        switch (op) {
          case '<<':
            // Left bitshift
            result = (left.toInt() << right.toInt()).toDouble();
            break;
          case '>>':
            // Right bitshift
            result = (left.toInt() >> right.toInt()).toDouble();
            break;
          case '*':
            result = left * right;
            break;
          case '/':
            result = right != 0 ? left / right : 0;
            break;
          case '+':
            result = left + right;
            break;
          case '-':
            result = left - right;
            break;
          default:
            result = 0;
        }

        formula = formula.substring(0, match.start) + result.toString() + formula.substring(match.end);
      }
    }
    return formula;
  }

  static double Function(String) getParserForType(OBDPIDType type) {
    switch (type) {
      case OBDPIDType.speed:
        return _parseSpeed;
      case OBDPIDType.stateOfCharge:
        return _parseSOC;
      case OBDPIDType.batteryVoltage:
        return _parseBatteryVoltage;
      case OBDPIDType.odometer:
        return _parseOdometer;
      case OBDPIDType.cumulativeCharge:
        return _parseCumulativeAh;
      case OBDPIDType.cumulativeDischarge:
        return _parseCumulativeAh;
      case OBDPIDType.cellVoltages:
        return _parseCellVoltagesAvg;
      case OBDPIDType.cellTemperatures:
        return _parseCellTemperaturesAvg;
      case OBDPIDType.custom:
        return _parseCustom;
    }
  }

  static double _parseSpeed(String response) {
    final parts = response.replaceAll(' ', '').trim();
    if (parts.length >= 6) {
      final speedHex = parts.substring(4, 6);
      return int.parse(speedHex, radix: 16).toDouble();
    }
    return 0.0;
  }

  static double _parseSOC(String response) {
    final parts = response.replaceAll(' ', '').trim();
    if (parts.length >= 6) {
      final socHex = parts.substring(4, 6);
      final soc = (int.parse(socHex, radix: 16) * 100.0) / 255.0;
      return soc.clamp(0.0, 100.0);
    }
    return 0.0;
  }

  static double _parseBatteryVoltage(String response) {
    final parts = response.replaceAll(' ', '').trim();
    if (parts.length >= 8) {
      final voltageHex = parts.substring(4, 8);
      return int.parse(voltageHex, radix: 16) * 0.001;
    }
    return 0.0;
  }

  static double _parseOdometer(String response) {
    final parts = response.replaceAll(' ', '').trim();
    if (parts.length >= 12) {
      final odometerHex = parts.substring(4, 12);
      return int.parse(odometerHex, radix: 16) * 0.1;
    }
    return 0.0;
  }

  static double _parseCustom(String response) {
    // Simple hex to decimal conversion for custom PIDs
    final parts = response.replaceAll(' ', '').trim();
    if (parts.length >= 6) {
      final valueHex = parts.substring(4, 6);
      return int.parse(valueHex, radix: 16).toDouble();
    }
    return 0.0;
  }

  /// Parse cumulative charge/discharge in Ah
  /// Formula: A<<24 + B<<16 + C<<8 + D (4 bytes, big-endian)
  static double _parseCumulativeAh(String response) {
    final parts = response.replaceAll(' ', '').trim();
    // Expect at least 8 hex chars of data (4 bytes) after header
    if (parts.length >= 16) {
      // Skip header bytes and get 4 data bytes
      final dataHex = parts.substring(parts.length - 8);
      final value = int.parse(dataHex, radix: 16);
      return value.toDouble();
    }
    return 0.0;
  }

  /// Parse multi-frame cell voltages (PID 221122) and return average voltage
  /// XPENG returns ~150 cell voltages in multi-frame ISO-TP response
  /// Each byte is cell voltage: value * 0.02 + 2.0V (typical range 3.0-4.2V)
  static double _parseCellVoltagesAvg(String response) {
    final cellVoltages = parseCellVoltages(response);
    if (cellVoltages.isEmpty) return 0.0;
    final sum = cellVoltages.reduce((a, b) => a + b);
    return sum / cellVoltages.length;
  }

  /// Parse multi-frame cell temperatures (PID 221123) and return average temp
  /// Each byte is temperature: value - 40 (°C)
  static double _parseCellTemperaturesAvg(String response) {
    final cellTemps = parseCellTemperatures(response);
    if (cellTemps.isEmpty) return 0.0;
    final sum = cellTemps.reduce((a, b) => a + b);
    return sum / cellTemps.length;
  }

  /// Parse multi-frame cell voltages and return list of all cell voltages (V)
  /// Response format: Multi-frame ISO-TP with cell voltage bytes
  /// Formula per cell: value * 0.02 + 2.0V
  static List<double> parseCellVoltages(String response) {
    final voltages = <double>[];
    try {
      // Remove spaces and get raw hex
      String parts = response.replaceAll(' ', '').replaceAll('>', '').trim().toUpperCase();

      // Multi-frame response contains multiple frames like:
      // 78410E3621122C7C8C7 (first frame with header)
      // 78421C8C7C8C7C8C8C8 (consecutive frames)
      // Each frame has: [3-char CAN ID][frame type/seq][data bytes...]

      // Split into frames (each starts with 784)
      final frames = <String>[];
      int idx = 0;
      while (idx < parts.length) {
        final frameStart = parts.indexOf('784', idx);
        if (frameStart < 0) break;

        // Find next frame or end
        final nextFrame = parts.indexOf('784', frameStart + 3);
        final frameEnd = nextFrame > 0 ? nextFrame : parts.length;
        frames.add(parts.substring(frameStart, frameEnd));
        idx = frameEnd;
      }

      if (frames.isEmpty) return voltages;

      // Parse first frame (has length and PID echo)
      // Format: 784[10][length][62][PID][data...]
      if (frames.isNotEmpty && frames[0].length >= 13) {
        final firstFrame = frames[0];
        // Skip: 784 (3) + 10 (2) + length (2) + 62 (2) + 1122 (4) = 13 chars
        final dataStart = 13;
        for (int i = dataStart; i < firstFrame.length - 1; i += 2) {
          final hexByte = firstFrame.substring(i, i + 2);
          if (hexByte == 'FF') continue; // Skip padding
          if (RegExp(r'^[0-9A-F]{2}$').hasMatch(hexByte)) {
            final rawValue = int.parse(hexByte, radix: 16);
            // Convert to voltage: value * 0.02 + 2.0V (gives ~3.7V for 0xB9=185)
            final voltage = rawValue * 0.02 + 2.0;
            if (voltage >= 2.5 && voltage <= 4.5) {
              voltages.add(voltage);
            }
          }
        }
      }

      // Parse consecutive frames
      // Format: 784[2X][data...] where X is sequence number
      for (int f = 1; f < frames.length; f++) {
        final frame = frames[f];
        if (frame.length < 5) continue;

        // Skip: 784 (3) + 2X (2) = 5 chars
        final dataStart = 5;
        for (int i = dataStart; i < frame.length - 1; i += 2) {
          final hexByte = frame.substring(i, i + 2);
          if (hexByte == 'FF' || hexByte == '55') continue; // Skip padding
          if (RegExp(r'^[0-9A-F]{2}$').hasMatch(hexByte)) {
            final rawValue = int.parse(hexByte, radix: 16);
            final voltage = rawValue * 0.02 + 2.0;
            if (voltage >= 2.5 && voltage <= 4.5) {
              voltages.add(voltage);
            }
          }
        }
      }

      _logger.log('[Parser] Parsed ${voltages.length} cell voltages');
    } catch (e) {
      _logger.log('[Parser] Error parsing cell voltages: $e');
    }
    return voltages;
  }

  /// Parse multi-frame cell temperatures and return list of all temps (°C)
  /// Response format: Multi-frame ISO-TP with temperature bytes
  /// Formula per cell: value - 40 (°C)
  static List<double> parseCellTemperatures(String response) {
    final temps = <double>[];
    try {
      String parts = response.replaceAll(' ', '').replaceAll('>', '').trim().toUpperCase();

      // Split into frames (each starts with 784)
      final frames = <String>[];
      int idx = 0;
      while (idx < parts.length) {
        final frameStart = parts.indexOf('784', idx);
        if (frameStart < 0) break;

        final nextFrame = parts.indexOf('784', frameStart + 3);
        final frameEnd = nextFrame > 0 ? nextFrame : parts.length;
        frames.add(parts.substring(frameStart, frameEnd));
        idx = frameEnd;
      }

      if (frames.isEmpty) return temps;

      // Parse first frame
      if (frames.isNotEmpty && frames[0].length >= 13) {
        final firstFrame = frames[0];
        final dataStart = 13; // Skip header
        for (int i = dataStart; i < firstFrame.length - 1; i += 2) {
          final hexByte = firstFrame.substring(i, i + 2);
          if (hexByte == 'FF') continue;
          if (RegExp(r'^[0-9A-F]{2}$').hasMatch(hexByte)) {
            final rawValue = int.parse(hexByte, radix: 16);
            final temp = rawValue.toDouble() - 40.0;
            if (temp >= -40 && temp <= 80) {
              temps.add(temp);
            }
          }
        }
      }

      // Parse consecutive frames
      for (int f = 1; f < frames.length; f++) {
        final frame = frames[f];
        if (frame.length < 5) continue;

        final dataStart = 5;
        for (int i = dataStart; i < frame.length - 1; i += 2) {
          final hexByte = frame.substring(i, i + 2);
          if (hexByte == 'FF' || hexByte == '55') continue;
          if (RegExp(r'^[0-9A-F]{2}$').hasMatch(hexByte)) {
            final rawValue = int.parse(hexByte, radix: 16);
            final temp = rawValue.toDouble() - 40.0;
            if (temp >= -40 && temp <= 80) {
              temps.add(temp);
            }
          }
        }
      }

      _logger.log('[Parser] Parsed ${temps.length} cell temperatures');
    } catch (e) {
      _logger.log('[Parser] Error parsing cell temperatures: $e');
    }
    return temps;
  }
}

enum OBDPIDType {
  speed,
  stateOfCharge,
  batteryVoltage,
  odometer,
  cumulativeCharge,
  cumulativeDischarge,
  cellVoltages,    // Multi-frame: all individual cell voltages
  cellTemperatures, // Multi-frame: all individual cell temperatures
  custom,
}

/// Default PID configurations for common vehicles
class DefaultOBDPIDs {
  static List<OBDPIDConfig> getDefaults() {
    return [
      OBDPIDConfig(
        name: 'Vehicle Speed',
        pid: '010D',
        description: 'Speed in km/h',
        type: OBDPIDType.speed,
        parser: OBDPIDConfig.getParserForType(OBDPIDType.speed),
      ),
      OBDPIDConfig(
        name: 'State of Charge',
        pid: '015B',
        description: 'Battery SOC (%)',
        type: OBDPIDType.stateOfCharge,
        parser: OBDPIDConfig.getParserForType(OBDPIDType.stateOfCharge),
      ),
      OBDPIDConfig(
        name: 'Battery Voltage',
        pid: '0142',
        description: 'Battery voltage (V)',
        type: OBDPIDType.batteryVoltage,
        parser: OBDPIDConfig.getParserForType(OBDPIDType.batteryVoltage),
      ),
      OBDPIDConfig(
        name: 'Odometer',
        pid: '01A6',
        description: 'Total distance (km)',
        type: OBDPIDType.odometer,
        parser: OBDPIDConfig.getParserForType(OBDPIDType.odometer),
      ),
    ];
  }

  /// Common alternative PIDs for different manufacturers
  static Map<String, List<OBDPIDConfig>> getManufacturerPIDs() {
    return {
      'Nissan Leaf': [
        OBDPIDConfig(
          name: 'State of Charge',
          pid: '01DB',
          description: 'Nissan Leaf SOC',
          type: OBDPIDType.stateOfCharge,
          parser: OBDPIDConfig.getParserForType(OBDPIDType.stateOfCharge),
        ),
      ],
      'Tesla': [
        OBDPIDConfig(
          name: 'State of Charge',
          pid: '0102',
          description: 'Tesla SOC',
          type: OBDPIDType.stateOfCharge,
          parser: OBDPIDConfig.getParserForType(OBDPIDType.stateOfCharge),
        ),
      ],
      'Chevrolet Bolt': [
        OBDPIDConfig(
          name: 'State of Charge',
          pid: '8334',
          description: 'Bolt EV SOC',
          type: OBDPIDType.stateOfCharge,
          parser: OBDPIDConfig.getParserForType(OBDPIDType.stateOfCharge),
        ),
      ],
    };
  }
}
