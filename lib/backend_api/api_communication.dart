import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:flutter/material.dart';
import 'package:tcc_flutter/widgets/show_message.dart';

class Session {
  Map<String, String> headers = {};
  final http.Client _client = BrowserClient()..withCredentials = true;
  final String url = 'https://us-central1-tcc2026-7d3c4.cloudfunctions.net/api';
  static const String _apiKey = String.fromEnvironment('FLUXIO_API_KEY');

  Session() {
    _setApiKey();
  }

  void _setApiKey() {
    if (_apiKey.isNotEmpty) {
      headers['x-api-key'] = _apiKey;
    }
  }

  Future<Map<String, dynamic>> patchObj(
    String endpoint,
    Map<String, dynamic> data,
    BuildContext context,
  ) async {
    try {
      final response = await _client.patch(
        Uri.parse('$url/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...headers,
        },
        body: jsonEncode(data),
      );

      await _handleTokenErrorIfNeeded(context, response.body);

      final jsonResponse = jsonDecode(response.body);

      if (jsonResponse is Map<String, dynamic>) {
        return jsonResponse;
      } else {
        throw Exception('Resposta não é um objeto JSON válido.');
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<dynamic> getObj(String endpoint, BuildContext context) async {
    try {
      final uri = Uri.parse('$url/$endpoint');

      final response = await _client.get(uri, headers: headers);

      await _handleTokenErrorIfNeeded(context, response.body);

      try {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse is Map<String, dynamic>) {
          return jsonResponse;
        } else {
          return response.body;
        }
      } catch (e) {
        return response.body;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<String> get(String endpoint, {Map<String, String>? query}) async {
    try {
      final uri = Uri.parse('$url/$endpoint').replace(queryParameters: query);

      final response = await _client.get(uri, headers: headers);

      try {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse is Map<String, dynamic> &&
            jsonResponse.containsKey('message')) {
          return jsonResponse['message'].toString();
        } else {
          return response.body;
        }
      } catch (e) {
        return response.body;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<String> delete(String endpoint, {Map<String, dynamic>? data}) async {
    try {
      final response = await _client.delete(
        Uri.parse('$url/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...headers,
        },
        body: data != null ? jsonEncode(data) : null,
      );
      try {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse is Map<String, dynamic> &&
            jsonResponse.containsKey('message')) {
          return jsonResponse['message'].toString();
        } else {
          return response.body;
        }
      } catch (e) {
        return response.body;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<Map<String, dynamic>> post(
    String endpoint,
    Map<String, dynamic> data,
  ) async {
    final response = await _client.post(
      Uri.parse('$url/$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...headers,
      },
      body: jsonEncode(data),
    );

    final body = response.body.trim();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is String) {
          throw Exception(decoded);
        }
        if (decoded is Map && decoded['message'] != null) {
          throw Exception(decoded['message'].toString());
        }
      } catch (_) {
        throw Exception(body.isEmpty ? 'Erro inesperado' : body);
      }
    }

    if (body.isEmpty) return {};

    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {'message': body};
    }
  }

  Future<Map<String, dynamic>> postObj(
    String endpoint,
    Map<String, dynamic> data,
    BuildContext context,
  ) async {
    final response = await _client.post(
      Uri.parse('$url/$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...headers,
      },
      body: jsonEncode(data),
    );

    await _handleTokenErrorIfNeeded(context, response.body);

    // ERRO vindo do backend
    if (response.statusCode >= 400) {
      throw Exception(response.body);
    }

    // Tenta converter JSON
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      } else {
        throw Exception('Resposta inválida do servidor.');
      }
    } catch (_) {
      print(response.body);
      throw Exception(response.body);
    }
  }

  Future<String> patch(String endpoint, Map<String, dynamic> data) async {
    try {
      final response = await _client.patch(
        Uri.parse('$url/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...headers,
        },
        body: jsonEncode(data),
      );

      try {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse is Map<String, dynamic> &&
            jsonResponse.containsKey('message')) {
          return jsonResponse['message'].toString();
        } else {
          return response.body;
        }
      } catch (e) {
        return response.body;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<String> put(String endpoint, Map<String, dynamic> data) async {
    try {
      final response = await _client.put(
        Uri.parse('$url/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...headers,
        },
        body: jsonEncode(data),
      );
      try {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse is Map<String, dynamic> &&
            jsonResponse.containsKey('message')) {
          return jsonResponse['message'].toString();
        } else {
          return response.body;
        }
      } catch (e) {
        return response.body;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _handleTokenErrorIfNeeded(
    BuildContext context,
    String responseBody,
  ) async {
    if (responseBody.contains('Token inválido')) {
      // Navigator.pushReplacement(
      //   context,
      //   MaterialPageRoute(builder: (context) => LoginScreen()),
      // );
      showMessage(context, "sessionend", true);
    }
  }
}
