import 'package:flutter/material.dart';
import 'package:tcc_flutter/services/app_state.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _hidePass = true;
  bool _hideConfirm = true;
  
  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;

    if (name.isEmpty || email.isEmpty || pass.isEmpty || confirm.isEmpty) {
      showMessage(context, 'Preencha todos os campos', true);
      return;
    }

    if (pass != confirm) {
      showMessage(context, 'As senhas não conferem', true);
      return;
    }

    if (pass.length < 6) {
      showMessage(context, 'Senha deve ter no mínimo 6 caracteres', true);
      return;
    }

    setState(() => _loading = true);

    try {
      await appState.register(name, email, pass, context);

      if (!mounted) return;

      showMessage(context, 'Conta criada com sucesso', false);

      Navigator.pop(context); // volta pro login
    } catch (e) {
      showMessage(context, 'Erro ao criar conta', true);
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

                      // Nome
                      const Text(
                        'Nome',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      _input(
                        hint: 'Seu nome completo',
                        _nameCtrl,
                        icon: Icons.person_outline,
                      ),

                      const SizedBox(height: 14),

                      // Email
                      const Text(
                        'E-mail',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      _input(
                        _emailCtrl,
                        hint: 'seuemail@dominio.com',
                        icon: Icons.mail_outline,
                        keyboardType: TextInputType.emailAddress,
                      ),

                      const SizedBox(height: 14),

                      // Senha
                      const Text(
                        'Senha',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      _input(
                        _passCtrl,
                        hint: '••••••••',
                        icon: Icons.lock_outline,
                        obscure: _hidePass,
                        suffix: IconButton(
                          tooltip: _hidePass
                              ? 'Mostrar senha'
                              : 'Ocultar senha',
                          onPressed: () =>
                              setState(() => _hidePass = !_hidePass),
                          icon: Icon(
                            _hidePass ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white70,
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Confirmar senha
                      const Text(
                        'Confirmar senha',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      _input(
                        _confirmCtrl,
                        hint: '••••••••',
                        icon: Icons.lock_outline,
                        obscure: _hideConfirm,
                        suffix: IconButton(
                          tooltip: _hideConfirm
                              ? 'Mostrar senha'
                              : 'Ocultar senha',
                          onPressed: () =>
                              setState(() => _hideConfirm = !_hideConfirm),
                          icon: Icon(
                            _hideConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: Colors.white70,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Botão criar conta
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              57,
                              194,
                              128,
                            ),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _loading ? null : _handleRegister,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle_outline, size: 20),
                              SizedBox(width: 10),
                              Text(
                                'Criar conta',
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
                            'Já tem conta?',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.greenAccent,
                            ),
                            child: const Text(
                              'Entrar',
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

  // Input padrão reutilizável
  Widget _input(
    TextEditingController controller, {
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      obscureText: obscure,
      keyboardType: keyboardType,
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.greenAccent, width: 1.4),
        ),
      ),
    );
  }
}
