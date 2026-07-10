import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'dart:async';
import 'package:tcc_flutter/widgets/show_message.dart';

final mqttManager = MqttManager();

class MqttManager {
  Timer? keepAliveTimer;
  int timerCounter = 0;
  MqttBrowserClient? client;
  final Map<String, Function(String)> subscriptions = {};
  Function(String topic, String message)? globalCallback;
  String usermqtt = '';
  String passwordmqtt = '';
  static bool _isConnected = false;
  ValueNotifier<bool> isLoadingNotifier = ValueNotifier<bool>(true);

  // Exposed so the UI can show a "reconnecting..." state instead of treating
  // every drop as a hard failure.
  ValueNotifier<bool> isReconnectingNotifier = ValueNotifier<bool>(false);

  static bool _isConnecting = false;
  final clientId = 'flutter_web_${DateTime.now().millisecondsSinceEpoch}';

  bool isConnected() {
    if (client == null) return false;
    return client!.connectionStatus?.state == MqttConnectionState.connected;
  }

  Future<void> initializeMqtt(BuildContext context, isCon) async {
    // Already connected — skip re-creating the client entirely.
    if (isConnected()) {
      isLoadingNotifier.value = false;
      return;
    }

    isLoadingNotifier.value = true;

    if (isCon) {
      try {
        final mqtt = appState.mqtt;
        if (mqtt == null) {
          throw Exception('MQTT não disponível');
        }

        mqttManager.usermqtt = mqtt['user'];
        mqttManager.passwordmqtt = mqtt['pass'];

        final List ports = mqtt['ports'];
        final int port = int.parse(
          ports.contains('8884') ? '8884' : ports.first.toString(),
        );

        final String url = 'wss://${mqtt['host']}/mqtt';

        mqttManager.client = MqttBrowserClient.withPort(
          url,
          mqttManager.clientId,
          port,
        );

        await mqttManager.connect(context);
      } catch (e) {
        if (context.mounted) {
          showMessage(context, 'internalerror', true);
        }
      }
    }

    if (context.mounted) {
      isLoadingNotifier.value = false;
    }
  }

  Future<bool> connect(BuildContext context) async {
    if (_isConnected || _isConnecting) return false;
    _isConnecting = true;

    try {
      client!.websocketProtocols = ['mqtt'];
      client!.keepAlivePeriod = 120;

      // Let the mqtt_client package handle reconnection at the socket level.
      // Without this, onDisconnected only flips a flag and nothing ever
      // tries to re-establish the connection until a screen is reopened.
      client!.autoReconnect = true;
      client!.resubscribeOnAutoReconnect = true;

      client!.onAutoReconnect = _onAutoReconnect;
      client!.onAutoReconnected = _onAutoReconnected;

      client!.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .authenticateAs(usermqtt, passwordmqtt)
          .startClean();

      await client!.connect();

      if (client!.connectionStatus?.state == MqttConnectionState.connected) {
        _setupOnDisconnectedHandler();
        _setupOnConnectedHandler();
        _listenToMessages(context);
        _isConnected = true;
        _isConnecting = false;
        return true;
      }

      _isConnecting = false;
      return false;
    } catch (e) {
      _isConnected = false;
      _isConnecting = false;
      client = null;
      return false;
    }
  }

  // Called by mqtt_client right before it attempts an automatic reconnect.
  void _onAutoReconnect() {
    isReconnectingNotifier.value = true;
  }

  // Called by mqtt_client after an automatic reconnect succeeds.
  // Subscriptions are restored automatically because
  // resubscribeOnAutoReconnect is set to true above.
  void _onAutoReconnected() {
    _isConnected = true;
    isReconnectingNotifier.value = false;
    debugPrint('[MQTT] Automatically reconnected');
  }

  void _setupOnDisconnectedHandler() {
    client!.onDisconnected = () {
      _isConnected = false;
      debugPrint('[MQTT] Disconnected, waiting for auto-reconnect...');
    };
  }

  void _setupOnConnectedHandler() {
    client!.onConnected = () {
      _isConnected = true;
      isReconnectingNotifier.value = false;

      try {
        for (final topic in subscriptions.keys) {
          client!.subscribe(topic, MqttQos.atLeastOnce);
        }
      } catch (_) {}
    };
  }

  bool getConnectionStatus() {
    return _isConnected;
  }

  void _listenToMessages(BuildContext context) async {
    client!.updates?.listen((
      List<MqttReceivedMessage<MqttMessage?>>? messages,
    ) {
      final MqttPublishMessage recMessage =
          messages![0].payload as MqttPublishMessage;
      final String topic = messages[0].topic;
      final String payload = MqttPublishPayload.bytesToStringAsString(
        recMessage.payload.message,
      );

      if (subscriptions.containsKey(topic)) {
        subscriptions[topic]!(payload);
      } else if (globalCallback != null) {
        globalCallback!(topic, payload);
      }
    });
  }

  void subscribe(String topic, Function(String) onMessage) {
    subscriptions[topic] = onMessage;

    if (!isConnected()) return;

    try {
      client!.subscribe(topic, MqttQos.atLeastOnce);
    } catch (_) {}
  }

  void unsubscribe(String topic) {
    subscriptions.remove(topic);

    if (!isConnected()) return;

    try {
      client!.unsubscribe(topic);
    } catch (_) {}
  }

  void publish(String topic, String message) {
    if (!isConnected()) {
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void clearSubscriptions() {
    final List<String> topics = subscriptions.keys.toList();

    try {
      for (final topic in topics) {
        client!.unsubscribe(topic);
      }
    } catch (e) {}

    subscriptions.clear();
  }

  // Explicit, user-initiated disconnect. This intentionally does NOT rely
  // on autoReconnect, since the caller wants the connection to actually
  // stay down (e.g. navigating away from the app / logging out).
  void disconnect() {
    _isConnected = false;
    _isConnecting = false;
    isReconnectingNotifier.value = false;
    clearSubscriptions();
    client?.disconnect();
  }

  void setGlobalCallback(Function(String topic, String message) callback) {
    globalCallback = callback;
  }
}