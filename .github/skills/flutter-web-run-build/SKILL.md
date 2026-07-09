---
name: flutter-web-run-build
description: "Run, analyze, build, and deploy the Fluxio Flutter web dashboard. Use when: installing Flutter packages, launching Chrome, building web assets, deploying Firebase Hosting, or configuring local Dart defines."
argument-hint: "Optional: 'run', 'build', 'deploy', 'analyze', or 'clean'"
---

# Flutter Web Run and Build

## When to Use

- Fetch Flutter dependencies
- Run the dashboard in Chrome
- Analyze Dart code
- Build production web assets
- Deploy Firebase Hosting
- Configure local API key defines

## Commands

```bash
# Install dependencies
flutter pub get

# Analyze
flutter analyze

# Run in Chrome
flutter run -d chrome --dart-define-from-file=.env.json

# Build production web assets
flutter build web --dart-define-from-file=.env.json

# Deploy Firebase Hosting
firebase deploy --only hosting

# Clean build outputs
flutter clean
```

## Configuration

```bash
cp .env.json.example .env.json
```

Set `FLUXIO_API_KEY` to the same key configured as `PUBLIC_API_KEY` in the backend.

## Web Notes

- Browser MQTT uses WebSockets: `wss://<host>/mqtt`.
- Prefer broker port `8884` when returned by the backend.
- Production output is written to `build/web`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Backend returns forbidden | API key mismatch | Update `.env.json` and backend `PUBLIC_API_KEY` |
| MQTT fails in browser | Wrong WebSocket URL or port | Confirm `wss://<host>/mqtt` and port `8884` |
| Chrome run fails after dependency changes | Stale build cache | Run `flutter clean` then `flutter pub get` |
| Hosting deploy has old UI | `build/web` was not rebuilt | Run `flutter build web --dart-define-from-file=.env.json` before deploy |
| Assets missing | Asset path missing from `pubspec.yaml` | Keep `assets/images/` registered |

## Safety Rules

- Do not commit `.env.json`.
- Do not put privileged secrets in a web build.
- Do not change MQTT topic names without updating backend, mobile, and ESP32 consumers.
