# Fluxio Flutter Web - Agent Instructions

## Project Overview

Flutter web dashboard for the Fluxio IoT platform. It handles login, device management, live MQTT telemetry over WebSockets, manual commands, channel configuration, visual logic editing, firmware upload coordination, and Firebase Hosting deployment.

## Build & Test

```bash
flutter pub get
flutter analyze

# Run in Chrome
flutter run -d chrome --dart-define-from-file=.env.json

# Build production web assets
flutter build web --dart-define-from-file=.env.json

# Deploy hosting when configured
firebase deploy --only hosting
```

Create `.env.json` from `.env.json.example` before running. The file must define `FLUXIO_API_KEY`.

## Architecture

```
lib/main.dart                         - app bootstrap, theme, persisted login gate
lib/backend_api/api_communication.dart - HTTP client for Fluxio backend
lib/mqtt/mqtt_manager.dart            - WebSocket MQTT client for browser
lib/services/app_state.dart           - global session/device/MQTT state
lib/widgets/                          - shared UI widgets
lib/models/                           - user, device, telemetry, channel models
lib/pages/first_screens/              - login, registration, forgot password
lib/pages/main_screen/                - device list and account/device management
lib/pages/dashboard_screen/           - device details, commands, channels, firmware, logic builder
web/                                  - web shell, manifest, icons
assets/images/                        - logo and background images
firebase.json                         - Firebase Hosting configuration
production-deploy.yaml                - production deployment workflow/config
```

## Key Conventions

- Keep backend calls in `lib/backend_api/api_communication.dart`.
- Keep MQTT connection, subscriptions, publishing, and disconnect behavior in `lib/mqtt/mqtt_manager.dart`.
- Keep session-wide state in `appState`; avoid duplicating user/device/MQTT state in pages.
- Use `--dart-define-from-file=.env.json` for `FLUXIO_API_KEY`; never hardcode API keys in Dart.
- Web MQTT uses `MqttBrowserClient` with `wss://<host>/mqtt` and broker WebSocket port `8884` when available.
- Mobile MQTT differs from web; do not copy web MQTT code into the mobile project without adapting the client type and TLS port.
- Keep visual logic block models compatible with the ESP32 firmware logic JSON format.
- Production web output is generated in `build/web`.

## Security Notes

- Do not commit `.env.json`, API keys, cookies, auth tokens, or broker credentials.
- Remember that web builds expose client-side Dart defines to users; only use the shared public API gate key here, never privileged secrets.
- Rotate the shared API key if it is exposed outside the intended environment.

## Do Not Change Without Understanding

- `main.dart` waits for `appState.tryPersistLogin(context)` before choosing `CardsPage` or `LoginPage`.
- `mqttManager` is a global singleton used by dashboard pages.
- Topic names and payloads must stay compatible with the ESP32 firmware MQTT contract.
- Firebase Hosting deploys the generated web build, not Dart source files.
