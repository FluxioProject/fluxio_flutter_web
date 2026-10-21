import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/blocks.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/enums.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

// Registered by the open editor so the route guard below can ask whether
// the canvas holds changes that were not sent to the device yet.
bool Function()? _openEditorHasUnsavedChanges;

/// Asks the operator to confirm leaving the logic editor while it holds
/// changes that were not sent to the device. Used as the editor route's
/// onExit guard, so it covers the back button, browser navigation and
/// in-app redirects (such as logout) alike.
Future<bool> confirmLeaveLogicEditor(BuildContext context) async {
  final hasUnsavedChanges = _openEditorHasUnsavedChanges?.call() ?? false;
  if (!hasUnsavedChanges) return true;

  final leave = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Alterações não enviadas'),
      content: const Text(
        'A lógica tem alterações que ainda não foram enviadas ao '
        'dispositivo. Se sair agora, elas serão perdidas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Continuar editando'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.dangerStrong,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Sair sem enviar'),
        ),
      ],
    ),
  );

  return leave ?? false;
}

class VisualLogicBuilderPage extends StatefulWidget {
  final Device device;
  final List<ChannelConfig> aiCfg;
  final List<ChannelConfig> diCfg;
  final List<ChannelConfig> aoCfg;
  final List<ChannelConfig> doCfg;

  const VisualLogicBuilderPage({
    super.key,
    required this.device,
    required this.aiCfg,
    required this.diCfg,
    required this.aoCfg,
    required this.doCfg,
  });

  @override
  State<VisualLogicBuilderPage> createState() => _VisualLogicBuilderPageState();
}

// ---------------------------------------------------------------------
// UNDO/REDO SNAPSHOT (FIXED)
//
// Previously, undo/redo only cloned `blocks` (via `_cloneBlocks`), never
// `connections`, and never each block's `inputs`. That meant:
//   - The new cloned blocks always had EMPTY inputs (the old
//     `_cloneBlocks` never copied `b.inputs`), so any link/constant value
//     was lost on every undo/redo.
//   - `connections` was never touched by undo/redo at all, so after an
//     undo it kept pointing to whatever the CURRENT state was, but those
//     `Connection` objects reference the OLD `LogicBlock` instances
//     (since every undo/redo replaces `blocks` with freshly-created
//     objects) — so the drawn lines and input/output counts went out of
//     sync with the actual blocks on screen.
//
// `_EditorSnapshot` now captures both `blocks` AND `connections` in one
// consistent snapshot, with `inputs` (including block-to-block links)
// correctly re-pointed to the NEW cloned block instances via an
// id -> block map (same two-pass approach already used in
// `_deserializeLogic` for the exact same reason).
// ---------------------------------------------------------------------
class _EditorSnapshot {
  final List<LogicBlock> blocks;
  final List<Connection> connections;
  _EditorSnapshot(this.blocks, this.connections);
}

class _VisualLogicBuilderPageState extends State<VisualLogicBuilderPage> {
  static const bg = AppColors.background;
  static const panel = AppColors.surface;
  static const accent = AppColors.primary;

  final List<LogicBlock> blocks = [];
  final List<Connection> connections = [];

  LogicBlock? selectedBlock;
  LogicBlock? linkingFrom;
  bool fullscreen = false;
  bool linkMode = false;
  bool isLinkingMode = false;
  bool toolboxVisible = true;
  bool _loadedFromBackend = false;

  final Set<LogicBlock> invalidBlocks = {};

  final TransformationController _transformCtrl = TransformationController();
  final FocusNode _focusNode = FocusNode();
  bool editingText = false;

  Timer? _logicTimeoutTimer;
  bool _logicReceived = false;
  LogicBlock? _clipboardBlock;

  // FIXED: stacks now hold full snapshots (blocks + connections), not
  // just a list of blocks. See `_EditorSnapshot` above for why.
  final List<_EditorSnapshot> _undoStack = [];
  final List<_EditorSnapshot> _redoStack = [];

  // NEW: tracks whether the current drag gesture already pushed an undo
  // snapshot. A drag fires onPanUpdate many times (once per pointer
  // move event) but must only count as ONE undoable action — this flag
  // makes sure _pushUndo() runs once per gesture, on the first move,
  // instead of once per pixel.
  bool _dragSnapshotPushed = false;

  int _idCounter = 0;
  List<Connection> inputConnections(LogicBlock b) =>
      connections.where((c) => c.to == b).toList();

  List<Connection> outputConnections(LogicBlock b) =>
      connections.where((c) => c.from == b).toList();

  int inputsCount(LogicBlock b) => connections.where((c) => c.to == b).length;

  int outputsCount(LogicBlock b) =>
      connections.where((c) => c.from == b).length;

  final GlobalKey _viewerKey = GlobalKey();

  // ---------------------------------------------------------------------
  // POST-SEND CONFIRMATION (NEW)
  //
  // After compiling and publishing a logic program, we now also ask the
  // device to echo back whatever it actually persisted (same 'logic_get'
  // command already used on page load) and compare it against what we
  // just sent, instead of just trusting the publish() call.
  //
  // _onLogicMessage already handles incoming 'device/.../logic' messages
  // for the initial page-load flow (-> _deserializeLogic, which rebuilds
  // the whole canvas). We do NOT want that here: reloading the canvas
  // right after a send would wipe out the user's current block layout,
  // since the device doesn't store x/y positions. So while
  // _awaitingSendConfirmation is true, the next message on that topic is
  // treated as a confirmation echo instead: compared structurally against
  // _lastSentBlocksJson and reported via a dialog, without touching
  // blocks/connections at all.
  // ---------------------------------------------------------------------
  bool _awaitingSendConfirmation = false;
  Timer? _sendConfirmTimer;
  List<dynamic>? _lastSentBlocksJson;

  // ---------------------------------------------------------------------
  // UNSAVED CHANGES
  //
  // The serialized program (blocks, links and positions) as it was last
  // loaded from the backend/device or sent to the device. Comparing it
  // with the current canvas tells whether leaving now would lose work.
  // Checked lazily, only when the operator tries to leave, so no edit
  // path has to remember to flag itself as dirty.
  // ---------------------------------------------------------------------
  String _savedLogicSnapshot = '';
  StreamSubscription<html.Event>? _beforeUnloadSub;

  String _encodeLogic() => jsonEncode(_buildLogicJson());

  void _markLogicSaved() => _savedLogicSnapshot = _encodeLogic();

  bool _hasUnsavedChanges() => _encodeLogic() != _savedLogicSnapshot;

  // Closing the tab or reloading the page bypasses the router, so the
  // browser's own "leave site?" prompt covers those cases.
  void _onBeforeUnload(html.Event event) {
    if (!_hasUnsavedChanges()) return;
    event.preventDefault();
    if (event is html.BeforeUnloadEvent) event.returnValue = '';
  }
  DateTime? _logicSendClickTime;

  static const Duration _sendConfirmTimeout = Duration(seconds: 6);

  final Session _session = Session();

  // ---------------------------------------------------------------------
  // BOOLEAN LOGIC GATES (AND / OR / NOT) — NO FIRMWARE/PROTOCOL CHANGE
  //
  // The firmware only understands "math" blocks with op 0=add, 1=sub,
  // 2=mul, 3=div (see logic.cpp / executeLogic / BLOCK_MATH). There is
  // no AND/OR/NOT op in logic.cpp and we're not adding one — instead,
  // the "E (AND)", "OU (OR)" and "NÃO (NOT)" blocks below are, as far as
  // the firmware is concerned, completely ordinary "math" blocks:
  //
  //   AND -> multiplication (a * b). For 0/1 inputs: 1*1=1, 1*0=0,
  //          0*0=0 -> behaves exactly like an AND gate.
  //   OR  -> addition (a + b). For 0/1 inputs: 0+0=0, 1+0=1, 1+1=2.
  //          The firmware always treats any value > 0.5 as "true" (DO,
  //          Timer trigger, Compare, etc — see `in > 0.5f` and
  //          `(b.lastValue > 0.5f) ? 1 : 0` in logic.cpp), so a result
  //          of 2 is still read as "on". This works perfectly when the
  //          OR's output feeds a DO, a Timer, or a Compare block.
  //          WARNING: if you feed an OR's output directly into an
  //          analog output (AO/PWM), 2 will be read as 2%, not 100% —
  //          for AO, route the OR through a Compare (> 0.5) first.
  //   NOT -> fixed subtraction (1 - b). This block's "A" input is
  //          locked to 1 by the UI itself (no editable field is shown
  //          for it); only the "B" input is linkable. Result: 1-0=1
  //          (negates false) and 1-1=0 (negates true).
  //
  // Since the protocol (`in`, `op`, `t`) doesn't change at all, the
  // ESP32 needs no changes: it already knows how to add/subtract/
  // multiply. Only the Flutter app needs to know how to "draw" these
  // math blocks with friendly logic-gate names/icons.
  //
  // To give the block a nice name when it comes back from the device
  // (via "logic_get"), we store an extra 'lg' (logic-gate) field in the
  // JSON: 0 = normal math block, 1 = AND, 2 = OR, 3 = NOT. This field is
  // simply ignored by ArduinoJson on the firmware (unknown fields don't
  // break the parser) and is ONLY used by the app itself to rebuild the
  // correct title when re-reading a saved program.
  //
  // CAVEAT / ASSUMPTION TO VALIDATE: this only survives a round trip if
  // the firmware really republishes, on "logic_get", the SAME JSON
  // string it received (suggested by the `logicJsonCache` variable in
  // logic.cpp, but the MQTT handler that deals with `type: "logic"`
  // wasn't in the files you sent me). If the firmware rebuilds the JSON
  // from its internal fields (id/t/op/in/io) and drops unknown fields,
  // 'lg' is lost after a reload — the logic keeps working 100% correctly
  // (the computed value doesn't change at all), only the block's label
  // in the editor goes back to showing the generic
  // "Multiplicação"/"Soma"/"Subtração" instead of "E (AND)" /
  // "OU (OR)" / "NÃO (NOT)". It's purely cosmetic, doesn't affect
  // behavior. For the same reason, the confirmation comparison
  // (_logicMatchesSent) deliberately ignores the 'lg' field.
  // ---------------------------------------------------------------------

  static const String kAndTitle = 'E (AND)';
  static const String kOrTitle = 'OU (OR)';
  static const String kNotTitle = 'NÃO (NOT)';

