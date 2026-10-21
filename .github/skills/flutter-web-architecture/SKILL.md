---
name: flutter-web-architecture
description: "Explains the Fluxio Flutter web architecture, app state, backend API client, browser MQTT flow, dashboard pages, Firebase Hosting, and logic builder. Use when: tracing web behavior, adding screens, debugging MQTT WebSockets, or changing client contracts."
---

# Flutter Web Architecture

## Module Map

| Area | File(s) | Responsibility |
|---|---|---|
| App bootstrap | `lib/main.dart` | Theme, persisted login check, initial route |
| Backend API | `lib/backend_api/api_communication.dart` | HTTP calls to Fluxio backend |
| App state | `lib/services/app_state.dart` | Logged-in user, selected devices, MQTT credentials/state |
| MQTT | `lib/mqtt/mqtt_manager.dart` | Browser MQTT connect, subscribe, publish, reconnect state |
| Models | `lib/models/` | User, device, telemetry, channel config models |
| Auth pages | `lib/pages/first_screens/` | Login, registration, password recovery |
| Main pages | `lib/pages/main_screen/` | Device list and user/device management |
| Dashboard | `lib/pages/dashboard_screen/` | Details, command page, channel editor, firmware upload, logic builder |
| Web shell | `web/` | HTML shell, manifest, icons |
| Hosting | `firebase.json` | Firebase Hosting configuration |

## Startup Flow

```
main()
  -> MyApp
  -> _init()
  -> appState.tryPersistLogin(context)
  -> logged in: CardsPage
  -> not logged in: LoginPage
```

## Device Data Flow

```
User action or dashboard load
  -> appState / page controller
  -> api_communication.dart
  -> Fluxio backend
  -> appState updated
  -> pages rebuild from current state
```

## MQTT Flow

```
Selected device
  -> backend returns MQTT credentials
  -> appState.mqtt stores credentials
  -> mqttManager.initializeMqtt()
  -> MqttBrowserClient.withPort(wss://host/mqtt, clientId, 8884)
  -> subscribe to telemetry/control topics
  -> dashboard callbacks update UI
  -> publish commands and logic payloads
```

## Firmware Upload Flow

```
Dashboard firmware page
  -> request signed upload URL from backend
  -> upload binary to storage URL
  -> commit firmware metadata through backend
  -> device OTA path can consume committed metadata
```

## Adding a Screen or Workflow

1. Add or update models in `lib/models/` if the backend contract changes.
2. Add backend calls in `lib/backend_api/api_communication.dart`.
3. Store shared session/device state in `appState`.
4. Add the page under the matching `lib/pages/` area.
5. Wire MQTT subscriptions through `mqttManager` when live telemetry is needed.
6. Run `flutter analyze`.

## Do Not Change Without Understanding

- `mqttManager` is shared global state; always unsubscribe or clear subscriptions when leaving device contexts.
- Web MQTT uses `MqttBrowserClient`; mobile uses `MqttServerClient`.
- Logic builder payloads must remain compatible with ESP32 block execution.
- Web builds expose client-side configuration, so never include privileged secrets.
