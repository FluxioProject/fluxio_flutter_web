import 'package:flutter/material.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/enums.dart';

class InputSource {
  InputSourceType type;
  LogicBlock? fromBlock;
  double? constant;

  InputSource.block(this.fromBlock)
    : type = InputSourceType.block,
      constant = null;

  InputSource.constant(this.constant)
    : type = InputSourceType.constant,
      fromBlock = null;
}

class LogicBlock {
  LogicBlock({
    required this.id,
    required this.title,
    required this.icon,
    required this.type,
    required this.position,
    this.ioType,
    this.ioChannel,
    // PID-only tuning parameters. Left at their defaults for every other
    // block type. These live directly on the block (not as an
    // InputSource/signal) because they are static controller tuning
    // values, not live signals — the firmware reads them once from a
    // dedicated 'pid' JSON object, separate from the generic 'in' array
    // (see _serializeBlock in VisualLogicBuilderPage).
    this.pidKp = 1.0,
    this.pidKi = 0.0,
    this.pidKd = 0.0,
    this.pidOutMin = 0.0,
    this.pidOutMax = 100.0,
  }) {
    inputs = List.generate(maxInputs, (_) => null);
  }

  final String id;
  final String title;
  final IconData icon;
  final BlockType type;
  Offset position;
  final int? ioType; // IOType.index
  final int? ioChannel; // physical channel

  // PID tuning parameters — see comment above. Mutable so the properties
  // panel can edit them in place without rebuilding the block.
  double pidKp;
  double pidKi;
  double pidKd;
  double pidOutMin;
  double pidOutMax;

  late List<InputSource?> inputs;

  int get maxInputs {
    switch (type) {
      case BlockType.math:
      case BlockType.compare:
        return 2;
      case BlockType.timer:
        return 2;
      // PID has 3 signal inputs: enable (0/1), process variable (PV),
      // and setpoint. Gains (Kp/Ki/Kd) and the output clamp
      // (outMin/outMax) are configured separately above, not through
      // inputs[], since they are tuning parameters rather than signals.
      case BlockType.pid:
        return 3;
      default:
        return 1;
    }
  }
}

class Connection {
  final LogicBlock from;
  final LogicBlock to;
  final int inputIndex; // 0 = A, 1 = B

  Connection(this.from, this.to, this.inputIndex);
}