# Fluxio Flutter Web

Flutter Web dashboard for the Fluxio/TCC 2026 platform. The app manages users,
devices, MQTT connectivity, telemetry visualization, channel configuration,
visual logic editing, and firmware upload flows.

## Requirements

- Flutter SDK compatible with Dart `^3.8.1`
- Chrome or another Flutter Web supported browser
- Access to the backend API and MQTT credentials returned by the backend

## Configuration

The API key must not be committed to the repository. Create a local config file:

```powershell
Copy-Item config.example.json config.local.json
```

Then edit `config.local.json` and set `FLUXIO_API_KEY`.

Run the app with:

```powershell
flutter run -d chrome --dart-define-from-file=config.local.json
```

Build for web with:

```powershell
flutter build web --dart-define-from-file=config.local.json
```

Important: Flutter Web bundles compile-time values into the generated
JavaScript. This keeps the key out of source control, but it does not make the
key a true server-side secret. For stronger protection, keep privileged
credentials in the backend and expose only authenticated, user-scoped endpoints
to the browser.

## Project Structure

- `lib/backend_api/`: HTTP communication with the backend API.
- `lib/config/`: compile-time application configuration.
- `lib/models/`: domain models used by the UI and services.
- `lib/services/`: application state and MQTT management.
- `lib/pages/`: screens and feature dialogs.
- `lib/widgets/`: shared UI widgets.
- `assets/images/`: static image assets.

## Development

Install dependencies:

```powershell
flutter pub get
```

Run static analysis:

```powershell
flutter analyze
```

Run tests:

```powershell
flutter test
```