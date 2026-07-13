import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';
import 'package:crypto/crypto.dart';

class FirmwareUploadDialog extends StatefulWidget {
  final String deviceId;
  const FirmwareUploadDialog({super.key, required this.deviceId});

  @override
  State<FirmwareUploadDialog> createState() => _FirmwareUploadDialogState();
}

class _FirmwareUploadDialogState extends State<FirmwareUploadDialog> {
  double progress = 0.0;
  bool uploading = false;
  Timer? _timer;

  // Replaces the old PlatformFile-only state: file_picker returns
  // PlatformFile, desktop_drop returns XFile — both get normalized into
  // these two fields so the rest of the widget doesn't care which path
  // the file came from.
  Uint8List? selectedBytes;
  String? selectedFileName;

  String? error;
  String? versionError;

  bool _dragging = false;

  final TextEditingController _versionCtrl = TextEditingController();

  // Latest version already committed for this device, fetched on open so
  // we can warn the user before they try to upload an older/equal version.
  // Null while loading, or if the device has no firmware yet (404).
  String? _latestVersion;
  bool _checkingLatest = true;

  static final RegExp _semverRegex = RegExp(r'^\d+\.\d+\.\d+$');

  // ---------------------------------------------------------------------
  // OTA CONFIRMATION (NEW)
  //
  // Previously "success" only meant the MQTT `ota` command was published —
  // it said nothing about whether the ESP32 actually finished downloading,
  // verifying, and rebooting into the new firmware. That publish is fire
  // and forget from the frontend's point of view.
  //
  // The firmware already announces what it's running: mqtt.cpp publishes
  // a retained status payload containing `fwVersion` on
  // `device/<id>/status`, both right after it connects and every
  // STATUS_HEARTBEAT_MS (2s) while connected. So instead of trusting the
  // publish() call, we now subscribe to that status topic after sending
  // the OTA command and wait for the device to come back online reporting
  // the version we just sent. This mirrors the same pattern already used
  // for logic confirmation in the visual logic builder (publish, then
  // wait for the device's own echo instead of assuming success).
  //
  // Note on scope: this only tells us the device booted back up reporting
  // the new version. If the download/flash fails on the ESP32 side (bad
  // hash, size mismatch, dropped Wi-Fi mid-transfer), the device simply
  // keeps running its old firmware and never reports the new version —
  // that case is indistinguishable here from "still applying, just slow"
  // until the confirmation timeout fires. Telling those two apart would
  // require the firmware to publish an explicit OTA result/failure reason
  // from ota.cpp before each `return false`, which is a firmware change,
  // not just a frontend one.
  // ---------------------------------------------------------------------
  bool _awaitingOtaConfirmation = false;
  Timer? _otaConfirmTimer;
  String? _pendingOtaVersion;

