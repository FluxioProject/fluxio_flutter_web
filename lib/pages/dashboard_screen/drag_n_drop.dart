import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tcc_flutter/models/channel_config.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/mqtt/mqtt_manager.dart';
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

  final Set<LogicBlock> invalidBlocks = {};

  final TransformationController _transformCtrl = TransformationController();
  final FocusNode _focusNode = FocusNode();
  bool editingText = false;

  Timer? _logicTimeoutTimer;
  bool _logicReceived = false;
  LogicBlock? _clipboardBlock;

  final List<List<LogicBlock>> _undoStack = [];
  final List<List<LogicBlock>> _redoStack = [];

  int _idCounter = 0;
  List<Connection> inputConnections(LogicBlock b) =>
      connections.where((c) => c.to == b).toList();

  List<Connection> outputConnections(LogicBlock b) =>
      connections.where((c) => c.from == b).toList();

  int inputsCount(LogicBlock b) => connections.where((c) => c.to == b).length;

  int outputsCount(LogicBlock b) =>
      connections.where((c) => c.from == b).length;

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
    };

    if (b.type == BlockType.io) {
      base['io'] = [b.ioType!, b.ioChannel!];
    }

    if (b.type == BlockType.math) {
      base['op'] = _mathOpFromTitle(b.title);
    } else if (b.type == BlockType.compare) {
      base['op'] = _compareOpFromTitle(b.title);
    }

    if (b.type == BlockType.timer) {
      base['time'] = b.inputs[0]?.constant ?? 0;
    }

    return base;
  }

  Map<String, dynamic> _buildLogicJson() {
    return {
      'v': 1, // versão do schema
      'blocks': blocks.map(_serializeBlock).toList(),
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _showRiskWarning();
      showMessage(
        context,
        'Dica: Double click em um bloco e depois click em outra para fazer a ligação.',
        false,
      );
      mqttManager.subscribe(
        'device/${widget.device.deviceId}/logic',
        _onLogicMessage,
      );
      mqttManager.publish(
        'device/${widget.device.deviceId}/control',
        jsonEncode({'type': 'logic_get'}),
      );
      _startLogicTimeout();
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
    mqttManager.unsubscribe('device/${widget.device.deviceId}/logic');
    super.dispose();
  }

  void _onLogicMessage(String payload) {
    print('Logic message received: $payload');
    _logicReceived = true;
    _logicTimeoutTimer?.cancel();

    try {
      final json = jsonDecode(payload);

      // valida versão
      if (json['v'] != 2 && json['v'] != 1) {
        debugPrint('Versão de lógica não suportada');
        return;
      }

      _deserializeLogic(json);
    } catch (e) {
      debugPrint('Erro ao decodificar lógica: $e');
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
      final id = b['id'];
      final type = BlockType.values[b['t']];
      final io = b['io'];

      Offset position;

      // se já existir posição salva → respeita
      if (b.containsKey('x') && b.containsKey('y')) {
        position = Offset((b['x']).toDouble(), (b['y']).toDouble());
      } else {
        // layout automático por tipo
        if (type == BlockType.io &&
            (io[0] == IOType.ai.index || io[0] == IOType.di.index)) {
          position = Offset(xInput, yInput);
          yInput += spacingY;
        } else if (type == BlockType.io &&
            (io[0] == IOType.ao.index || io[0] == IOType.doo.index)) {
          position = Offset(xOutput, yOutput);
          yOutput += spacingY;
        } else {
          // math / compare / timer
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

      blocks.add(block);
      map[id] = block;

      _idCounter = _idCounter <= id ? id + 1 : _idCounter;
    }

    // 2️ conecta entradas
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
      final io = b['io'];
      if (io == null) return 'IO ?';

      final ioType = io[0];
      final channel = io[1];

      return _ioTitle(ioType, channel);
    }

    return 'Bloco';
  }

  IconData _iconFromBlock(Map b) {
    if (b['t'] == BlockType.math.index) return Icons.calculate;
    if (b['t'] == BlockType.compare.index) return Icons.compare_arrows;
    if (b['t'] == BlockType.timer.index) {
      return Icons.timer;
    }

    if (b['t'] == BlockType.io.index) {
      final io = b['io'];
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
        // exige uma entrada
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
              final label = b.maxInputs > 1 ? (i == 0 ? 'A' : 'B') : 'IN';
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

    _showCompileSuccess();
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

  void _showCompileSuccess() {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: panel,
          title: const Text(
            'Compilação concluída',
            style: TextStyle(color: Colors.greenAccent),
          ),
          content: const Text(
            'Lógica válida.\nPronta para envio.',
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

  List<LogicBlock> _cloneBlocks(List<LogicBlock> src) {
    return src
        .map(
          (b) => LogicBlock(
            id: b.id,
            title: b.title,
            icon: b.icon,
            type: b.type,
            position: b.position,
            ioType: b.ioType,
            ioChannel: b.ioChannel,
          ),
        )
        .toList();
  }

  void _pushUndo() {
    _undoStack.add(_cloneBlocks(blocks));
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

          // ===== UNDO =====
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
            if (_undoStack.isNotEmpty) {
              _redoStack.add(_cloneBlocks(blocks));
              setState(() {
                blocks
                  ..clear()
                  ..addAll(_undoStack.removeLast());
              });
            }
            return;
          }

          // ===== REDO =====
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyY) {
            if (_redoStack.isNotEmpty) {
              _undoStack.add(_cloneBlocks(blocks));
              setState(() {
                blocks
                  ..clear()
                  ..addAll(_redoStack.removeLast());
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
            (event.logicalKey == LogicalKeyboardKey.delete ||
                event.logicalKey == LogicalKeyboardKey.backspace)) {
          if (selectedBlock != null) {
            _pushUndo();

            setState(() {
              connections.removeWhere(
                (c) => c.from == selectedBlock || c.to == selectedBlock,
              );
              blocks.remove(selectedBlock);
              _inputControllers.remove(selectedBlock!.id);
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
              ...List.generate(widget.aiCfg.length, (i) {
                final c = widget.aiCfg[i];
                return _dragIO(
                  title: c.name,
                  icon: Icons.input,
                  ioType: IOType.ai,
                  channel: i,
                );
              }),

              // DI
              ...List.generate(widget.diCfg.length, (i) {
                final c = widget.diCfg[i];
                return _dragIO(
                  title: c.name,
                  icon: Icons.toggle_on,
                  ioType: IOType.di,
                  channel: i,
                );
              }),

              // AO
              ...List.generate(widget.aoCfg.length, (i) {
                final c = widget.aoCfg[i];
                return _dragIO(
                  title: c.name,
                  icon: Icons.output,
                  ioType: IOType.ao,
                  channel: i,
                );
              }),

              // DO
              ...List.generate(widget.doCfg.length, (i) {
                final c = widget.doCfg[i];
                return _dragIO(
                  title: c.name,
                  icon: Icons.toggle_off,
                  ioType: IOType.doo,
                  channel: i,
                );
              }),
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
                blocks.add(
                  LogicBlock(
                    id: 'b${_idCounter++}',
                    title: d.data['title'],
                    icon: d.data['icon'],
                    type: d.data['type'],
                    ioType: d.data['ioType'],
                    ioChannel: d.data['channel'],
                    position: d.offset - const Offset(260, kToolbarHeight + 10),
                  ),
                );
              });
            },
            builder: (_, __, ___) {
              return Listener(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      selectedBlock = null;
                      linkingFrom = null;
                    });
                  },
                  child: SizedBox(
                    width: 3000,
                    height: 3000,
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
    return Positioned(
      left: b.position.dx,
      top: b.position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,

        onTap: () {
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

              final idx = b.inputs.indexWhere((i) => i == null);

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
            child: Row(
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
    final label = index == 0 ? 'A' : 'B';

    final alreadyHasConstant =
        hasConstantInput(b) && input?.type != InputSourceType.constant;

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
                labelText: 'Entrada $label',
                hintText: 'Valor fixo',
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
                    b.inputs[index] = InputSource.constant(
                      double.tryParse(v) ?? 0,
                    );
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
            final idx = e.key;
            final from = e.value.from;
            final label = b.maxInputs > 1 ? (idx == 0 ? 'A' : 'B') : 'IN';

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

        if (b.type == BlockType.math ||
            b.type == BlockType.compare ||
            b.type == BlockType.timer) ...[
          const Text(
            'Entradas (valores fixos)',
            style: TextStyle(fontWeight: FontWeight.w600),
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
                blocks.remove(b);
                if (blocks.isEmpty) _idCounter = 0;
                _inputControllers.remove(b.id);
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
