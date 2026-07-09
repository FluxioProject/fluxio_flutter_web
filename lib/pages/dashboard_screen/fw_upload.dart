import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
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

  PlatformFile? selectedFile;
  String? error;

  // Basic firmware validation.
  bool _isValidFirmware(PlatformFile file) {
    final name = file.name.toLowerCase();
    return name.endsWith('.bin') ||
        name.endsWith('.hex') ||
        name.endsWith('.uf2');
  }

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

  Future<void> _pickFile() async {
    setState(() => error = null);

    // Immediate FilePicker call triggered by the user event.
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['bin', 'hex', 'uf2'],
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    if (!_isValidFirmware(file)) {
      setState(() {
        error = 'Arquivo inválido. Selecione um firmware válido.';
        selectedFile = null;
      });
      return;
    }

    // Agora sim pode mostrar dialog
    final accepted = await _showWarningDialog(context);
    if (!accepted) {
      setState(() => selectedFile = null);
      return;
    }

    setState(() {
      selectedFile = file;
    });
  }

  Future<void> _startUpload() async {
    if (selectedFile == null || selectedFile!.bytes == null) {
      setState(() {
        error = 'Selecione um arquivo de firmware antes de enviar';
      });
      return;
    }

    setState(() {
      uploading = true;
      progress = 0.05;
      error = null;
    });

    try {
      final session = Session();
      final bytes = selectedFile!.bytes!;
      final sha = sha256FromBytes(bytes);

      // 1. Request a signed URL.
      final uploadInfo = await session.postObj(
        'devices/${widget.deviceId}/firmware/get-upload-url',
        {},
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

      setState(() {
        progress = 1.0;
        uploading = false;
      });
    } catch (e) {
      setState(() {
        uploading = false;
        progress = 0.0;
        error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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
                'Selecione um arquivo de firmware para atualizar o dispositivo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white70),
              ),

              const SizedBox(height: 20),

              // File picker
              InkWell(
                onTap: uploading ? null : _pickFile,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.6),
                    ),
                    color: Colors.white10,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.upload_file, color: Colors.greenAccent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          selectedFile?.name ??
                              'Selecionar arquivo (.bin, .hex, .uf2)',
                          style: const TextStyle(color: Colors.white70),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
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
              LinearProgressIndicator(
                value: uploading ? progress : 0.0,
                minHeight: 10,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Colors.greenAccent,
                ),
                borderRadius: BorderRadius.circular(8),
              ),

              const SizedBox(height: 12),

              Text(
                uploading
                    ? 'Enviando... ${(progress * 100).toStringAsFixed(0)}%'
                    : progress >= 1.0
                    ? 'Upload concluído com sucesso'
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
