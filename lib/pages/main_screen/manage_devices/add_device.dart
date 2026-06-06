import 'package:flutter/material.dart';

class AddDeviceDialog extends StatefulWidget {
  const AddDeviceDialog({super.key});

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  final _formKey = GlobalKey<FormState>();

  final nameCtrl = TextEditingController();
  final idCtrl = TextEditingController();

  @override
  void dispose() {
    nameCtrl.dispose();
    idCtrl.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(labelText: label, isDense: true);
  }

  String? _requiredValidator(String? v) {
    if (v == null || v.trim().isEmpty) {
      return 'Campo obrigatório';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adicionar dispositivo'),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                decoration: _decoration('Nome'),
                validator: _requiredValidator,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: idCtrl,
                decoration: _decoration('Device ID'),
                validator: _requiredValidator,
                textInputAction: TextInputAction.next,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Adicionar', style: TextStyle(color: Colors.white)),
          style: FilledButton.styleFrom(
            backgroundColor: const Color.fromARGB(255, 63, 146, 66),
          ),
        ),
      ],
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(context, {
      'name': nameCtrl.text.trim(),
      'deviceId': idCtrl.text.trim(),
    });
  }
}
