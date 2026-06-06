import 'package:flutter/material.dart';
import 'package:tcc_flutter/pages/first_screens/login.dart';
import 'package:tcc_flutter/pages/main_screen/cards_page.dart';
import 'package:tcc_flutter/services/app_state.dart';

void main() {
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Fluxio',
      theme: ThemeData(
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white, width: 2),
          ),
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.greenAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: FutureBuilder(
        future: _boot,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          return appState.loggedIn ? const CardsPage() : const LoginPage();
        },
      ),
    );
  }
}
