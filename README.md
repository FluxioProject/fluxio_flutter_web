# Fluxio Flutter Web

Web dashboard for the Fluxio IoT platform. The app lets users manage devices, monitor telemetry, edit channel configuration, send MQTT commands, build visual logic programs, and coordinate firmware updates.

## Features

- Email/password login backed by the Fluxio Firebase API
- Device list with add, edit, and delete workflows
- Live MQTT telemetry over WebSockets
- Analog and digital channel views with configurable ranges and labels
- Manual output commands for AO and DO channels
- Visual logic builder for device-side automation blocks
- Firmware upload flow with backend-signed storage URLs

## Requirements

- Flutter SDK 3.8.1 or newer
- A running Fluxio backend
- A shared Fluxio API key configured in the backend as `PUBLIC_API_KEY`

## Configuration

The app reads the API key from a Dart define named `FLUXIO_API_KEY`.

Create a local define file from the example:

```bash
cp .env.json.example .env.json
```

Edit `.env.json` with the same key configured in the backend. This file is ignored by Git.

## Development

```bash
flutter pub get
flutter run -d chrome --dart-define-from-file=.env.json
```

## Build

```bash
flutter build web --dart-define-from-file=.env.json
```

The production build is generated in `build/web`.

## Project Structure

- `lib/backend_api/` - HTTP session client for the Fluxio API
- `lib/mqtt/` - MQTT WebSocket connection manager
- `lib/pages/first_screens/` - login, registration, and account recovery screens
- `lib/pages/main_screen/` - device list and account/device management
- `lib/pages/dashboard_screen/` - telemetry, command, channel, firmware, and logic views
- `lib/models/` - device, telemetry, user, and channel models
- `assets/images/` - application images

## Security Notes

Do not hardcode API keys in Dart files. Keep local define files such as `.env.json` out of source control and rotate the shared key if it is exposed.
