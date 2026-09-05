import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Helper class for Google Gemini API via HTTP
/// Does not extend BaseChatModel to avoid dependency conflicts
class GeminiHTTPClient {
  final String apiKey;
  final String model;
  static const String baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';

  GeminiHTTPClient({
    required this.apiKey,
    this.model = 'gemini-1.5-pro',
  });

  /// Call Gemini API with a text prompt
  Future<String> callText(String prompt) async {
    try {
      final body = {
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
      };

      final response = await http.post(
        Uri.parse('$baseUrl/$model:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates'][0]['content']['parts'][0]['text'] ?? '';
      } else {
        throw Exception('Gemini API error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('GeminiHTTPClient error: $e');
      rethrow;
    }
  }
}



