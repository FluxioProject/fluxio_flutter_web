---
name: flutter-web-architecture
description: "Explains the Fluxio Flutter web architecture, app state, backend API client, browser MQTT flow, dashboard pages, Firebase Hosting, and logic builder. Use when: tracing web behavior, adding screens, debugging MQTT WebSockets, or changing client contracts."
---

# Flutter Web Architecture

## Module Map

| Area | File(s) | Responsibility |
|---|---|---|
| App bootstrap | `lib/main.dart` | Persisted login check, then `MaterialApp.router` |
| Routing | `lib/routing/` | `go_router` config, URL paths (`AppRoutes`), login redirect, route helper pages |
| Theme | `lib/theme/app_theme.dart` | Color tokens (`AppColors`), type scale (`AppFontSize`), `ThemeData` |
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
  -> usePathUrlStrategy()
  -> MyApp
  -> _init()
  -> appState.tryPersistLogin(context)
  -> MaterialApp.router(appRouter)
  -> redirect: logged in -> requested URL (or /devices)
               not logged in -> /login?from=<requested URL>
```

## Routes

| Path | Screen |
|---|---|
| `/login` | Login |
| `/login/register` | Registration |
| `/login/forgot-password` | Password recovery |
| `/devices` | Device list |
| `/devices/:deviceId` | Device dashboard |
| `/devices/:deviceId/logic` | Logic editor (asks before leaving with unsent changes) |

Routes are nested, so a deep link or reload rebuilds the whole stack and
back navigation keeps working. Navigate with `context.go(AppRoutes...)` so
the browser URL follows.

The manual command page has no URL on purpose: it switches the device to
manual mode and must only open after the confirmation dialog on the
dashboard. Dialogs (firmware upload, channel editing) also stay off the URL.

The splash shown during the session check must not contain a `Navigator`
(no `MaterialApp`): on the web it reports `/` to the browser and wipes the
deep link before the router reads it.

## Colors and Text

Use `AppColors` tokens and `AppFontSize` sizes from
`lib/theme/app_theme.dart` instead of `Color(...)`, `Colors.*` or numeric
font sizes, so the visual identity changes in one place.

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
4. Add the page under the matching `lib/pages/` area and, if it should be
   reachable by URL, a route in `lib/routing/app_router.dart`.
5. Wire MQTT subscriptions through `mqttManager` when live telemetry is needed.
6. Run `flutter analyze`.

## Do Not Change Without Understanding

- `mqttManager` is shared global state; always unsubscribe or clear subscriptions when leaving device contexts.
- Web MQTT uses `MqttBrowserClient`; mobile uses `MqttServerClient`.
- Logic builder payloads must remain compatible with ESP32 block execution.
- Web builds expose client-side configuration, so never include privileged secrets.
