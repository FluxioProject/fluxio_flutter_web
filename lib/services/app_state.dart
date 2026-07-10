import 'package:flutter/material.dart';
import 'package:tcc_flutter/backend_api/api_communication.dart';
import 'package:tcc_flutter/models/device.dart';
import 'package:tcc_flutter/models/user.dart';
import 'package:tcc_flutter/services/mqtt_manager.dart';

final AppState appState = AppState();

class AppState extends ChangeNotifier {
  Usuario? current;
  final Session _session = Session();
  bool get loggedIn => current != null;
  bool _syncing = false;
  bool get isSyncing => _syncing;
  List<Device> devices = [];
  Map<String, dynamic>? mqtt;

  // Checks with the backend whether an existing session can skip the login page.
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
        current = null;
        devices = [];
      }
    } catch (e) {
      current = null;
      devices = [];
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // User login.
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
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // Logs out this user session without disconnecting other devices.
  Future<void> logout() async {
    if (_syncing) return;

    try {
      await _session.post('users/logout', {});
    } catch (e) {}

    if (mqttManager.isConnected()) {
      mqttManager.disconnect();
    }

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

  // Loads all devices.
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

  // Refreshes the device list (and MQTT credentials) from the backend,
  // without touching the current login session. Used by the manual
  // refresh button on the devices screen.
  //
  // NOTE: this reuses 'users/persist' since that is the only endpoint we've
  // seen that returns the full device list + mqtt config together. If your
  // backend has a dedicated endpoint (e.g. 'devices/get-all'), swap the
  // call below to that instead — this works either way as long as the
  // response shape has a 'devices' list and optionally an 'mqtt' object.
  Future<void> getDevices(BuildContext context) async {
    final obj = await _session.getObj('users/persist', context);

    final list = obj['devices'] as List? ?? [];
    devices = list.map((e) => Device.fromBackend(e)).toList();

    if (obj['mqtt'] is Map<String, dynamic>) {
      mqtt = obj['mqtt'];
    }

    notifyListeners();
  }

  // Updates device status (online/ip) from an MQTT message.
  void updateDeviceStatus({
    required String deviceId,
    bool? isConnected,
    String? ipAddress,
  }) {
    final idx = devices.indexWhere((d) => d.deviceId == deviceId);
    if (idx == -1) return;

    devices[idx] = devices[idx].copyWith(
      isConnected: isConnected,
      ipAddress: ipAddress,
    );
    notifyListeners();
  }

  // Deletes a device.
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

  // Updates device data.
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