  static const Duration _otaConfirmTimeout = Duration(seconds: 90);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchLatestVersion());
  }

  Future<void> _fetchLatestVersion() async {
    try {
      final obj = await Session().getObj(
        'devices/${widget.deviceId}/firmware/latest',
        context,
      );
      if (!mounted) return;

      final latest = obj['version'] as String?;

      String? nextVersion;
      if (latest != null && _semverRegex.hasMatch(latest)) {
        final parts = latest.split('.').map(int.parse).toList();
        parts[2]++; // Increment patch version (X.Y.Z -> X.Y.(Z+1))
        nextVersion = '${parts[0]}.${parts[1]}.${parts[2]}';
      }

      setState(() {
        _latestVersion = latest;
        if (nextVersion != null) {
          _versionCtrl.text = nextVersion;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _versionCtrl.text = '1.0.0';
        });
      }
    } finally {
      if (mounted) setState(() => _checkingLatest = false);
    }
  }

  // Compares two "X.Y.Z" version strings. Returns <0 if a<b, 0 if equal,
  // >0 if a>b. Assumes both already matched _semverRegex.
  int _compareSemver(String a, String b) {
    final pa = a.split('.').map(int.parse).toList();
    final pb = b.split('.').map(int.parse).toList();
    for (int i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] - pb[i];
    }
    return 0;
  }

  bool _isValidFirmwareName(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.bin') || n.endsWith('.hex') || n.endsWith('.uf2');
  }

  String _extensionOf(String name) => name.split('.').last.toLowerCase();

  // Liability warning.
  Future<bool> _showWarningDialog(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text(
                'Aviso importante',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: const Text(
                'O envio de firmware é de total responsabilidade do usuário.\n\n'
                'Para que o dispositivo continue acessível pela plataforma Fluxio, '
                'o firmware deve conter a biblioteca Fluxio integrada ao projeto '
                'antes da geração do arquivo.\n\n'
                'Um firmware incompatível pode tornar o dispositivo inacessível '
                'ou inutilizável.\n\n'
                'Deseja continuar?',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Entendi, continuar'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  String sha256FromBytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  // Shared by both the file picker button and drag & drop: validates the
  // extension, shows the liability warning, and stores the bytes/name.
  Future<void> _acceptFile(String name, Uint8List bytes) async {
    setState(() => error = null);

    if (!_isValidFirmwareName(name)) {
      setState(() {
        error =
            'Arquivo inválido. Selecione um firmware válido (.bin, .hex, .uf2).';
        selectedBytes = null;
        selectedFileName = null;
      });
      return;
    }

    final accepted = await _showWarningDialog(context);
    if (!accepted) {
      setState(() {
        selectedBytes = null;
        selectedFileName = null;
      });
      return;
    }

    setState(() {
      selectedBytes = bytes;
      selectedFileName = name;
    });
  }

  Future<void> _pickFile() async {
    setState(() => error = null);

    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['bin', 'hex', 'uf2'],
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    await _acceptFile(file.name, file.bytes!);
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    if (uploading || details.files.isEmpty) return;

    final XFile file = details.files.first;
    final bytes = await file.readAsBytes();
    await _acceptFile(file.name, bytes);
  }

  // Validates the typed version against the format (X.Y.Z) and against
  // the latest known version for this device (must be strictly greater).
  // Returns the validated version string, or null if invalid (in which
  // case versionError is already set).
  String? _validateVersion() {
    final v = _versionCtrl.text.trim();

    if (v.isEmpty) {
      setState(() => versionError = 'Informe a versão do firmware');
      return null;
    }

    if (!_semverRegex.hasMatch(v)) {
      setState(() => versionError = 'Formato inválido. Use X.Y.Z (ex: 1.0.0)');
      return null;
    }

    if (_latestVersion != null && _compareSemver(v, _latestVersion!) <= 0) {
      setState(
        () => versionError =
            'Já existe a versão v$_latestVersion para este device. Informe uma versão mais recente.',
      );
      return null;
    }

    setState(() => versionError = null);
    return v;
  }

  Future<void> _startUpload() async {
    if (selectedBytes == null || selectedFileName == null) {
      setState(
        () => error = 'Selecione um arquivo de firmware antes de enviar',
      );
      return;
    }

    final version = _validateVersion();
    if (version == null) return;

    setState(() {
      uploading = true;
      progress = 0.05;
      error = null;
    });

    try {
      final session = Session();
      final bytes = selectedBytes!;
      final sha = sha256FromBytes(bytes);
      final extension = _extensionOf(selectedFileName!);

      // 1. Request a signed URL. The filename in storage is derived from
      // the version the user typed (e.g. "v1.0.0.bin"), not from the
      // original file name — the backend builds and returns the path.
      final uploadInfo = await session.postObj(
        'devices/${widget.deviceId}/firmware/get-upload-url',
        {'version': version, 'extension': extension},
        context,
      );

      setState(() => progress = 0.25);

      // 2. Upload directly to Firebase Storage.
      final uploadResp = await http.put(
        Uri.parse(uploadInfo['uploadUrl']),
        headers: {'Content-Type': 'application/octet-stream'},
        body: bytes,
      );

      if (uploadResp.statusCode < 200 || uploadResp.statusCode >= 300) {
        throw Exception('Erro ao enviar firmware para o storage');
      }

      setState(() => progress = 0.6);

      // 3. Commit the upload in the backend.
      final commit = await session
          .postObj('devices/${widget.deviceId}/firmware/commit', {
            'path': uploadInfo['path'],
            'version': uploadInfo['version'],
            'sha256': sha,
            'size': bytes.length,
          }, context);

      // 4. Publish the MQTT command from the frontend.
      final payload = {
        'type': 'ota',
        'version': uploadInfo['version'],
        'url': commit['readUrl'],
        'sha256': sha,
        'size': bytes.length,
      };

      mqttManager.publish('device/${widget.deviceId}/ota', jsonEncode(payload));

      setState(() => progress = 0.9);

      // NEW: don't mark success yet — the OTA command was only sent, not
      // confirmed. Wait for the device to report the new fwVersion on its
      // status topic before declaring victory.
      _startOtaConfirmation(uploadInfo['version'] as String);
    } catch (e) {
      setState(() {
        uploading = false;
        progress = 0.0;
        error = e.toString().replaceAll('Exception:', '').trim();
      });
    }
  }

  // NEW: subscribes to the device's status topic and waits for it to
  // report back online with the version we just sent. The MQTT publish
  // itself already finished — `uploading` goes back to false here so the
  // buttons unlock, while _awaitingOtaConfirmation drives a separate
  // "waiting for device" state in the UI.
  void _startOtaConfirmation(String version) {
    _pendingOtaVersion = version;
    _awaitingOtaConfirmation = true;

    mqttManager.subscribe('device/${widget.deviceId}/status', _onDeviceStatus);

    _otaConfirmTimer?.cancel();
    _otaConfirmTimer = Timer(_otaConfirmTimeout, () {
      if (!_awaitingOtaConfirmation || !mounted) return;
      _finishOtaConfirmation(success: false, timedOut: true);
    });

    setState(() => uploading = false);
  }

  // NEW: handles every message on the status topic while a confirmation
  // is pending. Ignores anything that isn't the online status we're
  // waiting for (malformed payload, or a status for a different version
  // published before the reboot completes).
  void _onDeviceStatus(String payload) {
    if (!_awaitingOtaConfirmation) return;

    try {
      final json = jsonDecode(payload);
      if (json['online'] == true && json['fwVersion'] == _pendingOtaVersion) {
        _finishOtaConfirmation(success: true);
      }
    } catch (_) {
      // Malformed status payload — ignore and keep waiting, the timeout
      // will eventually fire if nothing valid ever arrives.
    }
  }

  // NEW: single exit point for the confirmation flow, whether it resolved
  // by matching the reported version or by timing out.
  void _finishOtaConfirmation({required bool success, bool timedOut = false}) {
    _awaitingOtaConfirmation = false;
    _otaConfirmTimer?.cancel();
    mqttManager.unsubscribe('device/${widget.deviceId}/status');

    if (!mounted) return;

    setState(() {
      progress = success ? 1.0 : 0.0;
      if (success) {
        _latestVersion =
            _pendingOtaVersion; // reflects right away, no refetch needed
      } else {
        error = timedOut
            ? 'Não foi possível confirmar a atualização a tempo. O dispositivo '
                  'pode ainda estar reiniciando ou ter falhado ao aplicar o firmware.'
            : 'Falha ao confirmar a atualização do firmware.';
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _otaConfirmTimer?.cancel();
    if (_awaitingOtaConfirmation) {
      mqttManager.unsubscribe('device/${widget.deviceId}/status');
    }
    _versionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 420,
          maxWidth: 420, // fixed width
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon
              const Icon(
                Icons.system_update_alt,
                size: 48,
                color: Colors.greenAccent,
              ),

              const SizedBox(height: 12),

              const Text(
                'Atualização de Firmware',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 8),

              const Text(
                'Selecione ou arraste um arquivo de firmware para atualizar o dispositivo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white70),
              ),

              const SizedBox(height: 12),

              // Informs the user the update doesn't depend on the device
              // being online right now — it will be picked up either live
              // via MQTT (if connected) or on its next boot/reconnect.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Colors.lightBlueAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Se o dispositivo estiver desconectado, o firmware será '
                        'aplicado automaticamente assim que ele se conectar '
                        '(seja agora ou na próxima vez que for ligado).',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.lightBlueAccent.withOpacity(0.9),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Version field
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _checkingLatest
                      ? 'Verificando versão atual...'
                      : _latestVersion != null
                      ? 'Versão atual do dispositivo: v$_latestVersion'
                      : 'Nenhum firmware enviado ainda para este device',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _versionCtrl,
                enabled: !uploading,
                onChanged: (_) {
                  if (versionError != null) {
                    setState(() => versionError = null);
                  }
                },
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Versão do firmware (ex: 1.0.0)',
                  labelStyle: const TextStyle(color: Colors.white54),
                  prefixText: 'v',
                  prefixStyle: const TextStyle(color: Colors.white70),
                  errorText: versionError,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),

              const SizedBox(height: 16),

              // File picker + drag & drop
              DropTarget(
                onDragDone: _onDragDone,
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                child: InkWell(
                  onTap: uploading ? null : _pickFile,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _dragging
                            ? Colors.greenAccent
                            : Colors.greenAccent.withOpacity(0.6),
                        width: _dragging ? 2 : 1,
                      ),
                      color: _dragging
                          ? Colors.greenAccent.withOpacity(0.12)
                          : Colors.white10,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.upload_file,
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            selectedFileName ??
                                'Arraste o arquivo aqui ou clique para selecionar (.bin, .hex, .uf2)',
                            style: const TextStyle(color: Colors.white70),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],

              const SizedBox(height: 20),

              // Progress bar
              // NEW: shows an indeterminate bar (value: null) while waiting
              // for the device's OTA confirmation, since there's no real
              // percentage to report for "device is rebooting somewhere".
              LinearProgressIndicator(
                value: uploading
                    ? progress
                    : _awaitingOtaConfirmation
                    ? null
                    : 0.0,
                minHeight: 10,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Colors.greenAccent,
                ),
                borderRadius: BorderRadius.circular(8),
              ),

              const SizedBox(height: 12),

              // NEW: distinguishes "uploading", "waiting for the device to
              // confirm it applied the update", and "confirmed" instead of
              // treating publish() as the finish line.
              Text(
                uploading
                    ? 'Enviando... ${(progress * 100).toStringAsFixed(0)}%'
                    : _awaitingOtaConfirmation
                    ? 'Firmware enviado, aguardando o dispositivo confirmar...'
                    : progress >= 1.0
                    ? 'Atualização confirmada com sucesso'
                    : 'Aguardando envio',
                style: const TextStyle(color: Colors.white70),
              ),

              const SizedBox(height: 24),

              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: uploading ? null : () => Navigator.pop(context),
                    child: const Text(
                      'Fechar',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: uploading ? null : _startUpload,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Iniciar upload'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
