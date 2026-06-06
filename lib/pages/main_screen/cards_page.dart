import 'package:flutter/material.dart';
import 'package:tcc_flutter/pages/main_screen/manage_devices/add_device.dart';
import 'package:tcc_flutter/pages/first_screens/login.dart';
import 'package:tcc_flutter/pages/main_screen/manage_user/edit_account.dart';
import 'package:tcc_flutter/pages/main_screen/widgets/device_card.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class CardsPage extends StatefulWidget {
  const CardsPage({super.key});

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  List<Device> get filteredDevices {
    final devices = appState.devices;

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return devices;

    return devices.where((d) {
      return d.name.toLowerCase().contains(q) ||
          d.deviceId.toLowerCase().contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    appState.addListener(_onUserUpdated);
  }

  void _onUserUpdated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    appState.removeListener(_onUserUpdated);
    super.dispose();
  }

  Future<void> _editDeviceName(BuildContext context, Device device) async {
    final nameCtrl = TextEditingController(text: device.name);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar dispositivo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtrl,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(ctx, true),
              decoration: const InputDecoration(
                label: Text('Nome do dispositivo'),
                hintText: 'Digite o novo nome',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'ID: ${device.deviceId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 63, 146, 66),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salvar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    final newName = nameCtrl.text.trim();
    if (confirm != true || newName.isEmpty || newName == device.name) return;

    try {
      await appState.updateDeviceName(
        deviceId: device.deviceId,
        newName: newName,
        context: context,
      );

      showMessage(context, 'Nome do dispositivo atualizado', false);
      // NÃO precisa setState: o AppState dá notifyListeners()
    } catch (e) {
      showMessage(
        context,
        e.toString().replaceAll('Exception:', '').trim(),
        true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = appState.current;

    return Scaffold(
      appBar: AppBar(
        actionsPadding: EdgeInsets.only(right: 8),
        backgroundColor: Color(0xFF1E1E1E),
        title: Row(
          children: [
            SizedBox(width: 8),
            const Text('Dispositivos'),
            Spacer(),
            SizedBox(
              height: 40,
              width: 350,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Pesquisar por nome ou ID...',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Limpar',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            Spacer(),
          ],
        ),
        actions: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withOpacity(0.18),
                width: 1,
              ),
              color: Colors.white.withOpacity(0.04), // opcional (bem leve)
            ),
            child: TextButton.icon(
              onPressed: () async {
                final currentUser = appState.current;
                if (currentUser == null) return;

                final newName = await showDialog<String>(
                  context: context,
                  builder: (_) => EditUserDialog(usuario: currentUser),
                );

                if (newName != null && newName != currentUser.nome) {
                  await appState.updateName(newName, context);

                  showMessage(context, 'Nome atualizado com sucesso', false);

                  // força rebuild REAL
                  if (mounted) setState(() {});
                }
              },

              icon: const Icon(Icons.person_outline, size: 22),
              label: Text(
                (user?.nome.trim().isNotEmpty ?? false)
                    ? user!.nome.trim()
                    : 'Conta',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                minimumSize: const Size(0, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
          SizedBox(width: 5),
          // IconButton(
          //   tooltip: 'Configurações',
          //   icon: const Icon(Icons.settings_outlined),
          //   onPressed: () {
          //     // TODO: abrir tela de configurações
          //   },
          // ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () {
              appState.logout();

              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (_) => false,
              );
            },
          ),
        ],
      ),
      body: GradientBackground(
        image: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: GridView.builder(
            itemCount: filteredDevices.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 4.5,
            ),
            itemBuilder: (context, index) {
              final dev = filteredDevices[index];
              return DeviceCard(
                device: dev,
                onDelete: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Excluir dispositivo?'),
                      content: Text(
                        'Tem certeza que deseja excluir "${dev.name}"?\n\n'
                        'ID: ${dev.deviceId}',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancelar'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              180,
                              49,
                              39,
                            ),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text(
                            'Excluir',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    try {
                      await appState.deleteDevice(
                        deviceId: dev.deviceId,
                        context: context,
                      );

                      showMessage(context, 'Dispositivo removido', false);
                    } catch (e) {
                      showMessage(
                        context,
                        e.toString().replaceAll('Exception:', '').trim(),
                        true,
                      );
                    }
                  }
                },
                onEdit: () => _editDeviceName(context, dev),
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.greenAccent,
        foregroundColor: Colors.black,
        shape: const CircleBorder(),
        onPressed: () async {
          final result = await showDialog<Map<String, String>>(
            context: context,
            builder: (_) => const AddDeviceDialog(),
          );

          if (result == null) return;

          try {
            await appState.createDevice(
              name: result['name']!,
              deviceId: result['deviceId']!,
              context: context,
            );

            showMessage(context, 'Dispositivo adicionado com sucesso', false);
          } catch (e) {
            showMessage(
              context,
              e.toString().replaceAll('Exception:', '').trim(),
              true,
            );
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
