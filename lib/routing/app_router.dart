import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tcc_flutter/pages/dashboard_screen/device_details_page.dart';
import 'package:tcc_flutter/pages/dashboard_screen/drag_n_drop.dart';
import 'package:tcc_flutter/pages/first_screens/create_account.dart';
import 'package:tcc_flutter/pages/first_screens/forgot_password.dart';
import 'package:tcc_flutter/pages/first_screens/login.dart';
import 'package:tcc_flutter/pages/main_screen/cards_page.dart';
import 'package:tcc_flutter/routing/route_pages.dart';
import 'package:tcc_flutter/services/app_state.dart';

/// URL paths of every screen that can be reached by address.
///
/// Routes are nested (devices > device > logic, login > register), so a
/// deep link or page reload rebuilds the whole stack and the back button
/// keeps working.
///
/// The manual command screen deliberately has no URL: it switches the
/// device to manual mode and must only be opened after the confirmation
/// dialog on the device dashboard.
abstract final class AppRoutes {
  static const login = '/login';
  static const register = '/login/register';
  static const forgotPassword = '/login/forgot-password';
  static const devices = '/devices';

  static String device(String deviceId) => '$devices/$deviceId';
  static String deviceLogic(String deviceId) => '${device(deviceId)}/logic';
}

bool _isPublic(String path) => path.startsWith(AppRoutes.login);

// Only follow redirects back into this app, never to another site.
bool _isInternalPath(String? path) =>
    path != null && path.startsWith('/') && !path.startsWith('//');

String? _redirect(BuildContext context, GoRouterState state) {
  final path = state.matchedLocation;

  if (!appState.loggedIn) {
    if (_isPublic(path)) return null;

    // Remember where the user was going, to return there after login.
    final from = state.uri.toString();
    return Uri(
      path: AppRoutes.login,
      queryParameters: path == '/' ? null : {'from': from},
    ).toString();
  }

  if (_isPublic(path) || path == '/') {
    final from = state.uri.queryParameters['from'];
    return _isInternalPath(from) ? from : AppRoutes.devices;
  }

  return null;
}

final GoRouter appRouter = GoRouter(
  refreshListenable: appState.authState,
  redirect: _redirect,
  errorBuilder: (context, state) => const NotFoundPage(),
  routes: [
    GoRoute(path: '/', redirect: (_, _) => AppRoutes.devices),
    GoRoute(
      path: AppRoutes.login,
      builder: (_, _) => const LoginPage(),
      routes: [
        GoRoute(path: 'register', builder: (_, _) => const RegisterPage()),
        GoRoute(
          path: 'forgot-password',
          builder: (_, _) => const ForgotPasswordPage(),
        ),
      ],
    ),
    GoRoute(
      path: AppRoutes.devices,
      builder: (_, _) => const CardsPage(),
      routes: [
        GoRoute(
          path: ':deviceId',
          builder: (_, state) => DeviceRoute(
            deviceId: state.pathParameters['deviceId']!,
            builder: (device) => DeviceDetailsPage(device: device),
          ),
          routes: [
            GoRoute(
              path: 'logic',
              onExit: (context, _) => confirmLeaveLogicEditor(context),
              builder: (_, state) => DeviceRoute(
                deviceId: state.pathParameters['deviceId']!,
                builder: (device) => LogicBuilderLoader(device: device),
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);
