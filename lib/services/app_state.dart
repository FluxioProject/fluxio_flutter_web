import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/user.dart';

final AppState appState = AppState();

class AppState extends ChangeNotifier {
  Usuario? current;
  final Session _session = Session();
  bool get loggedIn => current != null;
  bool _syncing = false;
  bool get isSyncing => _syncing;
  List<Device> devices = [];
  Map<String, dynamic>? mqtt;

  // Verifica com backend se já possui autenticação para pular tela de login
  Future<void> tryPersistLogin(BuildContext context) async {
    if (_syncing) return;

    _syncing = true;
    notifyListeners();

    try {
      final obj = await _session.getObj('users/persist', context);

      if (obj['user'] is Map<String, dynamic>) {
        current = Usuario.fromBackend(obj['user']);

        final list = obj['devices'] as List? ?? [];
        devices = list.map((e) => Device.fromBackend(e)).toList();

        if (obj['mqtt'] is Map<String, dynamic>) {
          mqtt = obj['mqtt'];
        }
      } else {
        // persist válido, mas sem usuário
        current = null;
        devices = [];
      }
    } catch (e) {
      // erro → estado conhecido
      current = null;
      devices = [];
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // Login do usuário
  Future<void> login(
    String email,
    String password,
    BuildContext context,
  ) async {
    if (_syncing) return;

    _syncing = true;
    notifyListeners();

    try {
      final obj = await _session.postObj('users/login', {
        'email': email,
        'password': password,
      }, context);

      if (obj['user'] is! Map<String, dynamic>) {
        throw Exception('Resposta inválida do servidor');
      }

      current = Usuario.fromBackend(obj['user']);

      final list = obj['devices'] as List? ?? [];
      devices = list.map((e) => Device.fromBackend(e)).toList();

      if (obj['mqtt'] is Map<String, dynamic>) {
        mqtt = obj['mqtt'];
      }
    } catch (e) {
      print(e);
    }
    finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // Logout do usuário sem desconectar em outros dispositivos
  Future<void> logout() async {
    if (_syncing) return;

    try {
      await _session.post('users/logout', {});
    } catch (e) {}
    current = null;
    notifyListeners();
  }

  Future<void> register(
    String name,
    String email,
    String password,
    BuildContext context,
  ) async {
    if (_syncing) return;

    _syncing = true;
    notifyListeners();

    try {
      await _session.post('users/register', {
        'name': name,
        'email': email,
        'password': password,
      });
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // Carrega todos os produtos
  Future<void> loadProducts(BuildContext context) async {
    final obj = await _session.getObj('products/get-all-products', context);

    if (obj is Map<String, dynamic> && obj['products'] is List) {
      // final list = (obj['products'] as List).cast<Map<String, dynamic>>();
    } else {
      throw Exception('Erro interno.');
    }
  }

  Future<Device> createDevice({
    required String name,
    required String deviceId,
    required BuildContext context,
  }) async {
    if (_syncing) {
      throw Exception('Sincronização em andamento');
    }

    _syncing = true;
    notifyListeners();

    try {
      await _session.post('devices/create', {
        'name': name,
        'deviceId': deviceId,
      });

      final device = Device(name: name, deviceId: deviceId);
      devices.add(device);
      return device;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> deleteDevice({
    required String deviceId,
    required BuildContext context,
  }) async {
    if (_syncing) throw Exception('Sincronização em andamento');

    _syncing = true;
    notifyListeners();

    try {
      await _session.delete('devices/delete-device/$deviceId');

      // remove localmente
      devices.removeWhere((d) => d.deviceId == deviceId);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> updateDeviceName({
    required String deviceId,
    required String newName,
    required BuildContext context,
  }) async {
    if (_syncing) throw Exception('Sincronização em andamento');

    _syncing = true;
    notifyListeners();

    try {
      await _session.patch('devices/edit-device/$deviceId', {'name': newName});

      // atualiza lista local
      final idx = devices.indexWhere((d) => d.deviceId == deviceId);
      if (idx != -1) {
        devices[idx] = devices[idx].copyWith(name: newName);
      }

      notifyListeners();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // Deleta um produto
  Future<void> deleteProduct({
    required String productId,
    required BuildContext context,
  }) async {
    if (_syncing) throw Exception("Sincronização em andamento");

    try {
      await _session.delete('products/delete-product/$productId');
    } catch (e) {
      rethrow;
    }
  }

  // Atualiza os dados de um produto
  Future<void> updateProduct({
    required String productId,
    String? name,
    bool? ativo,
    required BuildContext context,
  }) async {
    if (_syncing) throw Exception("Sincronização em andamento");

    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (ativo != null) body['ativo'] = ativo;

    if (body.isEmpty) return;

    await _session.patch('products/edit-product/$productId', body);
  }

  Future<void> deleteAccount(BuildContext context) async {
    if (_syncing) return;

    _syncing = true;
    notifyListeners();

    try {
      await _session.delete('users/delete_own_account');

      // limpa estado local
      current = null;
      notifyListeners();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> updateName(String newName, BuildContext context) async {
    final obj = await _session.patchObj('users/edit', {
      'name': newName,
    }, context);

    if (obj['user'] is Map<String, dynamic>) {
      current = current!.copyWith(nome: obj['user']['name']);
      notifyListeners();
    } else {
      throw Exception('Erro ao atualizar nome');
    }
  }
}
