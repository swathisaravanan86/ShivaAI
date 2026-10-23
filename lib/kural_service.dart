import 'dart:convert';

import 'package:flutter/services.dart';

class Kural {
  final int number;
  final String chapter;
  final String meaning;
  final String tamil;

  Kural.fromJson(Map<String, dynamic> j)
      : number = j['number'] as int,
        chapter = j['chapter'] as String,
        meaning = j['meaning'] as String,
        tamil = j['tamil'] as String;
}

class KuralService {
  static const notFoundMessage =
      'I could not find a Thirukural for that. Try using words from the '
      'Kural meaning, such as learning, leader, or team.';

  static const _stopWords = {
    'the', 'and', 'for', 'with', 'want', 'what', 'how', 'can', 'you',
    'tell', 'about', 'should', 'this', 'that', 'my', 'me', 'i', 'to',
    'do', 'is', 'are', 'please', 'help', 'but', 'dont', 'know', 'does',
    'will', 'not', 'his', 'her', 'their', 'they', 'them', 'who', 'which',
    'from', 'have', 'has', 'was', 'were', 'be', 'it', 'its', 'of', 'in',
    'on', 'at', 'by', 'or', 'an', 'a', 'if', 'so', 'than', 'then',
  };

  List<Kural> _kurals = [];

  Future<void> load() async {
    final raw = await rootBundle.loadString('assets/kurals.json');
    final list = jsonDecode(raw) as List<dynamic>;
    _kurals = list
        .map((e) => Kural.fromJson(e as Map<String, dynamic>))
        .where((k) => !k.meaning.contains('here.'))
        .toList();
  }

  // Scores each Kural by how many of the spoken words appear in its
  // English meaning and chapter name. Returns null if nothing matches.
  Kural? findBest(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length > 2 && !_stopWords.contains(w))
        .toSet();
    if (words.isEmpty) return null;

    Kural? best;
    var bestScore = 0;
    for (final k in _kurals) {
      final text = '${k.meaning} ${k.chapter}'.toLowerCase();
      final score = words.where((w) => text.contains(w)).length;
      if (score > bestScore) {
        bestScore = score;
        best = k;
      }
    }
    return best;
  }
}