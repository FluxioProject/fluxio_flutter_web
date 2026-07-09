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

  late List<InputSource?> inputs;

  int get maxInputs {
    switch (type) {
      case BlockType.math:
      case BlockType.compare:
        return 2;
      case BlockType.timer:
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