  int _logicGateFromTitle(String title) {
    switch (title) {
      case kAndTitle:
        return 1;
      case kOrTitle:
        return 2;
      case kNotTitle:
        return 3;
      default:
        return 0;
    }
  }

  int _mathOpFromTitle(String title) {
    switch (title) {
      case 'Soma':
        return MathOp.add.index;
      case 'Subtração':
        return MathOp.sub.index;
      case 'Multiplicação':
        return MathOp.mul.index;
      case 'Divisão':
        return MathOp.div.index;
      // Logic gates: reuse the firmware's existing math ops.
      case kAndTitle:
        return MathOp.mul.index; // AND = a * b
      case kOrTitle:
        return MathOp.add.index; // OR  = a + b
      case kNotTitle:
        return MathOp.sub.index; // NOT = 1 - b
      default:
        return 0;
    }
  }

  int _compareOpFromTitle(String title) {
    switch (title) {
      case 'Maior que':
        return CompareOp.gt.index;
      case 'Maior ou igual':
        return CompareOp.gte.index;
      case 'Menor que':
        return CompareOp.lt.index;
      case 'Menor ou igual':
        return CompareOp.lte.index;
      case 'Igual':
        return CompareOp.eq.index;
      default:
        return CompareOp.gt.index;
    }
  }

  List<dynamic> _serializeInput(InputSource input) {
    if (input.type == InputSourceType.constant) {
      return [InputKind.constant.index, input.constant ?? 0];
    } else {
      return [
        InputKind.block.index,
        int.parse(input.fromBlock!.id.substring(1)), // b3 → 3
      ];
    }
  }

  Map<String, dynamic> _serializeBlock(LogicBlock b) {
    final inputs = isInputIO(b)
        ? <dynamic>[]
        : b.inputs
              .where((i) => i != null)
              .map((i) => _serializeInput(i!))
              .toList();

    final base = <String, dynamic>{
      'id': int.parse(b.id.substring(1)),
      't': b.type.index,
      'in': inputs,
      // NEW: canvas position. The firmware ignores unknown fields (same
      // as 'lg' above), so it's safe to send this in the MQTT payload
      // too — but the real reason it exists is the backend, to restore
      // the exact layout when reopening the editor without the device
      // online.
      'x': b.position.dx,
      'y': b.position.dy,
    };

    if (b.type == BlockType.io) {
      base['io'] = [b.ioType!, b.ioChannel!];
    }

    if (b.type == BlockType.math) {
      base['op'] = _mathOpFromTitle(b.title);
      // Extra field, app-only — the firmware ignores it. Records whether
      // this math block is actually a disguised AND/OR/NOT gate, so we
      // can redraw the correct name if the program is re-read back from
      // the device (see the big comment above).
      final lg = _logicGateFromTitle(b.title);
      if (lg != 0) base['lg'] = lg;
    } else if (b.type == BlockType.compare) {
      base['op'] = _compareOpFromTitle(b.title);
    }

    if (b.type == BlockType.timer) {
      // Time now lives on input[1] (input[0] is the trigger). This 'time'
      // field is redundant — logic.cpp only ever reads the 'in' array —
      // but kept in sync for anyone inspecting the raw JSON.
      base['time'] = b.inputs[1]?.constant ?? 0;
    }

    if (b.type == BlockType.pid) {
      // Dedicated config object for the firmware PID block — kept
      // separate from 'in', which only carries the live enable/PV/
      // setpoint signals. Gains and the output clamp are static tuning
      // parameters the firmware reads once at load time, the same way
      // it reads 'op' for math/compare blocks.
      base['pid'] = {
        'kp': b.pidKp,
        'ki': b.pidKi,
        'kd': b.pidKd,
        'outMin': b.pidOutMin,
        'outMax': b.pidOutMax,
      };
    }

    if (b.type == BlockType.tpo) {
      // Dedicated config object for the TPO (time-proportioning output)
      // block, same rationale as 'pid' above: the cycle period is a
      // static config value the firmware reads once at load time, kept
      // separate from 'in', which only carries the live duty-cycle
      // signal (normally fed from a PID's output).
      base['tpo'] = {'period': b.tpoPeriodMs};
    }

    return base;
  }

  Map<String, dynamic> _buildLogicJson() {
    return {
      'v': 1, // schema version
      'blocks': blocks.map(_serializeBlock).toList(),
    };
  }

  Future<void> _loadLogicFromBackend() async {
    try {
      final resp = await _session.getObj(
        'devices/${widget.device.deviceId}/logic',
        context,
      );

      // getObj decodes JSON when it can, otherwise returns the raw body
      // string (e.g. the 404 "Nenhuma lógica salva..." message the
      // backend sends as plain text). We only treat this as success if
      // we got a Map with the expected fields.
      if (resp is Map<String, dynamic> && resp.containsKey('blocks')) {
        _deserializeLogic(resp);
        _markLogicSaved();
        _loadedFromBackend = true;
      }
      // Otherwise: no logic saved yet for this device, or an error —
      // fall through to the normal flow (ask the device over MQTT).
    } catch (e) {
      // No connection to the backend — not fatal, just falls through to
      // the normal MQTT flow.
      print('Erro ao carregar lógica do backend: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _markLogicSaved();
    _openEditorHasUnsavedChanges = _hasUnsavedChanges;
    _beforeUnloadSub = html.window.onBeforeUnload.listen(_onBeforeUnload);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _focusNode.requestFocus();
      _showRiskWarning();
      showMessage(
        context,
        'Dica: Double click em um bloco e depois click em outra para fazer a ligação.',
        false,
      );

      await _loadLogicFromBackend();

      mqttManager.subscribe(
        'device/${widget.device.deviceId}/logic',
        _onLogicMessage,
      );

      if (!_loadedFromBackend) {
        mqttManager.publish(
          'device/${widget.device.deviceId}/control',
          jsonEncode({'type': 'logic_get'}),
        );
        _startLogicTimeout();
      } else {
        _logicReceived = true; // avoids the "no logic found" warning
      }
    });
  }

  void _startLogicTimeout() {
    _logicReceived = false;

    _logicTimeoutTimer?.cancel();
    _logicTimeoutTimer = Timer(const Duration(seconds: 6), () {
      if (!_logicReceived && mounted) {
        showMessage(
          context,
          'Nenhuma lógica encontrada no dispositivo. Você pode começar do zero.',
          true,
        );
      }
    });
  }

  @override
  void dispose() {
    _beforeUnloadSub?.cancel();
    if (_openEditorHasUnsavedChanges == _hasUnsavedChanges) {
      _openEditorHasUnsavedChanges = null;
    }
    _logicTimeoutTimer?.cancel();
    _sendConfirmTimer?.cancel();
    mqttManager.unsubscribe('device/${widget.device.deviceId}/logic');
    super.dispose();
  }

  void _onLogicMessage(String payload) {
    print('Logic message received: $payload');
    _logicReceived = true;
    _logicTimeoutTimer?.cancel();

    try {
      final json = jsonDecode(payload);

      if (json['v'] != 2 && json['v'] != 1) {
        // A pending send-confirmation still needs to be resolved even on
        // an unsupported version, otherwise it would just sit there until
        // the timeout fires instead of reporting the real problem now.
        if (_awaitingSendConfirmation) {
          _awaitingSendConfirmation = false;
          _sendConfirmTimer?.cancel();
          _showSendConfirmationResult(matched: false, decodeError: true);
          return;
        }

        showMessage(
          context,
          'Logic JSON version ${json['v']} is not supported. Only v1 and v2 are supported.',
          true,
        );
        return;
      }

      // If we're waiting for a post-send confirmation, this message is
      // the device echoing back what it actually persisted — compare it
      // against what we sent instead of reloading the whole canvas (see
      // the big comment on _awaitingSendConfirmation above).
      if (_awaitingSendConfirmation) {
        _awaitingSendConfirmation = false;
        _sendConfirmTimer?.cancel();
        final matched = _logicMatchesSent(json);

        if (_logicSendClickTime != null) {
          final elapsed = DateTime.now().difference(_logicSendClickTime!);
          debugPrint(
            '[METRIC] logic_roundtrip_ms=${elapsed.inMilliseconds} matched=$matched',
          );
          _logicSendClickTime = null;
        }

        _showSendConfirmationResult(matched: matched);
        return;
      }

      if (_loadedFromBackend) {
        print('Ignorando mensagem MQTT retida: já carregado do backend');
        return;
      }

      _deserializeLogic(json);
      _markLogicSaved();
    } catch (e) {
      print('Error decoding logic JSON: $e');

      if (_awaitingSendConfirmation) {
        _awaitingSendConfirmation = false;
        _sendConfirmTimer?.cancel();
        _showSendConfirmationResult(matched: false, decodeError: true);
        return;
      }

      showMessage(
        context,
        'Erro ao decodificar lógica recebida do dispositivo.',
        true,
      );
    }
  }

