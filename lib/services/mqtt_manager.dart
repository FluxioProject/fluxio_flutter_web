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
    debugPrint('[MQTT] initializeMqtt called (isCon=$isCon)');

    // Already connected — skip re-creating the client entirely.
    if (isConnected()) {
      debugPrint('[MQTT] Already connected, skipping client re-creation');
      isLoadingNotifier.value = false;
      return;
    }

    isLoadingNotifier.value = true;
    debugPrint('[MQTT] isLoadingNotifier set to true');

    if (isCon) {
      try {
        final mqtt = appState.mqtt;
        if (mqtt == null) {
          debugPrint('[MQTT] ERROR: appState.mqtt is null, cannot initialize');
          throw Exception('MQTT não disponível');
        }

        mqttManager.usermqtt = mqtt['user'];
        mqttManager.passwordmqtt = mqtt['pass'];

        debugPrint(
          '[MQTT] Credentials loaded from appState (user=${mqttManager.usermqtt})',
        );

        final int port = 8884;

        final String url = 'wss://${mqtt['host']}/mqtt';

        debugPrint(
          '[MQTT] Building client for url=$url port=$port clientId=$clientId',
        );

        mqttManager.client = MqttBrowserClient.withPort(
          url,
          mqttManager.clientId,
          port,
        );

        debugPrint('[MQTT] Client instance created, calling connect()');

        await mqttManager.connect(context);
      } catch (e) {
        debugPrint('[MQTT] EXCEPTION during initializeMqtt: $e');
        if (context.mounted) {
          showMessage(context, 'internalerror', true);
        }
      }
    } else {
      debugPrint(
        '[MQTT] initializeMqtt called with isCon=false, skipping connect',
      );
    }

    if (context.mounted) {
      isLoadingNotifier.value = false;
      debugPrint('[MQTT] isLoadingNotifier set to false');
    }
  }

  Future<bool> connect(BuildContext context) async {
    debugPrint(
      '[MQTT] connect() called (isConnected=$_isConnected, isConnecting=$_isConnecting)',
    );

    if (_isConnected || _isConnecting) {
      debugPrint('[MQTT] connect() aborted: already connected or connecting');
      return false;
    }
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

      debugPrint(
        '[MQTT] Connection message built, calling client.connect()...',
      );

      await client!.connect();

      debugPrint(
        '[MQTT] client.connect() returned, state=${client!.connectionStatus?.state}',
      );

      if (client!.connectionStatus?.state == MqttConnectionState.connected) {
        debugPrint(
          '[MQTT] Connection SUCCESSFUL, setting up handlers and listeners',
        );
        _setupOnDisconnectedHandler();
        _setupOnConnectedHandler();
        _listenToMessages(context);
        _isConnected = true;
        _isConnecting = false;
        return true;
      }

      debugPrint(
        '[MQTT] Connection FAILED, final state=${client!.connectionStatus?.state}',
      );
      _isConnecting = false;
      return false;
    } catch (e) {
      debugPrint('[MQTT] EXCEPTION during connect(): $e');
      _isConnected = false;
      _isConnecting = false;
      client = null;
      return false;
    }
  }

  // Called by mqtt_client right before it attempts an automatic reconnect.
  void _onAutoReconnect() {
    debugPrint('[MQTT] onAutoReconnect fired — attempting to reconnect...');
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
    debugPrint('[MQTT] onDisconnected handler registered');
  }

  void _setupOnConnectedHandler() {
    client!.onConnected = () {
      _isConnected = true;
      isReconnectingNotifier.value = false;

      debugPrint(
        '[MQTT] onConnected fired, resubscribing to ${subscriptions.length} topic(s)',
      );

      try {
        for (final topic in subscriptions.keys) {
          debugPrint('[MQTT] Resubscribing to $topic');
          client!.subscribe(topic, MqttQos.atLeastOnce);
        }
      } catch (e) {
        debugPrint('[MQTT] EXCEPTION while resubscribing: $e');
      }
    };
    debugPrint('[MQTT] onConnected handler registered');
  }

  bool getConnectionStatus() {
    return _isConnected;
  }

  void _listenToMessages(BuildContext context) async {
    debugPrint('[MQTT] Starting to listen for incoming messages');

    client!.updates?.listen((
      List<MqttReceivedMessage<MqttMessage?>>? messages,
    ) {
      final MqttPublishMessage recMessage =
          messages![0].payload as MqttPublishMessage;
      final String topic = messages[0].topic;
      final String payload = MqttPublishPayload.bytesToStringAsString(
        recMessage.payload.message,
      );

      debugPrint('[MQTT ⬇ RX] $topic: $payload');

      if (subscriptions.containsKey(topic)) {
        debugPrint('[MQTT] Dispatching to topic-specific handler for $topic');
        subscriptions[topic]!(payload);
      } else if (globalCallback != null) {
        debugPrint(
          '[MQTT] No topic-specific handler for $topic, dispatching to globalCallback',
        );
        globalCallback!(topic, payload);
      } else {
        debugPrint(
          '[MQTT] WARNING: no handler registered for $topic, message dropped',
        );
      }
    });
  }

  void subscribe(String topic, Function(String) onMessage) {
    debugPrint('[MQTT] subscribe() called for $topic');
    subscriptions[topic] = onMessage;

    if (!isConnected()) {
      debugPrint(
        '[MQTT] Not connected yet, subscription for $topic saved for later',
      );
      return;
    }

    try {
      client!.subscribe(topic, MqttQos.atLeastOnce);
      debugPrint('[MQTT] Subscribed to $topic');
    } catch (e) {
      debugPrint('[MQTT] EXCEPTION while subscribing to $topic: $e');
    }
  }

  void unsubscribe(String topic) {
    debugPrint('[MQTT] unsubscribe() called for $topic');
    subscriptions.remove(topic);

    if (!isConnected()) {
      debugPrint(
        '[MQTT] Not connected, skipping broker unsubscribe for $topic',
      );
      return;
    }

    try {
      client!.unsubscribe(topic);
      debugPrint('[MQTT] Unsubscribed from $topic');
    } catch (e) {
      debugPrint('[MQTT] EXCEPTION while unsubscribing from $topic: $e');
    }
  }

  void publish(String topic, String message, {bool retain = false}) {
    if (!isConnected()) {
      debugPrint('[MQTT ⬆ TX] SKIPPED (not connected) $topic: $message');
      return;
    }

    // Log everything sent — visible in the browser console (F12).
    debugPrint('[MQTT ⬆ TX] $topic: $message');

    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client!.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: retain,
    );
    debugPrint('[MQTT] publishMessage() call completed for $topic');
  }

  void clearSubscriptions() {
    final List<String> topics = subscriptions.keys.toList();
    debugPrint(
      '[MQTT] clearSubscriptions() called for ${topics.length} topic(s): $topics',
    );

    try {
      for (final topic in topics) {
        client!.unsubscribe(topic);
        debugPrint('[MQTT] Unsubscribed from $topic (clearSubscriptions)');
      }
    } catch (e) {
      debugPrint('[MQTT] EXCEPTION during clearSubscriptions: $e');
    }

    subscriptions.clear();
    debugPrint('[MQTT] subscriptions map cleared');
  }

  // Explicit, user-initiated disconnect. This intentionally does NOT rely
  // on autoReconnect, since the caller wants the connection to actually
  // stay down (e.g. navigating away from the app / logging out).
  void disconnect() {
    debugPrint('[MQTT] disconnect() called (explicit, user-initiated)');
    _isConnected = false;
    _isConnecting = false;
    isReconnectingNotifier.value = false;
    clearSubscriptions();
    client?.disconnect();
    debugPrint('[MQTT] client.disconnect() completed');
  }

  void setGlobalCallback(Function(String topic, String message) callback) {
    debugPrint('[MQTT] setGlobalCallback() registered');
    globalCallback = callback;
  }
}
