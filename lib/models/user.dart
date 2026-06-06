class Usuario {
  final String uid;
  final String email;
  String nome;

  Usuario({
    required this.uid,
    required this.nome,
    required this.email,
  });

  Usuario copyWith({
    String? nome,
    String? email,
  }) {
    return Usuario(
      uid: uid,
      nome: nome ?? this.nome,
      email: email ?? this.email,
    );
  }

  factory Usuario.fromBackend(Map<String, dynamic> json) {
    return Usuario(
      uid: (json['uid'] as String?) ?? '',
      nome: (json['name'] as String?) ?? '',
      email: (json['email'] as String?) ?? '',
    );
  }
}