  void _deserializeLogic(Map<String, dynamic> json) {
    blocks.clear();
    connections.clear();
    _idCounter = 0;

    final Map<int, LogicBlock> map = {};

    final List list = json['blocks'];

    double yInput = 180;
    double yProcess = 180;
    double yOutput = 180;

    const double xInput = 120;
    const double xProcess = 360;
    const double xOutput = 620;

    const double spacingY = 90;

    // pass 1: create blocks
    for (final b in list) {
      print(
        'ID=${b['id']} TYPE=${b['t']} ENUM=${BlockType.values[b['t']]} IO=${b['io']}',
      );

      final id = b['id'];
      final type = BlockType.values[b['t']];
      final List? io = b['io'];

      Offset position;

      if (b.containsKey('x') && b.containsKey('y')) {
        position = Offset((b['x']).toDouble(), (b['y']).toDouble());
      } else {
        // input
        if (type == BlockType.io &&
            io != null &&
            (io[0] == IOType.ai.index || io[0] == IOType.di.index)) {
          position = Offset(xInput, yInput);
          yInput += spacingY;

          // output
        } else if (type == BlockType.io &&
            io != null &&
            (io[0] == IOType.ao.index || io[0] == IOType.doo.index)) {
          position = Offset(xOutput, yOutput);
          yOutput += spacingY;

          // processing (timer/math/compare/pid/tpo)
        } else {
          position = Offset(xProcess, yProcess);
          yProcess += spacingY;
        }
      }

      // PID tuning parameters, if present. Read defensively since older
      // saved programs won't have it at all.
      final Map? pidJson = b['pid'];

      // TPO config, if present. Same defensive read as pidJson above.
      final Map? tpoJson = b['tpo'];

      final block = LogicBlock(
        id: 'b$id',
        title: _titleFromBlock(b),
        icon: _iconFromBlock(b),
        type: type,
        ioType: io != null ? io[0] : null,
        ioChannel: io != null ? io[1] : null,
        position: position,
        pidKp: (pidJson?['kp'] as num?)?.toDouble() ?? 1.0,
        pidKi: (pidJson?['ki'] as num?)?.toDouble() ?? 0.0,
        pidKd: (pidJson?['kd'] as num?)?.toDouble() ?? 0.0,
        pidOutMin: (pidJson?['outMin'] as num?)?.toDouble() ?? 0.0,
        pidOutMax: (pidJson?['outMax'] as num?)?.toDouble() ?? 100.0,
        tpoPeriodMs: (tpoJson?['period'] as num?)?.toDouble() ?? 10000.0,
      );

      // TIMER needs to keep the received time value
      if (type == BlockType.timer) {
        final inputs = b['in'] as List?;

        if (inputs != null && inputs.length > 1) {
          final timeInput = inputs[1];

          if (timeInput[0] == InputKind.constant.index) {
            block.inputs[1] = InputSource.constant(
              (timeInput[1] as num).toDouble(),
            );
          }
        }
      }

      blocks.add(block);
      map[id] = block;

      _idCounter = _idCounter <= id ? id + 1 : _idCounter;
    }

    // pass 2: connect inputs
    for (final b in list) {
      final to = map[b['id']]!;
      final inputs = b['in'] as List;

      for (int i = 0; i < inputs.length; i++) {
        final inDef = inputs[i];

        if (inDef[0] == InputKind.constant.index) {
          to.inputs[i] = InputSource.constant((inDef[1] as num).toDouble());
        } else {
          final from = map[inDef[1]]!;

          to.inputs[i] = InputSource.block(from);

          connections.add(Connection(from, to, i));
        }
      }
    }

    setState(() {});
  }

  String _ioTitle(int ioType, int channel) {
    switch (IOType.values[ioType]) {
      case IOType.ai:
        return widget.aiCfg[channel].name;
      case IOType.di:
        return widget.diCfg[channel].name;
      case IOType.ao:
        return widget.aoCfg[channel].name;
      case IOType.doo:
        return widget.doCfg[channel].name;
    }
  }

  String _titleFromBlock(Map b) {
    final t = b['t'];

    if (t == BlockType.math.index) {
      // If the extra 'lg' field is present (see _serializeBlock),
      // rebuild the logic-gate name instead of the generic math name.
      // If it's absent (e.g. the firmware didn't echo the field back),
      // fall back to the generic name — the computed value is still
      // correct either way, only the displayed label changes.
      final lg = b['lg'];
      if (lg == 1) return kAndTitle;
      if (lg == 2) return kOrTitle;
      if (lg == 3) return kNotTitle;
      return ['Soma', 'Subtração', 'Multiplicação', 'Divisão'][b['op']];
    }

    if (t == BlockType.timer.index) {
      return 'Timer';
    }

    if (t == BlockType.compare.index) {
      return [
        'Maior que',
        'Menor que',
        'Igual',
        'Maior ou igual',
        'Menor ou igual',
      ][b['op']];
    }

    if (t == BlockType.pid.index) {
      return 'PID';
    }

    if (t == BlockType.tpo.index) {
      return 'TPO (SSR)';
    }

    if (t == BlockType.io.index) {
      final io = b['io'] as List?;
      if (io == null) return 'IO ?';

      final ioType = io[0];
      final channel = io[1];

      return _ioTitle(ioType, channel);
    }

    return 'Bloco';
  }

  IconData _iconFromBlock(Map b) {
    if (b['t'] == BlockType.math.index) {
      final lg = b['lg'];
      if (lg == 1) return Icons.merge_type;
      if (lg == 2) return Icons.call_split;
      if (lg == 3) return Icons.block;
      return Icons.calculate;
    }
    if (b['t'] == BlockType.compare.index) return Icons.compare_arrows;
    if (b['t'] == BlockType.timer.index) {
      return Icons.timer;
    }
    if (b['t'] == BlockType.pid.index) {
      return Icons.tune;
    }
    if (b['t'] == BlockType.tpo.index) {
      return Icons.power_settings_new;
    }

    if (b['t'] == BlockType.io.index) {
      final io = b['io'] as List?;
      if (io == null) return Icons.device_unknown;

      switch (IOType.values[io[0]]) {
        case IOType.ai:
          return Icons.input;
        case IOType.di:
          return Icons.toggle_on;
        case IOType.ao:
          return Icons.output;
        case IOType.doo:
          return Icons.toggle_off;
      }
    }

    return Icons.device_unknown;
  }

