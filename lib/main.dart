import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:tcc_flutter/routing/app_router.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/theme/app_theme.dart';

void main() {
  // Clean URLs (/devices/<id>) instead of hash URLs (/#/devices/<id>).
  // firebase.json already rewrites every path to index.html.
  usePathUrlStrategy();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final Future<void> _boot;

  @override
  void initState() {
    super.initState();
    _boot = _init();
  }

  Future<void> _init() async {
    await WidgetsBinding.instance.endOfFrame;
    await appState.tryPersistLogin(context);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _boot,
      builder: (context, snapshot) {
        // The router is only built after the persisted session check, so
        // its first redirect already knows whether the user is logged in
        // and a reload keeps the user on the same page.
        //
        // The splash must not contain a Navigator (no MaterialApp): on the
        // web a Navigator reports "/" to the browser and would wipe the
        // deep link before the router gets to read it.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Directionality(
            textDirection: TextDirection.ltr,
            child: ColoredBox(
              color: AppColors.background,
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            ),
          );
        }

        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          title: 'Fluxio',
          theme: appTheme,
          routerConfig: appRouter,
        );
      },
    );
  }
}
