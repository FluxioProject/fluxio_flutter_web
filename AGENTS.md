# Repository Guidelines

## Project Overview

This is a Flutter Web dashboard for the Fluxio/TCC 2026 platform. It talks to a
Cloud Functions backend, uses browser cookies for authenticated requests, and
uses MQTT over WebSockets for live device status and telemetry.

## Development Commands

- `flutter pub get`: install dependencies.
- `flutter run -d chrome --dart-define-from-file=config.local.json`: run locally.
- `flutter analyze`: run static analysis.
- `flutter test`: run the test suite.
- `flutter build web --dart-define-from-file=config.local.json`: create a web build.

## Configuration

Runtime values are read through Dart compile-time environment defines in
`lib/config/app_config.dart`.

Never commit real API keys. Use `config.local.json` locally and keep it ignored
by git. `config.example.json` documents the required keys without storing
secrets.

## Code Style

- Keep code, comments, and documentation in English.
- Follow existing Flutter structure and naming conventions.
- Keep widgets small when a screen becomes difficult to scan.
- Prefer explicit model parsing over loosely typed maps when adding new data.
- Avoid unrelated formatting churn in files that are not part of the task.

## Safety Notes

Manual commands, firmware uploads, and logic editor changes may affect physical
equipment. Preserve confirmation dialogs and defensive validation around these
flows.