  void _showRiskWarning() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: panel,
          title: const Text(
            'Aviso Importante',
            style: TextStyle(color: AppColors.foreground),
          ),
          content: const Text(
            'A programação realizada neste editor é de inteira responsabilidade do usuário.\n\n'
            'Configurações incorretas podem causar falhas no equipamento, danos materiais '
            'ou riscos operacionais.\n\n'
            'Utilize este recurso por sua conta e risco.',
            style: TextStyle(color: AppColors.foregroundSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  bool get _isLinking => linkMode || linkingFrom != null;
  bool isInputIO(LogicBlock b) =>
      b.type == BlockType.io &&
      (b.ioType == IOType.ai.index || b.ioType == IOType.di.index);

  bool isOutputIO(LogicBlock b) =>
      b.type == BlockType.io &&
      (b.ioType == IOType.ao.index || b.ioType == IOType.doo.index);

  // Analog output (PWM) blocks can now be driven either by a linked block
  // (existing behavior) OR by a fixed percentage value typed directly in
  // the properties panel. This helper flags AO blocks so the "fixed value"
  // editor (normally reserved for math/compare/timer blocks) also renders
  // for them. Digital outputs (DO) are intentionally NOT included here,
  // since they are on/off and still only make sense as a link.
  bool isAnalogOutput(LogicBlock b) =>
      b.type == BlockType.io && b.ioType == IOType.ao.index;

  // Timer blocks use a fixed 2-slot layout, PLC-style:
  //   input[0] = trigger (digital) — can be a block link OR a typed 0/1
  //   input[1] = time in ms — always a typed constant, never a link
  // logic.cpp already reads it this way whenever inputCount > 1
  // (b.inputCount > 1 ? getInputValue(inputs[1]) : ...), so no firmware
  // change is needed — this is purely a Flutter-side change, as long as
  // LogicBlock.maxInputs returns 2 for BlockType.timer (see blocks.dart).
  bool isTimerTrigger(LogicBlock b, int index) =>
      b.type == BlockType.timer && index == 0;

  bool isTimerTime(LogicBlock b, int index) =>
      b.type == BlockType.timer && index == 1;

  // NOT gate: A is always a fixed value (1), locked by the UI itself —
  // only one "real" input exists (B), which is the one that can be linked.
  bool isNotGate(LogicBlock b) => b.title == kNotTitle;

  // ---------------------------------------------------------------------
  // PID block. It uses a fixed 3-slot layout:
  //   input[0] = enable (digital 0/1) — link or typed 0/1
  //   input[1] = PV (process variable) — usually linked to an AI block
  //   input[2] = setpoint — usually a typed constant, but can be linked
  //              too (e.g. a dynamic setpoint coming from another AI)
  // Kp/Ki/Kd/outMin/outMax are NOT part of inputs[] — they're static
  // tuning parameters stored directly on the block (see blocks.dart) and
  // edited via _pidGainsEditor below.
  // ---------------------------------------------------------------------
  bool isPidBlock(LogicBlock b) => b.type == BlockType.pid;
  bool isPidEnable(LogicBlock b, int index) => isPidBlock(b) && index == 0;
  bool isPidPV(LogicBlock b, int index) => isPidBlock(b) && index == 1;
  bool isPidSetpoint(LogicBlock b, int index) => isPidBlock(b) && index == 2;

  // ---------------------------------------------------------------------
  // NEW: PID auto-routing by source IO type.
  //
  // Field bug found: nothing stopped a user from double-click-linking an
  // AI (analog, e.g. a temperature sensor) into the PID's "Habilita"
  // slot, or a DI (digital on/off) into "PV" — both compile fine (every
  // slot just needs *some* input) but produce a controller that reads
  // nonsense (a wildly swinging float treated as a boolean enable, or a
  // 0/1 signal treated as the process variable).
  //
  // Instead of relying on the generic "first empty slot" placement used
  // for math/compare (see the linking handler in _blockWidget), a link
  // landing on a PID block is now routed by what KIND of source it is:
  //   - AI source  -> always PV (index 1). Analog signals are process
  //     variables, never a boolean.
  //   - DI source  -> always Enable (index 0). Digital on/off signals
  //     enable/disable, never a continuous PV.
  //   - Anything else (compare/math/timer/another PID's output, etc. —
  //     genuinely boolean-like or purpose-built results) falls back to
  //     the first empty slot among Enable/PV/Setpoint, in that order,
  //     same spirit as the generic branch.
  //
  // Returns -1 when the natural target slot is already occupied by a
  // real block link, so the caller can show the same "already linked"
  // rejection message used everywhere else instead of silently
  // overwriting an existing connection.
  // ---------------------------------------------------------------------
  int _pidTargetIndexForSource(LogicBlock source, LogicBlock pid) {
    int? preferred;

    if (source.type == BlockType.io && source.ioType == IOType.ai.index) {
      preferred = 1; // PV
    } else if (source.type == BlockType.io &&
        source.ioType == IOType.di.index) {
      preferred = 0; // Enable
    }

    if (preferred != null) {
      final current = pid.inputs[preferred];
      if (current != null && current.type == InputSourceType.block) {
        return -1; // already linked to another block — refuse
      }
      return preferred;
    }

    // Non-IO source (math/compare/timer/pid output, etc.): first empty
    // slot among Enable(0)/PV(1)/Setpoint(2).
    for (final i in [0, 1, 2]) {
      if (pid.inputs[i] == null) return i;
    }

    // All three already have *something* — only overwrite a slot that
    // holds a fixed constant, never a real block link.
    for (final i in [0, 1, 2]) {
      if (pid.inputs[i]?.type == InputSourceType.constant) return i;
    }

    return -1;
  }

  // ---------------------------------------------------------------------
  // TPO (time-proportioning output) block. Single signal input:
  //   input[0] = duty cycle, 0-100 (%) — typically linked from a PID's
  //              output, but can also be a typed fixed value for testing
  //              the SSR wiring without a full control loop running yet.
  // The cycle period is NOT part of inputs[] — it's a static config
  // value stored directly on the block (tpoPeriodMs) and edited via
  // _tpoConfigEditor below, same pattern as PID's gains.
  //
  // Unlike BLOCK_PID when it was first introduced, the firmware already
  // implements BLOCK_TPO end-to-end (see logic.cpp's executeLogic()),
  // so this block is live from day one — no "safe to send but inert"
  // caveat here.
  // ---------------------------------------------------------------------
  bool isTpoBlock(LogicBlock b) => b.type == BlockType.tpo;
  bool isTpoDuty(LogicBlock b, int index) => isTpoBlock(b) && index == 0;

  // Short label used both in the "linked inputs" list and as a base for
  // the editable-field label below.
  String _inputShortLabel(LogicBlock b, int index) {
    if (isAnalogOutput(b)) return 'PWM';
    if (isTimerTrigger(b, index)) return 'Gatilho';
    if (isTimerTime(b, index)) return 'Tempo';
    if (isPidEnable(b, index)) return 'Habilita';
    if (isPidPV(b, index)) return 'PV';
    if (isPidSetpoint(b, index)) return 'SP';
    if (isTpoDuty(b, index)) return 'Duty';
    if (isNotGate(b)) return index == 0 ? 'A (fixo)' : 'Entrada';
    if (b.maxInputs > 1) return index == 0 ? 'A' : 'B';
    return 'IN';
  }

  // ---------------------------------------------------------------------
  // (UX only, no protocol/firmware change):
  // Builds a short summary string of any fixed ("constant") values
  // currently configured on a block, so it can be shown directly on the
  // block's card in the canvas — e.g. "A=5 · B=3", "PWM: 50%",
  // "Gatilho=1 · Tempo=1000ms", "Habilita=1 · SP=50". Returns null when
  // there is nothing fixed to show (block has no constants, or is an
  // input IO block which never has inputs at all).
  // ---------------------------------------------------------------------
  String? _constantSummary(LogicBlock b) {
    if (isInputIO(b)) return null;

    // TPO: the period is a static config value, NOT stored in inputs[],
    // so it must be shown regardless of whether the duty input below is
    // a fixed value or a block link — unlike the generic loop further
    // down, which only ever summarizes fixed inputs.
    if (isTpoBlock(b)) {
      final parts = <String>[];
      final duty = b.inputs[0];
      if (duty != null && duty.type == InputSourceType.constant) {
        final value = duty.constant ?? 0;
        final display = value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toString();
        parts.add('Duty: $display%');
      }
      parts.add('Período: ${b.tpoPeriodMs.toInt()}ms');
      return parts.join(' · ');
    }

    final parts = <String>[];

    for (int i = 0; i < b.inputs.length; i++) {
      // NOT gate: the "A=1" is always fixed and not interesting for the
      // user to see on the card (the "NÃO (NOT)" title already implies it).
      if (isNotGate(b) && i == 0) continue;

      final input = b.inputs[i];
      if (input == null || input.type != InputSourceType.constant) continue;

      final value = input.constant ?? 0;
      // Drop the trailing ".0" for whole numbers so it reads "5" not "5.0".
      final display = value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();

      final label = _inputShortLabel(b, i);

      if (isAnalogOutput(b)) {
        parts.add('$label: $display%');
      } else if (isTimerTime(b, i)) {
        parts.add('$label: ${display}ms');
      } else {
        parts.add('$label=$display');
      }
    }

    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ---------------------------------------------------------------------
  // Structural comparison between what we just sent and what the device
  // echoed back via 'logic_get'. Compares by block id (order doesn't
  // matter) and only the fields that affect actual behavior — 'lg' is
  // deliberately excluded since it's a cosmetic, app-only field (see the
  // big AND/OR/NOT comment above). 'pid' and 'tpo' are also not compared
  // here for the same "cosmetic vs. behavioral" boundary: their actual
  // effect is already captured indirectly through 'in' (the live duty
  // signal for TPO, enable/PV/SP for PID) — comparing the raw config
  // objects too would just make the check stricter without catching any
  // failure mode the core keys don't already catch.
  // ---------------------------------------------------------------------
  bool _logicMatchesSent(Map<String, dynamic> received) {
    if (_lastSentBlocksJson == null) return false;

    final receivedBlocks = received['blocks'];
    if (receivedBlocks is! List) return false;

    Map<int, Map<String, dynamic>> byId(List list) {
      final map = <int, Map<String, dynamic>>{};
      for (final b in list) {
        if (b is Map<String, dynamic> && b['id'] is int) {
          map[b['id'] as int] = b;
        }
      }
      return map;
    }

    final sent = byId(_lastSentBlocksJson!);
    final got = byId(receivedBlocks);

    if (sent.length != got.length) return false;

    const coreKeys = ['id', 't', 'op', 'in', 'io'];

    for (final id in sent.keys) {
      final a = sent[id];
      final b = got[id];
      if (a == null || b == null) return false;

      for (final key in coreKeys) {
        final aHas = a.containsKey(key);
        final bHas = b.containsKey(key);
        if (!aHas && !bHas) continue;
        if (jsonEncode(a[key]) != jsonEncode(b[key])) return false;
      }
    }

    return true;
  }

  // Kicks off the post-send confirmation round trip described in the big
  // comment above _awaitingSendConfirmation.
  void _startSendConfirmation(List<dynamic> sentBlocksJson) {
    _lastSentBlocksJson = sentBlocksJson;
    _awaitingSendConfirmation = true;

    _sendConfirmTimer?.cancel();
    _sendConfirmTimer = Timer(_sendConfirmTimeout, () {
      if (!_awaitingSendConfirmation || !mounted) return;
      _awaitingSendConfirmation = false;
      _showSendConfirmationResult(matched: false, timedOut: true);
    });

    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode({'type': 'logic_get'}),
    );
  }

  // Reports the outcome of the post-send confirmation.
  void _showSendConfirmationResult({
    required bool matched,
    bool timedOut = false,
    bool decodeError = false,
  }) {
    if (!mounted) return;

    final String title;
    final String content;
    final Color color;

    if (matched) {
      title = 'Lógica confirmada';
      content =
          'O dispositivo confirmou que salvou exatamente a lógica enviada.';
      color = AppColors.accent;
    } else if (timedOut) {
      title = 'Sem confirmação do dispositivo';
      content =
          'A lógica foi enviada, mas o dispositivo não respondeu ao pedido '
          'de confirmação (logic_get) a tempo. Verifique a conexão e tente '
          'enviar novamente se necessário.';
      color = AppColors.warning;
    } else if (decodeError) {
      title = 'Resposta inválida do dispositivo';
      content =
          'A lógica foi enviada, mas a resposta do dispositivo ao pedido '
          'de confirmação não pôde ser interpretada.';
      color = AppColors.warning;
    } else {
      title = 'Lógica enviada, mas não confere';
      content =
          'O dispositivo respondeu, mas o que ele tem salvo não bate com o '
          'que foi enviado. Recomenda-se enviar novamente.';
      color = AppColors.warning;
    }

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: panel,
          title: Text(title, style: TextStyle(color: color)),
          content: Text(
            content,
            style: const TextStyle(color: AppColors.foregroundSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveLogicToBackend(Map<String, dynamic> logicJson) async {
    try {
      await _session.postObj(
        'devices/${widget.device.deviceId}/logic',
        logicJson,
        context,
      );
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'type': 'logic_sync'}),
        retain: true,
      );
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          'Lógica enviada ao device, mas não foi possível salvar no backend.',
          true,
        );
      }
    }
  }

  void _showOfflineSaveNotice() {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: panel,
          title: const Text(
            'Dispositivo offline',
            style: TextStyle(color: AppColors.warning),
          ),
          content: const Text(
            'O dispositivo está offline no momento. A lógica foi salva no '
            'backend e será enviada automaticamente para o dispositivo assim '
            'que ele se reconectar.',
            style: TextStyle(color: AppColors.foregroundSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // IMPORT / EXPORT TO A JSON FILE
  //
  // This is a purely local, offline operation — it reads/writes the same
  // JSON shape produced by _buildLogicJson()/_deserializeLogic() (the
  // exact program a device would receive over MQTT or the backend would
  // store), but round-trips it through a file the user picks instead.
  // Useful for keeping a backup of a program, moving it between devices,
  // or editing it outside the app.
  //
  // FIXED: export originally used FilePicker.platform.saveFile(...), but
  // that throws `UnimplementedError: saveFile() has not been implemented`
  // on Flutter Web with the version of file_picker this project pins
  // (8.3.1) — the web implementation of saveFile is a known gap in the
  // plugin. Since this app is Flutter Web only, export now triggers a
  // browser download directly via dart:html (Blob + AnchorElement),
  // which needs no plugin support at all and is the standard way to
  // "save a file" from a Flutter Web app. Import is untouched: pickFiles
  // (used to open the file dialog) IS implemented on web and keeps
  // working exactly as before.
  // ---------------------------------------------------------------------

  // Builds a filesystem-safe "yyyyMMdd_HHmmss" timestamp for the
  // exported file name, so multiple exports never collide and it's
  // obvious at a glance which one is newest.
  String _timestampForFilename() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<void> _exportLogicToFile() async {
    try {
      final logicJson = _buildLogicJson();
      final jsonString = const JsonEncoder.withIndent('  ').convert(logicJson);

      final fileName =
          'fluxio_logic_${widget.device.deviceId}_${_timestampForFilename()}.json';

      // Browser-native download: wrap the JSON text in a Blob, give it a
      // temporary object URL, and click a hidden <a download> pointing
      // at it. This is synchronous and needs no user prompt beyond the
      // browser's own "Save As" dialog (or a direct download into the
      // downloads folder, depending on the browser's settings).
      final blob = html.Blob([jsonString], 'application/json');
      final url = html.Url.createObjectUrlFromBlob(blob);

      html.AnchorElement(href: url)
        ..setAttribute('download', fileName)
        ..click();

      html.Url.revokeObjectUrl(url);

      if (mounted) {
        showMessage(context, 'Lógica exportada com sucesso.', false);
      }
    } catch (e) {
      if (mounted) {
        showMessage(context, 'Erro ao exportar lógica: $e', true);
      }
    }
  }

  Future<void> _importLogicFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Importar lógica',
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true, // required on web to get the bytes in-memory
      );

      if (result == null || result.files.isEmpty) return; // user cancelled

      final file = result.files.first;
      if (file.bytes == null) {
        if (mounted) {
          showMessage(
            context,
            'Não foi possível ler o arquivo selecionado.',
            true,
          );
        }
        return;
      }

      final decoded = jsonDecode(utf8.decode(file.bytes!));

      if (decoded is! Map<String, dynamic> || !decoded.containsKey('blocks')) {
        if (mounted) {
          showMessage(
            context,
            'Arquivo inválido: formato de lógica não reconhecido.',
            true,
          );
        }
        return;
      }

      // Snapshot the current canvas first so the import itself can be
      // undone with Ctrl+Z like any other bulk change.
      _pushUndo();

      _deserializeLogic(decoded);

      if (mounted) {
        showMessage(context, 'Lógica importada com sucesso.', false);
      }
    } catch (e) {
      if (mounted) {
        showMessage(context, 'Erro ao importar lógica: $e', true);
      }
    }
  }

