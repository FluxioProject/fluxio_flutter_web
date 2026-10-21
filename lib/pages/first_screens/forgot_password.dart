import 'package:flutter/material.dart';
import 'package:tcc_flutter/theme/app_theme.dart';
import 'package:tcc_flutter/widgets/gradient_bg.dart';

class ForgotPasswordPage extends StatelessWidget {
  const ForgotPasswordPage({super.key});

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
                shadowColor: AppColors.shadow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: AppColors.foreground.withOpacity(0.08),
                  ),
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
                      Divider(color: AppColors.foreground.withOpacity(0.08)),
                      const SizedBox(height: 18),
                      
                      // Texto explicativo
                      const Text(
                        'Informe seu e-mail cadastrado e enviaremos um link para redefinir sua senha.',
                        style: TextStyle(
                          fontSize: AppFontSize.md,
                          color: AppColors.foregroundSecondary,
                          height: 1.4,
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Email
                      const Text(
                        'E-mail',
                        style: TextStyle(
                          fontSize: AppFontSize.sm,
                          color: AppColors.foregroundSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _input(
                        hint: 'seuemail@dominio.com',
                        icon: Icons.mail_outline,
                        keyboardType: TextInputType.emailAddress,
                      ),

                      const SizedBox(height: 22),

                      // Botão enviar
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.onAccent,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () {
                            // TODO: enviar email de recuperação
                          },
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.send_rounded, size: 20),
                              SizedBox(width: 10),
                              Text(
                                'Enviar link de recuperação',
                                style: TextStyle(
                                  fontSize: AppFontSize.base,
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
                            'Lembrou da senha?',
                            style: TextStyle(
                              color: AppColors.foregroundSecondary,
                              fontSize: AppFontSize.base,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.accent,
                            ),
                            child: const Text(
                              'Voltar ao login',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: AppFontSize.base,
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

  static Widget _input({
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: AppColors.foreground.withOpacity(0.06),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.foreground.withOpacity(0.12)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.foreground.withOpacity(0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
        ),
      ),
    );
  }
}
