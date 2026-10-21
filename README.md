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
flutter build web --dart-define-from-file=config.local.json --pwa-strategy=none  
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

## Deployment

`.github/workflows/firebase-hosting.yml` builds and deploys to Firebase
Hosting (project `tcc2026-7d3c4`):

- Every pull request gets a preview URL, valid for 7 days and posted as a
  comment on the PR.
- Every push to `master` deploys to production.

The workflow needs two repository secrets (Settings > Secrets and variables >
Actions):

- `FLUXIO_API_KEY`: the same value used in `config.local.json`.
- `FIREBASE_SERVICE_ACCOUNT_TCC2026_7D3C4`: JSON key of a Google Cloud service
  account with the Firebase Hosting Admin, Cloud Run Viewer and API Keys
  Viewer roles. `firebase init hosting:github` creates this account and secret
  automatically; answer "no" when it offers to write workflow files, since
  this one already exists.

Manual deploy, if ever needed:

```powershell
flutter build web --dart-define-from-file=config.local.json --pwa-strategy=none
firebase deploy --only hosting
```