  void _compileAndSend() {
    invalidBlocks.clear();
    final errors = <String>[];

    for (final b in blocks) {
      final outputs = outputConnections(b);
      bool hasError = false;

      // INPUT BLOCK (AI / DI)
      if (isInputIO(b)) {
        // no inputs required
        // requires at least one output
        if (outputs.isEmpty) {
          errors.add(
            'Entrada "${b.title}" (${b.id}) não está ligada a nenhum bloco',
          );
          hasError = true;
        }
      }
      // OUTPUT BLOCK (AO / DO)
      else if (isOutputIO(b)) {
        // requires one input (can now be a link OR a fixed value, see
        // _inputEditor / _blockProperties for AO blocks)
        if (b.inputs[0] == null) {
          errors.add('Saída "${b.title}" (${b.id}) está sem entrada');
          hasError = true;
        }
        // no output required
      }
      // PROCESSING BLOCK (math / compare / timer / pid / tpo)
      else {
        // TIMER
        if (b.type == BlockType.timer) {
          if (b.inputs[0] == null) {
            errors.add('Timer (${b.id}) está sem gatilho configurado');
            invalidBlocks.add(b);
            continue;
          }

          if (b.inputs[1] == null) {
            errors.add('Timer (${b.id}) está sem tempo configurado');
            invalidBlocks.add(b);
            continue;
          }

          if (outputs.isEmpty) {
            errors.add('Timer (${b.id}) não possui saída conectada');
            invalidBlocks.add(b);
            continue;
          }
        }
        // OTHERS (math / compare / pid / tpo — pid and tpo fall here
        // too, since neither is IO nor Timer; their signal inputs are
        // all required by the generic loop below, same as math's A/B).
        else {
          for (int i = 0; i < b.maxInputs; i++) {
            if (b.inputs[i] == null) {
              final label = _inputShortLabel(b, i);
              errors.add(
                'Bloco "${b.title}" (${b.id}) está sem entrada $label',
              );
              invalidBlocks.add(b);
            }
          }

          // ---------------------------------------------------------
          // PID semantic validation (Enable vs PV wiring).
          //
          // The auto-routing in the linking handler (see
          // _pidTargetIndexForSource) prevents this mistake for links
          // made from now on, but it can't fix programs that were
          // already wired backwards before this existed — imported from
          // a file, loaded from an old saved backend program, etc. This
          // catches those at compile time instead of silently sending a
          // controller that reads nonsense.
          // ---------------------------------------------------------
          if (isPidBlock(b)) {
            final enableSrc = b.inputs[0]?.fromBlock;
            if (enableSrc != null &&
                enableSrc.type == BlockType.io &&
                enableSrc.ioType == IOType.ai.index) {
              errors.add(
                'PID (${b.id}): "Habilita" está ligado a uma entrada '
                'analógica (AI). Ligue um sinal digital (DI) ou use um '
                'valor fixo 0/1.',
              );
              invalidBlocks.add(b);
            }

            final pvSrc = b.inputs[1]?.fromBlock;
            if (pvSrc != null &&
                pvSrc.type == BlockType.io &&
                pvSrc.ioType == IOType.di.index) {
              errors.add(
                'PID (${b.id}): "PV" está ligado a uma entrada digital '
                '(DI). A variável de processo deve vir de uma entrada '
                'analógica (AI).',
              );
              invalidBlocks.add(b);
            }
          }

          // ---------------------------------------------------------
          // TPO semantic validation (output must go to a DO, never AO).
          //
          // The linking handler (see _blockWidget) already refuses to
          // CREATE a TPO → AO connection, but it can't fix programs
          // wired that way before this check existed — imported from a
          // file, loaded from an old saved backend program, etc. TPO's
          // output is always 0/1; on an AO it would be read as 0% or
          // 100%, never the intended proportional value.
          // ---------------------------------------------------------
          if (isTpoBlock(b)) {
            for (final c in outputs) {
              if (isOutputIO(c.to) && c.to.ioType == IOType.ao.index) {
                errors.add(
                  'TPO (${b.id}): saída ligada a uma saída analógica '
                  '(AO). A saída do TPO é sempre 0 ou 1 — ligue a uma '
                  'saída digital (DO).',
                );
                invalidBlocks.add(b);
              }
            }
          }

          if (outputs.isEmpty) {
            errors.add(
              'Bloco "${b.title}" (${b.id}) não possui saída conectada',
            );
            invalidBlocks.add(b);
          }
        }
      }

      if (hasError) invalidBlocks.add(b);
    }

    setState(() {}); // forces border repaint

    if (errors.isNotEmpty) {
      _showCompileErrors(errors);
      return;
    }

    showMessage(context, 'Compilação concluída', false);

    final json = _buildLogicJson();
    final pretty = const JsonEncoder.withIndent('  ').convert(json);

    debugPrint('====== LOGIC JSON ======');
    debugPrint(pretty);
    debugPrint('========================');

    final logicJson = _buildLogicJson();
    final payload = {'type': 'logic', ...logicJson};
    print(payload);

    _logicSendClickTime = DateTime.now();

    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode(payload),
    );
    _markLogicSaved();

    if (appState.isDeviceFresh(widget.device.deviceId)) {
      _startSendConfirmation(logicJson['blocks'] as List<dynamic>);
    } else {
      _showOfflineSaveNotice();
    }

