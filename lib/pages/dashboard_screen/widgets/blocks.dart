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
    // TPO-only config. Same rationale as the PID fields above: a static
    // config value the firmware reads once from a dedicated 'tpo' JSON
    // object, not a live signal. Default matches BLOCK_TPO's firmware
    // default (10s) so a freshly-dropped block already compiles with a
    // sane cycle length even before the user touches it.
    this.tpoPeriodMs = 10000.0,
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

  // TPO cycle period, in ms — see comment above. Mutable for the same
  // reason as the PID fields.
  double tpoPeriodMs;

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
      // TPO has a single signal input: duty cycle (0-100%), typically
      // fed straight from a PID's output. The cycle period is
      // configured separately above (tpoPeriodMs), same rationale as
      // PID's gains — it's a static config value, not a live signal.
      case BlockType.tpo:
        return 1;
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