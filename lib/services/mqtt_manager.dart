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

  void _setupOnDisconnectedHandler() {
    client!.onDisconnected = () {
      _isConnected = false;
    };
  }

  void _setupOnConnectedHandler() {
    client!.onConnected = () {
      _isConnected = true;

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

  void disconnect() {
    _isConnected = false;
    _isConnecting = false;
    clearSubscriptions();
    client?.disconnect();
  }

  void setGlobalCallback(Function(String topic, String message) callback) {
    globalCallback = callback;
  }
}