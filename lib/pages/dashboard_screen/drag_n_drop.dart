import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/blocks.dart';
import 'package:tcc_flutter/pages/dashboard_screen/widgets/enums.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

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
  static const bg = Color(0xFF141414);
  static const panel = Color(0xFF1E1E1E);
  static const accent = Color(0xFF4CAF50);

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

  static const Duration _sendConfirmTimeout = Duration(seconds: 6);

  final Session _session = Session();

  // ---------------------------------------------------------------------
  // LÓGICA BOOLEANA (AND / OR / NOT) — SEM MUDANÇA DE FIRMWARE/PROTOCOLO
  //
  // O firmware só entende blocos "math" com op 0=soma, 1=sub, 2=mul, 3=div
  // (ver logic.cpp / executeLogic / BLOCK_MATH). Não existe op de AND/OR/NOT
  // no logic.cpp e não vamos adicionar um — em vez disso, os blocos
  // "E (AND)", "OU (OR)" e "NÃO (NOT)" abaixo são, para o firmware,
  // blocos "math" completamente normais:
  //
  //   E (AND)  -> multiplicação (a * b). Para entradas 0/1: 1*1=1, 1*0=0,
  //               0*0=0 -> comporta-se exatamente como um AND.
  //   OU (OR)  -> soma (a + b). Para entradas 0/1: 0+0=0, 1+0=1, 1+1=2.
  //               O firmware sempre trata qualquer valor > 0.5 como
  //               "verdadeiro" (DO, gatilho de Timer, Compare, etc. -
  //               ver `in > 0.5f` e `(b.lastValue > 0.5f) ? 1 : 0` em
  //               logic.cpp), então o resultado 2 ainda é lido como
  //               "ligado". Isso funciona perfeitamente quando a saída do
  //               OR alimenta um DO, um Timer ou um Compare.
  //               ATENÇÃO: se você ligar a saída de um OR diretamente em
  //               uma saída analógica (AO/PWM), 2 será interpretado como
  //               2%, não 100% — para AO, prefira alimentar o OR em um
  //               Compare (> 0.5) antes de ir para o AO.
  //   NÃO (NOT) -> subtração fixa (1 - b). A entrada "A" desse bloco é
  //               travada em 1 pela própria interface (não aparece campo
  //               editável pra ela); só a entrada "B" é ligável. Resultado
  //               1-0=1 (nega falso) e 1-1=0 (nega verdadeiro).
  //
  // Como o protocolo (`in`, `op`, `t`) não muda em nada, o ESP32 não
  // precisa de nenhuma alteração: ele já sabe fazer soma/subtração/
  // multiplicação. Só o app Flutter precisa saber "desenhar" esses
  // blocos de math com nomes/ícones amigáveis de porta lógica.
  //
  // Para dar nome bonito ao bloco quando ele volta do dispositivo (via
  // "logic_get"), gravamos um campo extra 'lg' (logic-gate) no JSON:
  // 0 = bloco math normal, 1 = AND, 2 = OR, 3 = NOT. Esse campo é
  // simplesmente ignorado pelo ArduinoJson no firmware (campos
  // desconhecidos não quebram o parser) e SÓ é usado pelo próprio app
  // para reconstruir o título correto ao reler o programa salvo.
  //
  // ATENÇÃO / PREMISSA A VALIDAR: isso só sobrevive à ida-e-volta se o
  // firmware realmente republica, em "logic_get", a MESMA string JSON
  // recebida (isso é sugerido pela variável `logicJsonCache` em
  // logic.cpp, mas o handler MQTT que trata `type: "logic"` não estava
  // nos arquivos que você me mandou). Se o firmware reconstrói o JSON
  // a partir dos campos internos (id/t/op/in/io) e descarta campos
  // desconhecidos, o 'lg' se perde depois de um reload — a lógica
  // continua funcionando 100% certo (o valor calculado não muda em
  // nada), só o rótulo do bloco no editor volta a aparecer como
  // "Multiplicação"/"Soma"/"Subtração" genérico em vez de "E (AND)" /
  // "OU (OR)" / "NÃO (NOT)". É só estética, não afeta o funcionamento.
  // Pelo mesmo motivo, a comparação de confirmação (_logicMatchesSent)
  // ignora deliberadamente o campo 'lg'.
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
      // Portas lógicas: reaproveitam os mesmos ops de math do firmware.
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
      // NEW: posição no canvas. O firmware ignora campos desconhecidos
      // (mesma lógica do 'lg'), então é seguro mandar isso também no
      // payload MQTT — mas o motivo real de existir é o backend, pra
      // restaurar o layout exato ao reabrir o editor sem o device online.
      'x': b.position.dx,
      'y': b.position.dy,
    };

    if (b.type == BlockType.io) {
      base['io'] = [b.ioType!, b.ioChannel!];
    }

    if (b.type == BlockType.math) {
      base['op'] = _mathOpFromTitle(b.title);
      // Campo extra, só para o app — o firmware ignora. Guarda se este
      // bloco math é na verdade uma porta AND/OR/NOT "disfarçada", para
      // conseguirmos redesenhar o nome certo se o programa for relido
      // do dispositivo (ver nota grande acima).
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

    return base;
  }

  Map<String, dynamic> _buildLogicJson() {
    return {
      'v': 1, // versão do schema
      'blocks': blocks.map(_serializeBlock).toList(),
    };
  }

  Future<void> _loadLogicFromBackend() async {
    try {
      final resp = await _session.getObj(
        'devices/${widget.device.deviceId}/logic',
        context,
      );

      // getObj decodifica JSON quando dá, senão devolve a string crua do
      // corpo (ex.: a mensagem 404 "Nenhuma lógica salva..." que o backend
      // manda como texto puro). Só tratamos como sucesso se veio um Map
      // com os campos esperados.
      if (resp is Map<String, dynamic> && resp.containsKey('blocks')) {
        _deserializeLogic(resp);
        _loadedFromBackend = true;
      }
      // Se não: nenhuma lógica salva ainda pra esse device, ou erro —
      // segue o fluxo normal (pedir pro device via MQTT).
    } catch (e) {
      // Sem conexão com o backend — não é fatal, só cai no fluxo MQTT normal.
      print('Erro ao carregar lógica do backend: $e');
    }
  }

  @override
  void initState() {
    super.initState();
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
        _logicReceived = true; // evita o aviso de "nenhuma lógica encontrada"
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
        _showSendConfirmationResult(matched: matched);
        return;
      }

      if (_loadedFromBackend) {
        print('Ignorando mensagem MQTT retida: já carregado do backend');
        return;
      }

      _deserializeLogic(json);
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

    // 1 cria blocos
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
        // entrada
        if (type == BlockType.io &&
            io != null &&
            (io[0] == IOType.ai.index || io[0] == IOType.di.index)) {
          position = Offset(xInput, yInput);
          yInput += spacingY;

          // saída
        } else if (type == BlockType.io &&
            io != null &&
            (io[0] == IOType.ao.index || io[0] == IOType.doo.index)) {
          position = Offset(xOutput, yOutput);
          yOutput += spacingY;

          // processamento (timer/math/compare)
        } else {
          position = Offset(xProcess, yProcess);
          yProcess += spacingY;
        }
      }

      final block = LogicBlock(
        id: 'b$id',
        title: _titleFromBlock(b),
        icon: _iconFromBlock(b),
        type: type,
        ioType: io != null ? io[0] : null,
        ioChannel: io != null ? io[1] : null,
        position: position,
      );

      // TIMER precisa manter o tempo recebido
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

    // 2 conecta entradas
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
      // Se o campo extra 'lg' estiver presente (ver _serializeBlock),
      // reconstrói o nome de porta lógica em vez do nome genérico de
      // math. Se não estiver (ex.: firmware não ecoou o campo de volta),
      // cai no nome genérico — o cálculo continua correto de qualquer
      // forma, só muda o rótulo mostrado no bloco.
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
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'A programação realizada neste editor é de inteira responsabilidade do usuário.\n\n'
            'Configurações incorretas podem causar falhas no equipamento, danos materiais '
            'ou riscos operacionais.\n\n'
            'Utilize este recurso por sua conta e risco.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.greenAccent),
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

  // Porta NOT: A é sempre um valor fixo (1), travado pela própria UI —
  // só existe uma entrada "de verdade" (B), que é a que pode ser ligada.
  bool isNotGate(LogicBlock b) => b.title == kNotTitle;

  // Short label used both in the "linked inputs" list and as a base for
  // the editable-field label below.
  String _inputShortLabel(LogicBlock b, int index) {
    if (isAnalogOutput(b)) return 'PWM';
    if (isTimerTrigger(b, index)) return 'Gatilho';
    if (isTimerTime(b, index)) return 'Tempo';
    if (isNotGate(b)) return index == 0 ? 'A (fixo)' : 'Entrada';
    if (b.maxInputs > 1) return index == 0 ? 'A' : 'B';
    return 'IN';
  }

  // ---------------------------------------------------------------------
  // NEW (UX only, no protocol/firmware change):
  // Builds a short summary string of any fixed ("constant") values
  // currently configured on a block, so it can be shown directly on the
  // block's card in the canvas — e.g. "A=5 · B=3", "PWM: 50%",
  // "Gatilho=1 · Tempo=1000ms". Returns null when there is nothing fixed
  // to show (block has no constants, or is an input IO block which never
  // has inputs at all).
  // ---------------------------------------------------------------------
  String? _constantSummary(LogicBlock b) {
    if (isInputIO(b)) return null;

    final parts = <String>[];

    for (int i = 0; i < b.inputs.length; i++) {
      // Porta NOT: o "A=1" é sempre fixo e não é interessante pro usuário
      // ver no card (o título "NÃO (NOT)" já deixa isso implícito).
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
  // NEW: structural comparison between what we just sent and what the
  // device echoed back via 'logic_get'. Compares by block id (order
  // doesn't matter) and only the fields that affect actual behavior —
  // 'lg' is deliberately excluded since it's a cosmetic, app-only field
  // (see the big AND/OR/NOT comment above) the firmware may not echo.
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

  // NEW: kicks off the post-send confirmation round trip described in
  // the big comment above _awaitingSendConfirmation.
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

  // NEW: reports the outcome of the post-send confirmation.
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
      color = Colors.greenAccent;
    } else if (timedOut) {
      title = 'Sem confirmação do dispositivo';
      content =
          'A lógica foi enviada, mas o dispositivo não respondeu ao pedido '
          'de confirmação (logic_get) a tempo. Verifique a conexão e tente '
          'enviar novamente se necessário.';
      color = Colors.orangeAccent;
    } else if (decodeError) {
      title = 'Resposta inválida do dispositivo';
      content =
          'A lógica foi enviada, mas a resposta do dispositivo ao pedido '
          'de confirmação não pôde ser interpretada.';
      color = Colors.orangeAccent;
    } else {
      title = 'Lógica enviada, mas não confere';
      content =
          'O dispositivo respondeu, mas o que ele tem salvo não bate com o '
          'que foi enviado. Recomenda-se enviar novamente.';
      color = Colors.orangeAccent;
    }

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: panel,
          title: Text(title, style: TextStyle(color: color)),
          content: Text(content, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.greenAccent),
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
            style: TextStyle(color: Colors.orangeAccent),
          ),
          content: const Text(
            'O dispositivo está offline no momento. A lógica foi salva no '
            'backend e será enviada automaticamente para o dispositivo assim '
            'que ele se reconectar.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.greenAccent),
              ),
            ),
          ],
        );
      },
    );
  }

  void _compileAndSend() {
    invalidBlocks.clear();
    final errors = <String>[];

    for (final b in blocks) {
      final outputs = outputConnections(b);
      bool hasError = false;

      // BLOCO DE ENTRADA (AI / DI)
      if (isInputIO(b)) {
        // não exige entradas
        // exige ao menos uma saída
        if (outputs.isEmpty) {
          errors.add(
            'Entrada "${b.title}" (${b.id}) não está ligada a nenhum bloco',
          );
          hasError = true;
        }
      }
      // BLOCO DE SAÍDA (AO / DO)
      else if (isOutputIO(b)) {
        // exige uma entrada (agora pode ser uma ligação OU um valor fixo,
        // ver _inputEditor / _blockProperties para blocos AO)
        if (b.inputs[0] == null) {
          errors.add('Saída "${b.title}" (${b.id}) está sem entrada');
          hasError = true;
        }
        // não exige saída
      }
      // BLOCO DE PROCESSAMENTO (math / compare / timer)
      // BLOCO DE PROCESSAMENTO
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
        // OUTROS (math / compare)
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

    setState(() {}); // força repaint das bordas

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
    mqttManager.publish(
      'device/${widget.device.deviceId}/control',
      jsonEncode(payload),
    );

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
            style: TextStyle(color: Colors.redAccent),
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
                        style: const TextStyle(color: Colors.white70),
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
                style: TextStyle(color: Colors.greenAccent),
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
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 180, 49, 39),
            ),
            onPressed: () {
              Navigator.pop(context);
              _clearAllLogic();
            },
            child: const Text(
              'Apagar tudo',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _clearAllLogic() {
    _pushUndo(); // permite desfazer se quiser depois

    setState(() {
      blocks.clear();
      connections.clear();
      invalidBlocks.clear();
      selectedBlock = null;
      linkingFrom = null;
      isLinkingMode = false;
      _inputControllers.clear();

      // MUITO IMPORTANTE
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
            IconButton(
              tooltip: 'Limpar lógica (apagar todos os blocos)',
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              onPressed: _confirmClearAll,
            ),

            IconButton(
              tooltip: 'Compilar e Enviar',
              icon: const Icon(Icons.send, color: Colors.greenAccent),
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
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            _group('IO do Dispositivo', Colors.greenAccent, [
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

            _group('Matemática', Colors.blueAccent, [
              _drag('Soma', Icons.add, BlockType.math),
              _drag('Subtração', Icons.remove, BlockType.math),
              _drag('Multiplicação', Icons.close, BlockType.math),
              _drag('Divisão', Icons.calculate, BlockType.math),
            ]),

            _group('Comparação', Colors.orangeAccent, [
              _drag('Maior que', Icons.arrow_upward, BlockType.compare),
              _drag('Maior ou igual', Icons.trending_up, BlockType.compare),
              _drag('Menor que', Icons.arrow_downward, BlockType.compare),
              _drag('Menor ou igual', Icons.trending_down, BlockType.compare),
              _drag('Igual', Icons.compare_arrows, BlockType.compare),
            ]),

            // ---------------------------------------------------------
            // NOVO: portas lógicas booleanas. Por baixo dos panos elas
            // são blocos "math" comuns (mesmo BlockType do firmware) —
            // ver o comentário grande logo acima de _mathOpFromTitle
            // explicando por que isso funciona sem tocar no ESP32.
            // ---------------------------------------------------------
            _group('Lógica (AND / OR / NOT)', Colors.tealAccent, [
              _drag(kAndTitle, Icons.merge_type, BlockType.math),
              _drag(kOrTitle, Icons.call_split, BlockType.math),
              _drag(kNotTitle, Icons.block, BlockType.math),
            ]),

            _group('Tempo', Colors.purpleAccent, [
              _drag('Timer', Icons.timer, BlockType.timer),
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
        border: Border.all(color: dragging ? accent : Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
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
          minScale: 0.5,
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

                // Porta NOT recém-criada já nasce com A=1 fixo, sobrando
                // só a entrada B como ligável (ver isNotGate / _inputEditor).
                if (newBlock.title == kNotTitle) {
                  newBlock.inputs[0] = InputSource.constant(1);
                }

                blocks.add(newBlock);
              });
            },
            builder: (_, __, ___) {
              return Listener(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // NEW: restores keyboard focus to the editor's
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
                    width: 25000,
                    height: 25000,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _GridPainter()),
                        ),

                        // conexões fixas
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
        // botão de ocultar/mostrar toolbox
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
              splashColor: Colors.white.withOpacity(0.08),
              highlightColor: Colors.white.withOpacity(0.04),
              onTap: () {
                setState(() => toolboxVisible = !toolboxVisible);
              },
              child: SizedBox(
                width: 28,
                height: 48,
                child: Icon(
                  toolboxVisible ? Icons.chevron_left : Icons.chevron_right,
                  color: Colors.white70,
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
                color: Colors.black.withOpacity(0.4),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _blockWidget(LogicBlock b) {
    // NEW: fetch the constant-value summary (e.g. "A=5 · B=3") once per
    // build so it can be rendered as a subtitle below the block title.
    final constantSummary = _constantSummary(b);

    return Positioned(
      left: b.position.dx,
      top: b.position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,

        onTap: () {
          // NEW: same focus-reclaiming fix as the canvas background tap
          // above — makes sure Delete/Ctrl+C/Ctrl+Z/Ctrl+Y keep working
          // after interacting with a TextField in the properties panel.
          _focusNode.requestFocus();
          setState(() {
            invalidBlocks.remove(b);

            //  Se está em modo ligação
            if (isLinkingMode && linkingFrom != null) {
              // clicou no mesmo bloco → cancela ligação
              if (linkingFrom == b) {
                isLinkingMode = false;
                linkingFrom = null;
                return;
              }

              // ❌ limite de saída
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

              // limite de entrada
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

              // FIX: escolhe o índice de destino da ligação de forma
              // explícita por tipo de bloco, em vez de só procurar um
              // slot vazio (o que falhava sempre que o slot já tinha um
              // valor fixo digitado, como "PWM: 50%" — indexWhere nunca
              // achava null e a ligação era descartada silenciosamente).
              //
              // - AO/DO (saída) e gatilho do Timer: SEMPRE índice 0,
              //   porque é o único índice que o firmware realmente lê
              //   (getInputValue(b.inputs[0]) em logic.cpp). Substitui
              //   qualquer valor fixo que já estivesse lá.
              // - Porta NOT: sempre índice 1 (a entrada B) — a entrada A
              //   é travada em 1 pela própria UI.
              // - Math/Compare genéricos: primeiro tenta achar um slot
              //   vazio; se não achar (os dois já têm valor fixo),
              //   substitui o primeiro que só tinha uma constante em vez
              //   de travar sem fazer nada.
              int idx;
              if (isOutputIO(b) || b.type == BlockType.timer) {
                idx = 0;
              } else if (isNotGate(b)) {
                idx = 1;
              } else {
                idx = b.inputs.indexWhere((i) => i == null);
                if (idx == -1) {
                  idx = b.inputs.indexWhere(
                    (i) => i?.type == InputSourceType.constant,
                  );
                }
              }

              // Só bloqueia se o destino já é uma ligação de BLOCO de
              // verdade — um valor fixo (constante) pode sempre ser
              // sobrescrito por uma nova ligação.
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

            // Caso NORMAL: apenas selecionar
            selectedBlock = b;
          });
        },
        onDoubleTap: () {
          // NEW: same focus-reclaiming fix, so entering link mode also
          // guarantees keyboard shortcuts keep working afterwards.
          _focusNode.requestFocus();
          setState(() {
            isLinkingMode = true;
            linkingFrom = b;
          });
        },

        onPanUpdate: (d) {
          setState(() => b.position += d.delta);
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
                    ? Colors.redAccent
                    : linkingFrom == b
                    ? Colors.greenAccent
                    : selectedBlock == b
                    ? const Color.fromARGB(255, 45, 108, 47)
                    : Colors.white10,
                width: invalidBlocks.contains(b) ? 3 : 2,
              ),
            ),
            // NEW: switched from a bare Row to a Column so we can add an
            // optional subtitle line with the constant-value summary
            // right below the icon/title row, without touching layout
            // elsewhere (connections still anchor off the same block
            // width/position as before).
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(b.icon, color: Colors.white70),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        b.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
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
                      color: Colors.greenAccent,
                      fontSize: 11,
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

  Widget _inputEditor(LogicBlock b, int index) {
    final input = b.inputs[index];

    // Porta NOT: a entrada A (index 0) é sempre fixa em 1 e não é
    // editável pela UI — só mostramos um texto informativo. Isso garante
    // que ninguém troque esse valor sem querer e quebre o "1 - B".
    if (isNotGate(b) && index == 0) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'A = 1 (fixo) — o resultado será 1 − Entrada, ou seja, NÃO(Entrada)',
          style: TextStyle(fontSize: 12, color: Colors.white38),
        ),
      );
    }

    final isAoPercent = isAnalogOutput(b);
    final isTimeField = isTimerTime(b, index);
    final isTriggerField = isTimerTrigger(b, index);

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
    } else {
      labelText = 'Entrada ${_inputShortLabel(b, index)}';
      hintText = 'Valor fixo';
    }

    // Timer's time input (index 1) is always independently editable as a
    // constant — it must never be blocked by the "only one constant per
    // block" rule used for math/compare A/B, since time is meant to stay
    // a fixed value no matter what the trigger input is doing.
    final alreadyHasConstant = isTimeField
        ? false
        : (hasConstantInput(b) && input?.type != InputSourceType.constant);

    final controller = _controllersFor(b)[index];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12), // espaçamento
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (alreadyHasConstant)
            const Text(
              'Somente ligação com bloco',
              style: TextStyle(fontSize: 12, color: Colors.white38),
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
                fillColor: const Color(0xFF1A1A1A),
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

                    // Clamp the PWM duty cycle to a valid 0-100% range so
                    // an out-of-range typo can't be sent to the device.
                    if (isAoPercent) {
                      value = value.clamp(0, 100);
                    }

                    // Trigger is a digital signal — keep it to 0/1 so it
                    // behaves the same as a linked DI/compare block would.
                    if (isTriggerField) {
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
                style: const TextStyle(fontSize: 12),
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
            Icon(b.icon, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              b.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),

        const SizedBox(height: 8),
        Text(
          'Tipo: ${b.type.name}',
          style: const TextStyle(color: Colors.white54),
        ),

        Text(
          'ID: ${b.id}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),

        const Divider(height: 24),

        const Text(
          'Entradas (blocos)',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),

        if (inputs.isEmpty)
          const Text('— nenhuma —', style: TextStyle(color: Colors.white38))
        else
          ...inputs.asMap().entries.map((e) {
            final from = e.value.from;
            final idx = e.value.inputIndex;
            final label = _inputShortLabel(b, idx);

            return Row(
              children: [
                Text(
                  '$label ← ',
                  style: const TextStyle(color: Colors.white54),
                ),
                Text(from.title),
              ],
            );
          }),

        const Divider(height: 24),

        // Analog output (AO/PWM) blocks and Timer blocks both get their
        // fixed-value editor(s) rendered here too now, not just
        // math/compare. Timer shows both slots: trigger (link or 0/1) and
        // time (always a typed constant). Portas AND/OR/NOT também são
        // BlockType.math, então caem nesse mesmo bloco de código.
        if (b.type == BlockType.math ||
            b.type == BlockType.compare ||
            b.type == BlockType.timer ||
            isAnalogOutput(b)) ...[
          Text(
            isAnalogOutput(b)
                ? 'Valor fixo (PWM)'
                : b.type == BlockType.timer
                ? 'Gatilho e tempo'
                : isNotGate(b)
                ? 'Porta NÃO (inversora)'
                : 'Entradas (valores fixos)',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),

          ...List.generate(b.maxInputs, (i) => _inputEditor(b, i)),

          const Divider(height: 24),
        ],

        const Text('Saídas', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),

        if (outputs.isEmpty)
          const Text('— nenhuma —', style: TextStyle(color: Colors.white38))
        else
          ...outputs.map(
            (c) => Row(
              children: [
                const Text('→ ', style: TextStyle(color: Colors.white54)),
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
            icon: const Icon(Icons.delete, size: 18, color: Colors.white),
            label: const Text('Excluir', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 210, 67, 67),
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
              style: TextStyle(color: Colors.white70),
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
      ..color = Colors.greenAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // centro do port de saída (dentro do bloco)
    final start = from.position + const Offset(140, 34);

    // centro do port de entrada (dentro do bloco)
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
      ..color = Colors.white.withOpacity(0.04)
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
