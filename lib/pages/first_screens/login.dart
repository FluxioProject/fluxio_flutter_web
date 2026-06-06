import 'package:flutter/material.dart';
import 'package:tcc_flutter/pages/main_screen/cards_page.dart';
import 'package:tcc_flutter/pages/first_screens/create_account.dart';
import 'package:tcc_flutter/pages/first_screens/forgot_password.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController(
    text: 'teste@teste.com',
  );
  final TextEditingController _passwordController = TextEditingController(
    text: 'Teste123',
  );

  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage(context, 'Preencha e-mail e senha', true);
      return;
    }

    setState(() => _loading = true);

    try {
      await appState.login(email, password, context);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const CardsPage()),
      );
    } catch (e) {
      showMessage(
        context,
        e.toString().replaceAll('Exception:', '').trim(),
        true,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        image: true,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                elevation: 14,
                shadowColor: Colors.black54,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset(
                        'assets/images/logo.png',
                        fit: BoxFit.contain,
                        width: 100,
                        height: 100,
                      ),
                      const SizedBox(height: 10),
                      Divider(color: Colors.white.withOpacity(0.08)),
                      const SizedBox(height: 18),

                      // Email
                      const Text(
                        'E-mail',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        onSubmitted: (_) =>
                            _handleLogin(), // ENTER dispara login
                        decoration: InputDecoration(
                          hintText: 'seuemail@dominio.com',
                          prefixIcon: const Icon(Icons.mail_outline),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Password
                      const Text(
                        'Senha',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) =>
                            _handleLogin(), // ENTER dispara login
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(
                                () => _obscurePassword = !_obscurePassword,
                              );
                            },
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // Actions row
                      Row(
                        children: [
                          TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ForgotPasswordPage(),
                                ),
                              );
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              padding: EdgeInsets.zero,
                            ),
                            child: const Text(
                              'Esqueci minha senha',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Button
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _handleLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              57,
                              194,
                              128,
                            ),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.login_rounded, size: 20),
                                    SizedBox(width: 10),
                                    Text(
                                      'Entrar',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Footer
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Não tem conta?',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const RegisterPage(),
                                ),
                              );
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.greenAccent,
                            ),
                            child: const Text(
                              'Criar conta',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