    _saveLogicToBackend(logicJson);
  }

  void _showCompileErrors(List<String> errors) {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: panel,
          title: const Text(
            'Erro de compilação',
            style: TextStyle(color: AppColors.danger),
          ),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: errors
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '• $e',
                        style: const TextStyle(
                          color: AppColors.foregroundSecondary,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // FIXED: `_takeSnapshot` replaces the old `_cloneBlocks`.
  //
  // It rebuilds `blocks` in two passes (exactly like `_deserializeLogic`
  // already does when loading from JSON):
  //   1st pass: create a fresh `LogicBlock` for every current block and
  //             remember old-id -> new-block in `idMap`.
  //   2nd pass: copy each block's `inputs` (both fixed constants AND
  //             block-to-block links), re-pointing any block link to the
  //             corresponding NEW block instance via `idMap`.
  //
  // It also rebuilds `connections` against those same new instances, so
  // a restored snapshot's `connections` list is always consistent with
  // its `blocks` list — this is what the old code was missing entirely.
  //
  // PID tuning fields (Kp/Ki/Kd/outMin/outMax) and TPO's period are
  // plain values copied along with the rest of the block's constructor
  // args, same as ioType/ioChannel — no extra handling needed here.
  // ---------------------------------------------------------------------
  _EditorSnapshot _takeSnapshot() {
    final idMap = <String, LogicBlock>{};
    final newBlocks = <LogicBlock>[];

    for (final b in blocks) {
      final nb = LogicBlock(
        id: b.id,
        title: b.title,
        icon: b.icon,
        type: b.type,
        position: b.position,
        ioType: b.ioType,
        ioChannel: b.ioChannel,
        pidKp: b.pidKp,
        pidKi: b.pidKi,
        pidKd: b.pidKd,
        pidOutMin: b.pidOutMin,
        pidOutMax: b.pidOutMax,
        tpoPeriodMs: b.tpoPeriodMs,
      );
      idMap[b.id] = nb;
      newBlocks.add(nb);
    }

    for (final b in blocks) {
      final nb = idMap[b.id]!;
      for (int i = 0; i < b.inputs.length; i++) {
        final input = b.inputs[i];
        if (input == null) continue;

        if (input.type == InputSourceType.constant) {
          nb.inputs[i] = InputSource.constant(input.constant ?? 0);
        } else if (input.fromBlock != null) {
          final fromId = input.fromBlock!.id;
          final mappedFrom = idMap[fromId];
          if (mappedFrom != null) {
            nb.inputs[i] = InputSource.block(mappedFrom);
          }
        }
      }
    }

    final newConnections = connections
        .map(
          (c) => Connection(idMap[c.from.id]!, idMap[c.to.id]!, c.inputIndex),
        )
        .toList();

    return _EditorSnapshot(newBlocks, newConnections);
  }

  // FIXED: restores both `blocks` and `connections` from a snapshot,
  // instead of only `blocks` like the previous undo/redo did.
  void _restoreSnapshot(_EditorSnapshot snap) {
    blocks
      ..clear()
      ..addAll(snap.blocks);
    connections
      ..clear()
      ..addAll(snap.connections);
  }

  void _pushUndo() {
    _undoStack.add(_takeSnapshot());
    _redoStack.clear();
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Limpar lógica'),
        content: const Text(
          'Isso irá apagar TODOS os blocos e conexões do editor.\n\n'
          'Esta ação não pode ser desfeita.\n\n'
          'Deseja continuar?',
          style: TextStyle(color: AppColors.foregroundSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.dangerStrong,
            ),
            onPressed: () {
              Navigator.pop(context);
              _clearAllLogic();
            },
            child: const Text(
              'Apagar tudo',
              style: TextStyle(color: AppColors.foreground),
            ),
          ),
        ],
      ),
    );
  }

  void _clearAllLogic() {
    _pushUndo(); // allows undoing this later if wanted

    setState(() {
      blocks.clear();
      connections.clear();
      invalidBlocks.clear();
      selectedBlock = null;
      linkingFrom = null;
      isLinkingMode = false;
      _inputControllers.clear();
      _pidControllers.clear();
      _tpoControllers.clear();

      // VERY IMPORTANT
      _idCounter = 0;
    });

    showMessage(context, 'Lógica limpa. Comece do zero.', false);
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: (event) {
        if (editingText) return;

        final isCtrl = event.isControlPressed || event.isMetaPressed;

        if (event is RawKeyDownEvent) {
          // ===== COPY =====
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyC) {
            if (selectedBlock != null) {
              _clipboardBlock = selectedBlock;
            }
            return;
          }

          // ===== PASTE =====
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV) {
            if (_clipboardBlock != null) {
              _pushUndo();

              setState(() {
                blocks.add(
                  LogicBlock(
                    id: 'b${_idCounter++}',
                    title: _clipboardBlock!.title,
                    icon: _clipboardBlock!.icon,
                    type: _clipboardBlock!.type,
                    ioType: _clipboardBlock!.ioType,
                    ioChannel: _clipboardBlock!.ioChannel,
                    position: _clipboardBlock!.position + const Offset(30, 30),
                    pidKp: _clipboardBlock!.pidKp,
                    pidKi: _clipboardBlock!.pidKi,
                    pidKd: _clipboardBlock!.pidKd,
                    pidOutMin: _clipboardBlock!.pidOutMin,
                    pidOutMax: _clipboardBlock!.pidOutMax,
                    tpoPeriodMs: _clipboardBlock!.tpoPeriodMs,
                  ),
                );
              });
            }
            return;
          }

          // ===== UNDO ===== (FIXED: uses _takeSnapshot/_restoreSnapshot
          // so connections and inputs are restored consistently, not
          // just block metadata like before.)
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
            if (_undoStack.isNotEmpty) {
              _redoStack.add(_takeSnapshot());
              setState(() {
                _restoreSnapshot(_undoStack.removeLast());
              });
            }
            return;
          }

          // ===== REDO ===== (FIXED: same snapshot-based approach as undo)
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyY) {
            if (_redoStack.isNotEmpty) {
              _undoStack.add(_takeSnapshot());
              setState(() {
                _restoreSnapshot(_redoStack.removeLast());
              });
            }
            return;
          }

          // ===== ESC =====
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            setState(() {
              isLinkingMode = false;
              linkingFrom = null;
              selectedBlock = null;
            });
            FocusScope.of(context).unfocus();
            return;
          }
        }

        // ===== DELETE =====
        if (event is RawKeyUpEvent &&
            (event.logicalKey == LogicalKeyboardKey.delete)) {
          if (selectedBlock != null) {
            _pushUndo();

            setState(() {
              final deleted = selectedBlock!;

              connections.removeWhere(
                (c) => c.from == deleted || c.to == deleted,
              );

              for (final b in blocks) {
                for (int i = 0; i < b.inputs.length; i++) {
                  if (b.inputs[i]?.fromBlock == deleted) {
                    b.inputs[i] = null;
                  }
                }
              }

              blocks.remove(deleted);
              if (blocks.isEmpty) _idCounter = 0;
              _inputControllers.remove(deleted.id);
              _pidControllers.remove(deleted.id);
              _tpoControllers.remove(deleted.id);
              invalidBlocks.remove(deleted);
              selectedBlock = null;
            });
          }
        }
      },

      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: panel,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            'Editor Lógico Visual   -   ${widget.device.name} (${widget.device.deviceId})',
          ),
          actions: [
            // Import/export the current logic program to a local JSON
            // file. Placed to the left of the "clear logic" button,
            // grouped together since both are file/bulk operations on
            // the whole program rather than on a single block.
            IconButton(
              tooltip: 'Importar lógica de um arquivo JSON',
              icon: const Icon(Icons.file_upload, color: AppColors.info),
              onPressed: _importLogicFromFile,
            ),
            IconButton(
              tooltip: 'Exportar lógica para um arquivo JSON',
              icon: const Icon(Icons.file_download, color: AppColors.info),
              onPressed: _exportLogicToFile,
            ),

            IconButton(
              tooltip: 'Limpar lógica (apagar todos os blocos)',
              icon: const Icon(Icons.delete_sweep, color: AppColors.danger),
              onPressed: _confirmClearAll,
            ),

            IconButton(
              tooltip: 'Compilar e Enviar',
              icon: const Icon(Icons.send, color: AppColors.accent),
              onPressed: _compileAndSend,
            ),
          ],
        ),
        body: Row(
          children: [
            if (!fullscreen)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: toolboxVisible ? 260 : 0,
                child: toolboxVisible ? _toolbox() : null,
              ),

            if (!fullscreen && toolboxVisible) const VerticalDivider(width: 1),

            Expanded(child: _canvas()),

            if (!fullscreen && selectedBlock != null) ...[
              const VerticalDivider(width: 1),
              _propertiesPanel(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _toolbox() {
    return Container(
      width: 260,
      color: panel,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(right: 12, left: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Blocos',
              style: TextStyle(
                fontSize: AppFontSize.lg,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            _group('IO do Dispositivo', AppColors.accent, [
              // AI
              // ONLY: channels marked as hidden by the user in the IO screen
              // (ChannelConfig.visible == false) are skipped here so they
              // never show up as draggable blocks in the logic editor.
              ...widget.aiCfg.asMap().entries.where((e) => e.value.visible).map(
                (e) {
                  final c = e.value;
                  return _dragIO(
                    title: c.name,
                    icon: Icons.input,
                    ioType: IOType.ai,
                    channel: e.key,
                  );
                },
              ),

              // DI
              ...widget.diCfg.asMap().entries.where((e) => e.value.visible).map(
                (e) {
                  final c = e.value;
                  return _dragIO(
                    title: c.name,
                    icon: Icons.toggle_on,
                    ioType: IOType.di,
                    channel: e.key,
                  );
                },
              ),

              // AO
              ...widget.aoCfg.asMap().entries.where((e) => e.value.visible).map(
                (e) {
                  final c = e.value;
                  return _dragIO(
                    title: c.name,
                    icon: Icons.output,
                    ioType: IOType.ao,
                    channel: e.key,
                  );
                },
              ),

              // DO
              ...widget.doCfg.asMap().entries.where((e) => e.value.visible).map(
                (e) {
                  final c = e.value;
                  return _dragIO(
                    title: c.name,
                    icon: Icons.toggle_off,
                    ioType: IOType.doo,
                    channel: e.key,
                  );
                },
              ),
            ]),

            _group('Matemática', AppColors.blockMath, [
              _drag('Soma', Icons.add, BlockType.math),
              _drag('Subtração', Icons.remove, BlockType.math),
              _drag('Multiplicação', Icons.close, BlockType.math),
              _drag('Divisão', Icons.calculate, BlockType.math),
            ]),

            _group('Comparação', AppColors.warning, [
              _drag('Maior que', Icons.arrow_upward, BlockType.compare),
              _drag('Maior ou igual', Icons.trending_up, BlockType.compare),
              _drag('Menor que', Icons.arrow_downward, BlockType.compare),
              _drag('Menor ou igual', Icons.trending_down, BlockType.compare),
              _drag('Igual', Icons.compare_arrows, BlockType.compare),
            ]),

            // ---------------------------------------------------------
            // Boolean logic gates. Under the hood these are just regular
            // "math" blocks (same BlockType the firmware knows) — see
            // the big comment above _mathOpFromTitle explaining why this
            // works without touching the ESP32.
            // ---------------------------------------------------------
            _group('Lógica (AND / OR / NOT)', AppColors.blockLogic, [
              _drag(kAndTitle, Icons.merge_type, BlockType.math),
              _drag(kOrTitle, Icons.call_split, BlockType.math),
              _drag(kNotTitle, Icons.block, BlockType.math),
            ]),

            _group('Tempo', AppColors.blockTimer, [
              _drag('Timer', Icons.timer, BlockType.timer),
            ]),

            _group('Controle (PID)', AppColors.blockPid, [
              _drag('PID', Icons.tune, BlockType.pid),
            ]),

            // ---------------------------------------------------------
            // NEW: TPO (time-proportioning output) block. Converts a
            // continuous 0-100 duty cycle — typically the output of a
            // PID block above — into a discrete on/off signal for
            // actuators that can only switch, such as an SSR driving a
            // resistive heater. Feed its output into a DO block only,
            // never an AO (see isTpoBlock / the linking guard in
            // _blockWidget and the compile-time check in
            // _compileAndSend).
            // ---------------------------------------------------------
            _group('Saída Temporizada (TPO/SSR)', AppColors.blockTpo, [
              _drag('TPO (SSR)', Icons.power_settings_new, BlockType.tpo),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _dragIO({
    required String title,
    required IconData icon,
    required IOType ioType,
    required int channel,
  }) {
    return Draggable<Map<String, dynamic>>(
      data: {
        'title': title,
        'icon': icon,
        'type': BlockType.io,
        'ioType': ioType.index,
        'channel': channel,
      },
      feedback: _toolTile(title, icon, dragging: true),
      childWhenDragging: Opacity(opacity: 0.4, child: _toolTile(title, icon)),
      child: _toolTile(title, icon),
    );
  }

  Widget _group(String title, Color color, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _drag(String title, IconData icon, BlockType type) {
    return Draggable<Map<String, dynamic>>(
      data: {'title': title, 'icon': icon, 'type': type},
      feedback: _toolTile(title, icon, dragging: true),
      childWhenDragging: Opacity(opacity: 0.4, child: _toolTile(title, icon)),
      child: _toolTile(title, icon),
    );
  }

  Widget _toolTile(String title, IconData icon, {bool dragging = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: dragging ? accent : AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: AppColors.foregroundSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.foreground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvas() {
    return Stack(
      key: _viewerKey,
      children: [
        InteractiveViewer(
          transformationController: _transformCtrl,
          minScale: 0.1,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(500),

          panEnabled: !_isLinking,
          scaleEnabled: !_isLinking,

          child: DragTarget<Map<String, dynamic>>(
            onAcceptWithDetails: (d) {
              setState(() {
                final RenderBox viewerBox =
                    _viewerKey.currentContext!.findRenderObject() as RenderBox;
                final localPoint = viewerBox.globalToLocal(d.offset);

                final Matrix4 inverse = Matrix4.inverted(_transformCtrl.value);
                final canvasPoint = MatrixUtils.transformPoint(
                  inverse,
                  localPoint,
                );

                final newBlock = LogicBlock(
                  id: 'b${_idCounter++}',
                  title: d.data['title'],
                  icon: d.data['icon'],
                  type: d.data['type'],
                  ioType: d.data['ioType'],
                  ioChannel: d.data['channel'],
                  position: canvasPoint - const Offset(85, 34),
                );

                // Freshly-created NOT gate already gets A=1 fixed, leaving
                // only the B input linkable (see isNotGate / _inputEditor).
                if (newBlock.title == kNotTitle) {
                  newBlock.inputs[0] = InputSource.constant(1);
                }

                // Freshly-created PID block: default enable to "always on"
                // (1) and setpoint to 0, so the block compiles right away
                // with sensible defaults — only PV is left unset, since
                // that one really should be linked to a real signal (an
                // AI block) rather than left as a typed constant.
                if (newBlock.type == BlockType.pid) {
                  newBlock.inputs[0] = InputSource.constant(1); // enable
                  newBlock.inputs[2] = InputSource.constant(0); // setpoint
                }

                // Freshly-created TPO block: duty is deliberately left
                // unset — it should be linked to a real signal (usually
                // a PID's output) rather than defaulted to a constant,
                // same rationale as PID's PV above. tpoPeriodMs already
                // gets a sane default (10000ms) from the LogicBlock
                // constructor.

                blocks.add(newBlock);
              });
            },
            builder: (_, __, ___) {
              return Listener(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // Restores keyboard focus to the editor's
                    // RawKeyboardListener. Any TextField clicked before
                    // this (e.g. a fixed-value field in the properties
                    // panel) steals focus, which silently breaks
                    // Delete/Ctrl+C/Ctrl+Z/Ctrl+Y until focus is
                    // reclaimed by a tap like this one.
                    _focusNode.requestFocus();
                    setState(() {
                      selectedBlock = null;
                      linkingFrom = null;
                    });
                  },
                  child: SizedBox(
                    width: 50000,
                    height: 50000,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _GridPainter()),
                        ),

                        // fixed connections
                        ...connections.map(_drawConnection),

                        ...blocks.map(_blockWidget),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned(right: 24, bottom: 24, child: _fullscreenButton()),
        // toolbox show/hide button
        Positioned(
          left: 0,
          top: 0,
          child: Material(
            color: panel,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
            child: InkWell(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              splashColor: AppColors.foreground.withOpacity(0.08),
              highlightColor: AppColors.foreground.withOpacity(0.04),
              onTap: () {
                setState(() => toolboxVisible = !toolboxVisible);
              },
              child: SizedBox(
                width: 28,
                height: 48,
                child: Icon(
                  toolboxVisible ? Icons.chevron_left : Icons.chevron_right,
                  color: AppColors.foregroundSecondary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fullscreenButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          setState(() => fullscreen = !fullscreen);
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: panel,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.scrim.withOpacity(0.4),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            color: AppColors.foreground,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _blockWidget(LogicBlock b) {
    // Fetch the constant-value summary (e.g. "A=5 · B=3") once per build
    // so it can be rendered as a subtitle below the block title.
    final constantSummary = _constantSummary(b);

    return Positioned(
      left: b.position.dx,
      top: b.position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,

        onTap: () {
          // Same focus-reclaiming fix as the canvas background tap
          // above — makes sure Delete/Ctrl+C/Ctrl+Z/Ctrl+Y keep working
          // after interacting with a TextField in the properties panel.
          _focusNode.requestFocus();
          setState(() {
            invalidBlocks.remove(b);

            // If currently in linking mode
            if (isLinkingMode && linkingFrom != null) {
              // clicked the same block again -> cancel linking
              if (linkingFrom == b) {
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              // output limit
              if (outputsCount(linkingFrom!) >= 1) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Este bloco já possui uma saída'),
                  ),
                );
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              // input limit
              if (inputsCount(b) >= b.maxInputs) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Este bloco já possui o máximo de entradas'),
                  ),
                );
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              if (linkingFrom!.type == BlockType.io &&
                  b.type == BlockType.io &&
                  linkingFrom!.ioType == IOType.ai.index &&
                  b.ioType == IOType.doo.index) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Ligação inválida: entrada analógica não pode ir direto para saída digital',
                    ),
                  ),
                );
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              // NEW: TPO's output is always 0/1. Feeding it into an AO
              // would be read as 0% or 100%, never the intended
              // proportional value — refuse the link at creation time,
              // same spirit as the AI->DO guard above. (Programs already
              // wired this way before this check existed are still
              // caught at compile time — see _compileAndSend.)
              if (linkingFrom!.type == BlockType.tpo &&
                  b.type == BlockType.io &&
                  b.ioType == IOType.ao.index) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Ligação inválida: a saída do TPO é sempre 0 ou 1 — ligue a uma saída digital (DO), não a uma saída analógica (AO)',
                    ),
                  ),
                );
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              // FIX: explicitly choose the destination input index by
              // block type, instead of only looking for an empty slot
              // (which used to fail whenever the slot already had a
              // fixed value typed in, like "PWM: 50%" — indexWhere would
              // never find null and the link was silently dropped).
              //
              // - AO/DO (output), the Timer trigger, and TPO's single
              //   duty slot: ALWAYS index 0, because that's the only
              //   index the firmware actually reads
              //   (getInputValue(b.inputs[0]) in logic.cpp). Overwrites
              //   any fixed value that was already there.
              // - NOT gate: always index 1 (the B input) — the A input
              //   is locked to 1 by the UI itself.
              // - PID: routed by the SOURCE block's IO type (AI -> PV,
              //   DI -> Enable), never by "first empty slot" — see
              //   _pidTargetIndexForSource above for why (this is the
              //   fix for the Habilita/PV-inverted wiring bug found in
              //   the field).
              // - Generic math/compare: first tries to find an empty
              //   slot; if none is found (both already have a fixed
              //   value), overwrites the first one that only had a
              //   constant instead of silently doing nothing.
              int idx;
              if (isOutputIO(b) ||
                  b.type == BlockType.timer ||
                  b.type == BlockType.tpo) {
                idx = 0;
              } else if (isNotGate(b)) {
                idx = 1;
              } else if (isPidBlock(b)) {
                idx = _pidTargetIndexForSource(linkingFrom!, b);
              } else {
                idx = b.inputs.indexWhere((i) => i == null);
                if (idx == -1) {
                  idx = b.inputs.indexWhere(
                    (i) => i?.type == InputSourceType.constant,
                  );
                }
              }

              // Only blocks if the destination is already a real BLOCK
              // link — a fixed value (constant) can always be overwritten
              // by a new link.
              if (idx == -1 || b.inputs[idx]?.type == InputSourceType.block) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Essa entrada já está ligada a outro bloco. Exclua a ligação atual antes de trocar.',
                    ),
                  ),
                );
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              b.inputs[idx] = InputSource.block(linkingFrom!);
              connections.add(Connection(linkingFrom!, b, idx));

              isLinkingMode = false;
              linkingFrom = null;
              return;
            }

            // NORMAL case: just select
            selectedBlock = b;
          });
        },
        onDoubleTap: () {
          // Same focus-reclaiming fix, so entering link mode also
          // guarantees keyboard shortcuts keep working afterwards.
          _focusNode.requestFocus();
          setState(() {
            isLinkingMode = true;
            linkingFrom = b;
          });
        },

        // NEW: dragging a block to a new position is now undoable.
        // onPanStart fires exactly once per drag gesture, so the
        // pre-move snapshot is pushed a single time here — onPanUpdate
        // (below) fires repeatedly during the same gesture and must NOT
        // push another snapshot each time, or Ctrl+Z would only undo a
        // few pixels of movement instead of the whole drag.
        onPanStart: (_) {
          _pushUndo();
          _dragSnapshotPushed = true;
        },

        onPanUpdate: (d) {
          // Safety net: onPanUpdate normally never fires without a prior
          // onPanStart, but if it ever does, still record the move so it
          // can be undone.
          if (!_dragSnapshotPushed) {
            _pushUndo();
            _dragSnapshotPushed = true;
          }
          setState(() => b.position += d.delta);
        },

        onPanEnd: (_) {
          _dragSnapshotPushed = false;
        },

        child: Tooltip(
          message: invalidBlocks.contains(b)
              ? 'Bloco com erro de compilação'
              : '',
          child: Container(
            width: 170,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: invalidBlocks.contains(b)
                    ? AppColors.danger
                    : linkingFrom == b
                    ? AppColors.accent
                    : selectedBlock == b
                    ? AppColors.primaryDark
                    : AppColors.border,
                width: invalidBlocks.contains(b) ? 3 : 2,
              ),
            ),
            // Column (instead of a bare Row) so we can add an optional
            // subtitle line with the constant-value summary right below
            // the icon/title row, without touching layout elsewhere
            // (connections still anchor off the same block width/position
            // as before).
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(b.icon, color: AppColors.foregroundSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        b.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.foreground),
                      ),
                    ),
                  ],
                ),
                if (constantSummary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    constantSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: AppFontSize.xs,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool hasConstantInput(LogicBlock b) {
    return b.inputs.any((i) => i?.type == InputSourceType.constant);
  }

  final Map<String, List<TextEditingController>> _inputControllers = {};

  List<TextEditingController> _controllersFor(LogicBlock b) {
    return _inputControllers.putIfAbsent(
      b.id,
      () => List.generate(
        b.maxInputs,
        (i) => TextEditingController(
          text: b.inputs[i]?.constant?.toString() ?? '',
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // PID gain/output-clamp controllers, kept separate from
  // _inputControllers since they don't map to inputs[] — they map
  // directly to LogicBlock.pidKp/pidKi/pidKd/pidOutMin/pidOutMax.
  // ---------------------------------------------------------------------
  final Map<String, List<TextEditingController>> _pidControllers = {};

  List<TextEditingController> _pidControllersFor(LogicBlock b) {
    return _pidControllers.putIfAbsent(
      b.id,
      () => [
        TextEditingController(text: b.pidKp.toString()),
        TextEditingController(text: b.pidKi.toString()),
        TextEditingController(text: b.pidKd.toString()),
        TextEditingController(text: b.pidOutMin.toString()),
        TextEditingController(text: b.pidOutMax.toString()),
      ],
    );
  }

  Widget _pidGainsEditor(LogicBlock b) {
    final ctrls = _pidControllersFor(b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: ctrls[0],
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: 'Kp (Proporcional)',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            if (parsed != null) setState(() => b.pidKp = parsed);
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: ctrls[1],
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: 'Ki (Integral)',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            if (parsed != null) setState(() => b.pidKi = parsed);
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: ctrls[2],
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: 'Kd (Derivativo)',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            if (parsed != null) setState(() => b.pidKd = parsed);
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: ctrls[3],
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: 'Saída mínima (%)',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            if (parsed != null) setState(() => b.pidOutMin = parsed);
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: ctrls[4],
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: 'Saída máxima (%)',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            if (parsed != null) setState(() => b.pidOutMax = parsed);
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // TPO period controller, kept separate from _inputControllers/
  // _pidControllers for the same reason as the PID gains above: it maps
  // directly to LogicBlock.tpoPeriodMs, not to inputs[].
  // ---------------------------------------------------------------------
  final Map<String, List<TextEditingController>> _tpoControllers = {};

  List<TextEditingController> _tpoControllersFor(LogicBlock b) {
    return _tpoControllers.putIfAbsent(
      b.id,
      () => [TextEditingController(text: b.tpoPeriodMs.toString())],
    );
  }

  Widget _tpoConfigEditor(LogicBlock b) {
    final ctrls = _tpoControllersFor(b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: ctrls[0],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Período (ms)',
            hintText: 'Duração total do ciclo liga+desliga',
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v);
            // Reject 0/negative: a zero-length cycle divides by nothing
            // useful and the firmware would just spin the on/off check
            // every scan for no reason.
            if (parsed != null && parsed > 0) {
              setState(() => b.tpoPeriodMs = parsed);
            }
          },
        ),
      ],
    );
  }

  Widget _inputEditor(LogicBlock b, int index) {
    final input = b.inputs[index];

    // NOT gate: the A input (index 0) is always fixed at 1 and not
    // editable through the UI — just show an informational text. This
    // guarantees nobody accidentally changes this value and breaks the
    // "1 - B" computation.
    if (isNotGate(b) && index == 0) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'A = 1 (fixo) — o resultado será 1 − Entrada, ou seja, NÃO(Entrada)',
          style: TextStyle(
            fontSize: AppFontSize.sm,
            color: AppColors.foregroundDisabled,
          ),
        ),
      );
    }

    final isAoPercent = isAnalogOutput(b);
    final isTimeField = isTimerTime(b, index);
    final isTriggerField = isTimerTrigger(b, index);
    final isPidEnableField = isPidEnable(b, index);
    final isPidPVField = isPidPV(b, index);
    final isPidSetpointField = isPidSetpoint(b, index);
    final isTpoDutyField = isTpoDuty(b, index);

    String labelText;
    String hintText;
    if (isAoPercent) {
      labelText = 'PWM (%)';
      hintText = '0 a 100';
    } else if (isTimeField) {
      labelText = 'Tempo (ms)';
      hintText = 'Duração em milissegundos';
    } else if (isTriggerField) {
      labelText = 'Gatilho';
      hintText = '0 ou 1';
    } else if (isPidEnableField) {
      labelText = 'Habilita (Enable)';
      hintText = '0 ou 1';
    } else if (isPidPVField) {
      labelText = 'Variável de Processo (PV)';
      hintText = 'Valor fixo (normalmente ligado a uma entrada AI)';
    } else if (isPidSetpointField) {
      labelText = 'Setpoint';
      hintText = 'Valor desejado';
    } else if (isTpoDutyField) {
      labelText = 'Duty cycle (%)';
      hintText = '0 a 100 — normalmente ligado à saída do PID';
    } else {
      labelText = 'Entrada ${_inputShortLabel(b, index)}';
      hintText = 'Valor fixo';
    }

    // Timer's time input (index 1), and all three PID inputs
    // (enable/PV/setpoint), are always independently editable as
    // constants — they must never be blocked by the "only one constant
    // per block" rule used for math/compare's shared A/B pair, since
    // each of them is an independent configuration value rather than a
    // shared slot. TPO doesn't need this bypass at all: it only ever has
    // one input slot (index 0), so the "shared slot" rule can never
    // trigger for it in the first place.
    final bypassSharedConstantRule = isTimeField || isPidBlock(b);
    final alreadyHasConstant = bypassSharedConstantRule
        ? false
        : (hasConstantInput(b) && input?.type != InputSourceType.constant);

    final controller = _controllersFor(b)[index];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12), // spacing
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (alreadyHasConstant)
            const Text(
              'Somente ligação com bloco',
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: AppColors.foregroundDisabled,
              ),
            )
          else if (input == null || input.type == InputSourceType.constant) ...[
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: labelText,
                hintText: hintText,
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (v) {
                setState(() {
                  if (v.trim().isEmpty) {
                    b.inputs[index] = null;
                  } else {
                    double value = double.tryParse(v) ?? 0;

                    // Clamp the PWM duty cycle (AO) and the TPO duty
                    // cycle to a valid 0-100% range so an out-of-range
                    // typo can't be sent to the device.
                    if (isAoPercent || isTpoDutyField) {
                      value = value.clamp(0, 100);
                    }

                    // Trigger and PID enable are digital signals — keep
                    // them to 0/1 so they behave the same as a linked
                    // DI/compare block would.
                    if (isTriggerField || isPidEnableField) {
                      value = value.clamp(0, 1);
                    }

                    b.inputs[index] = InputSource.constant(value);
                  }
                });
              },
            ),
          ],
          if (input != null && input.type == InputSourceType.block)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Ligado a: ${input.fromBlock!.title}',
                style: const TextStyle(fontSize: AppFontSize.sm),
              ),
            ),
        ],
      ),
    );
  }

  Widget _drawConnection(Connection c) {
    return CustomPaint(painter: _ConnectionPainter(c.from, c.to));
  }

  Widget _blockProperties(LogicBlock b) {
    final inputs = inputConnections(b);
    final outputs = outputConnections(b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(b.icon, color: AppColors.foregroundSecondary),
            const SizedBox(width: 8),
            Text(
              b.title,
              style: const TextStyle(
                fontSize: AppFontSize.lg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),
        Text(
          'Tipo: ${b.type.name}',
          style: const TextStyle(color: AppColors.foregroundMuted),
        ),

        Text(
          'ID: ${b.id}',
          style: const TextStyle(
            color: AppColors.foregroundDisabled,
            fontSize: AppFontSize.xs,
          ),
        ),

        const Divider(height: 24),

        const Text(
          'Entradas (blocos)',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),

        if (inputs.isEmpty)
          const Text(
            '— nenhuma —',
            style: TextStyle(color: AppColors.foregroundDisabled),
          )
        else
          ...inputs.asMap().entries.map((e) {
            final from = e.value.from;
            final idx = e.value.inputIndex;
            final label = _inputShortLabel(b, idx);

            return Row(
              children: [
                Text(
                  '$label ← ',
                  style: const TextStyle(color: AppColors.foregroundMuted),
                ),
                Text(from.title),
              ],
            );
          }),

        const Divider(height: 24),

        // Analog output (AO/PWM), Timer, PID, and TPO blocks all get
        // their fixed-value editor(s) rendered here too, not just math/
        // compare. Timer shows both slots (trigger + time); PID shows
        // its three slots (enable/PV/setpoint) plus the gains editor
        // right below; TPO shows its single duty slot plus the period
        // editor right below. AND/OR/NOT gates are also BlockType.math,
        // so they fall into this same block of code.
        if (b.type == BlockType.math ||
            b.type == BlockType.compare ||
            b.type == BlockType.timer ||
            isPidBlock(b) ||
            isTpoBlock(b) ||
            isAnalogOutput(b)) ...[
          Text(
            isAnalogOutput(b)
                ? 'Valor fixo (PWM)'
                : b.type == BlockType.timer
                ? 'Gatilho e tempo'
                : isPidBlock(b)
                ? 'Entradas do PID (Habilita / PV / Setpoint)'
                : isTpoBlock(b)
                ? 'Entrada do TPO (duty cycle)'
                : isNotGate(b)
                ? 'Porta NÃO (inversora)'
                : 'Entradas (valores fixos)',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),

          ...List.generate(b.maxInputs, (i) => _inputEditor(b, i)),

          if (isPidBlock(b)) ...[
            const SizedBox(height: 4),
            const Text(
              'Ganhos do controlador',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _pidGainsEditor(b),
          ],

          if (isTpoBlock(b)) ...[
            const SizedBox(height: 4),
            const Text(
              'Configuração do ciclo',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _tpoConfigEditor(b),
          ],

          const Divider(height: 24),
        ],

        const Text('Saídas', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),

        if (outputs.isEmpty)
          const Text(
            '— nenhuma —',
            style: TextStyle(color: AppColors.foregroundDisabled),
          )
        else
          ...outputs.map(
            (c) => Row(
              children: [
                const Text(
                  '→ ',
                  style: TextStyle(color: AppColors.foregroundMuted),
                ),
                Text(c.to.title),
              ],
            ),
          ),

        const Spacer(),

        _blockActions(b),
      ],
    );
  }

  Widget _blockActions(LogicBlock b) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            icon: const Icon(
              Icons.delete,
              size: 18,
              color: AppColors.foreground,
            ),
            label: const Text(
              'Excluir',
              style: TextStyle(color: AppColors.foreground),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.dangerStrong,
            ),
            onPressed: () {
              setState(() {
                connections.removeWhere((c) => c.from == b || c.to == b);

                for (final other in blocks) {
                  for (int i = 0; i < other.inputs.length; i++) {
                    if (other.inputs[i]?.fromBlock == b) {
                      other.inputs[i] = null;
                    }
                  }
                }

                blocks.remove(b);
                if (blocks.isEmpty) _idCounter = 0;
                _inputControllers.remove(b.id);
                _pidControllers.remove(b.id);
                _tpoControllers.remove(b.id);
                invalidBlocks.remove(b);
                selectedBlock = null;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _propertiesPanel() {
    return Container(
      width: 280,
      color: panel,
      padding: const EdgeInsets.all(12),
      child: selectedBlock == null
          ? const Text(
              'Selecione um bloco',
              style: TextStyle(color: AppColors.foregroundSecondary),
            )
          : _blockProperties(selectedBlock!),
    );
  }
}

class _ConnectionPainter extends CustomPainter {
  final LogicBlock from;
  final LogicBlock to;

  _ConnectionPainter(this.from, this.to);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // output port center (inside the block)
    final start = from.position + const Offset(140, 34);

    // input port center (inside the block)
    final end = to.position + const Offset(0, 34);

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(start.dx + 50, start.dy, end.dx - 50, end.dy, end.dx, end.dy);

    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_) => true;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.foreground.withOpacity(0.04)
      ..strokeWidth = 1;

    const step = 24.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}
