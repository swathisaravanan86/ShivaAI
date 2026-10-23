import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;

const apiKey = String.fromEnvironment('GEMINI_API_KEY');

void main() {
  runApp(const ShivaAIApp());
}

class ShivaAIApp extends StatelessWidget {
  const ShivaAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ShivaAI',
      theme: ThemeData.dark(),
      home: const VoiceScreen(),
    );
  }
}

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final stt.SpeechToText speech = stt.SpeechToText();
  final FlutterTts tts = FlutterTts();

  bool listening = false;
  bool loading = false;
  bool speaking = false;

  String status = 'Tap the mic and speak';
  String recognizedText = '';
  String reply = 'Vanakkam! I am ShivaAI. How can I help you?';

  final List<Map<String, String>> history = [];

  @override
  void initState() {
    super.initState();
    setupVoice();
  }

  Future<void> setupVoice() async {
    try {
      await speech.initialize(
        onStatus: (value) {
          if (!mounted) return;
          setState(() {
            listening = speech.isListening;
            if (value == 'notListening' && !loading) {
              status = 'Tap the mic and speak';
            }
          });
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            listening = false;
            status = 'Mic error: ${error.errorMsg}';
          });
        },
      );

      await tts.setSpeechRate(0.46);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);

      tts.setStartHandler(() {
        if (mounted) setState(() => speaking = true);
      });

      tts.setCompletionHandler(() {
        if (mounted) setState(() => speaking = false);
      });

      tts.setErrorHandler((message) {
        if (mounted) setState(() => speaking = false);
      });

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() => status = 'Voice setup failed. Check permissions.');
      }
    }
  }

  Future<void> toggleMic() async {
    if (loading) return;

    if (speech.isListening) {
      await speech.stop();
      if (recognizedText.trim().isNotEmpty) {
        await askGemini(recognizedText.trim());
      } else if (mounted) {
        setState(() => status = 'No speech detected. Try again.');
      }
      return;
    }

    if (apiKey.isEmpty) {
      setState(() => status = 'Gemini API key is not configured.');
      return;
    }

    if (!speech.isAvailable) {
      final available = await speech.initialize();
      if (!available) {
        setState(() => status = 'Speech recognition unavailable.');
        return;
      }
    }

    await tts.stop();
    recognizedText = '';

    setState(() {
      listening = true;
      speaking = false;
      status = 'Listening... speak now';
    });

    try {
      await speech.listen(
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            recognizedText = result.recognizedWords;
            status = result.finalResult
                ? 'Processing your question...'
                : 'Listening...';
          });

          if (result.finalResult &&
              result.recognizedWords.trim().isNotEmpty) {
            speech.stop();
            askGemini(result.recognizedWords.trim());
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          listening = false;
          status = 'Could not start microphone.';
        });
      }
    }
  }

  bool isAdviceQuestion(String question) {
    final q = question.toLowerCase();

    const keywords = [
      'suggest',
      'suggestion',
      'advice',
      'advise',
      'idea',
      'ideas',
      'recommend',
      'recommendation',
      'what should i do',
      'how can i improve',
      'give me an idea',
      'give me suggestions',
      'enna pan',
      'enna seiya',
      'epdi improve',
      'idea kudu',
      'suggestion kudu',
      'advice kudu',
      'oru idea',
      'nalla idea',
      'yosana',
      'ஆலோசனை',
      'யோசனை',
      'பரிந்துரை',
      'என்ன செய்ய',
      'எப்படி மேம்படுத்த',
      'யோசனை சொல்லு',
    ];

    return keywords.any((word) => q.contains(word));
  }

  Future<String> getKuralContext(String question) async {
    try {
      final uri = Uri.https(
        'kural.codewithram.dev',
        '/api/kural',
        {
          'q': question,
          'page': '1',
          'limit': '3',
        },
      );

      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return '';

      final data = jsonDecode(response.body);
      final results = data is Map ? data['results'] : null;

      if (results is! List || results.isEmpty) return '';

      final kurals = <String>[];

      for (final item in results.take(3)) {
        if (item is! Map) continue;

        final number =
            item['number'] ?? item['verse_number'] ?? '';
        final rawKural =
            item['kural'] ?? item['tamil_kural'] ?? '';
        final meaning = item['meaning'];

        final explanation = item['tamil_explanation'] ??
            (meaning is Map
                ? (meaning['en_modern'] ?? meaning['en'] ?? '')
                : item['explanation'] ?? '');

        final String kuralText = rawKural is List
            ? rawKural.join('\n')
            : rawKural.toString().replaceAll('\$', '\n');

        if (kuralText.trim().isEmpty) continue;

        kurals.add(
          'Kural Number: $number\n'
          'Tamil Kural: $kuralText\n'
          'Meaning: $explanation',
        );
      }

      return kurals.join('\n\n');
    } catch (_) {
      return '';
    }
  }
    Future<void> askGemini(String question) async {
    if (loading || question.trim().isEmpty) return;

    if (apiKey.isEmpty) {
      setState(() => status = 'Gemini API key is missing.');
      return;
    }

    setState(() {
      loading = true;
      listening = false;
      recognizedText = question;
      status = 'ShivaAI is thinking...';
    });

    try {
      final contents = <Map<String, dynamic>>[];

      for (final item in history) {
        contents.add({
          'role': item['role'] == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': item['text']!}
          ],
        });
      }

      String questionForGemini = question;

      if (isAdviceQuestion(question)) {
        final kuralContext = await getKuralContext(question);

        questionForGemini = kuralContext.isNotEmpty
            ? '''
User question: $question

Thirukkural dataset search results:
$kuralContext

Give practical advice based on the user's situation.
Use a relevant Kural from these results only.
Mention its number and Tamil couplet only if provided above.
Never invent or alter a Kural.
'''
            : '''
User question: $question

No relevant Thirukkural result was available from the dataset search.
Give useful practical advice without quoting or inventing a Kural.
''';
      }

      contents.add({
        'role': 'user',
        'parts': [
          {'text': questionForGemini}
        ],
      });

      final response = await http
          .post(
            Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/'
              'models/gemini-2.5-flash:generateContent',
            ),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode({
              'systemInstruction': {
                'parts': [
                  {
                    'text': '''
You are ShivaAI, a friendly conversational voice assistant.
Speak naturally, warmly and clearly, like a helpful person.
Reply in the same language as the user: Tamil, English or Tanglish.
Keep spoken answers concise unless the user asks for details.
Remember recent conversation and answer follow-up questions.

Use Thirukkural only for ideas, suggestions, recommendations or advice.
When Kural search results are included in the user message,
use a relevant result to support practical advice.
Never invent a Kural, number, chapter or quotation.
If no Kural search result is provided, give advice normally without
pretending you searched the dataset.
For normal questions, do not force Thirukkural into the answer.
For direct Thirukkural questions, answer honestly and do not invent
a couplet. If unsure, say so.
Avoid markdown formatting in answers intended to be spoken aloud.
'''
                  }
                ],
              },
              'contents': contents,
              'generationConfig': {
                'temperature': 0.7,
                'maxOutputTokens': 500,
              },
            }),
          )
          .timeout(const Duration(seconds: 40));

      if (response.statusCode != 200) {
        throw Exception(
          'Gemini error ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;

      if (candidates == null || candidates.isEmpty) {
        throw Exception('Gemini returned no answer. Please try again.');
      }

      final parts =
          candidates.first['content']?['parts'] as List? ?? [];

      final answer = parts
          .where((part) => part['text'] != null)
          .map((part) => part['text'].toString())
          .join('\n')
          .trim();

      if (answer.isEmpty) {
        throw Exception('The AI returned an empty answer.');
      }

      history.add({'role': 'user', 'text': question});
      history.add({'role': 'assistant', 'text': answer});

      // Keep recent conversation context manageable.
      if (history.length > 12) {
        history.removeRange(0, history.length - 12);
      }

      if (!mounted) return;

      setState(() {
        reply = answer;
        status = 'Speaking...';
      });

      await speakAnswer(answer);
    } catch (e) {
      if (mounted) {
        setState(() {
          status = 'Could not get an answer. Check internet/API key.';
          reply = 'Sorry, I could not answer just now. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          listening = false;

          if (!speaking && status == 'Speaking...') {
            status = 'Tap the mic and speak';
          }
        });
      }
    }
  }

  Future<void> speakAnswer(String text) async {
    try {
      await tts.stop();

      // Device TTS language support may vary.
      await tts.speak(text);
    } catch (e) {
      if (mounted) {
        setState(
          () => status = 'Answer received; voice playback failed.',
        );
      }
    }
  }

  @override
  void dispose() {
    speech.stop();
    tts.stop();
    super.dispose();
  }
    @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF061522),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.graphic_eq,
                    color: Color(0xFF55BFFF),
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'ShivaAI',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () async {
                      await tts.stop();
                      if (!mounted) return;

                      setState(() {
                        history.clear();
                        recognizedText = '';
                        reply =
                            'Vanakkam! What would you like to talk about?';
                        status = 'Conversation cleared';
                      });
                    },
                    icon: const Icon(
                      Icons.refresh,
                      color: Colors.white70,
                    ),
                    tooltip: 'New conversation',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'YOUR VOICE ASSISTANT',
                style: TextStyle(
                  color: Color(0xFF55BFFF),
                  letterSpacing: 3,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Talk naturally.\nI’m listening.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Center(
                  child: CustomPaint(
                    size: const Size(280, 280),
                    painter: WavePainter(),
                    child: SizedBox(
                      width: 280,
                      height: 280,
                      child: Center(
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF087DFF),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF168CFF)
                                    .withOpacity(0.35),
                                blurRadius: 35,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: Icon(
                            loading
                                ? Icons.hourglass_top
                                : speaking
                                    ? Icons.volume_up
                                    : Icons.graphic_eq,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF8BBBD6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 14),
              if (recognizedText.isNotEmpty)
                _messageCard('You said', recognizedText),
              _messageCard('ShivaAI', reply),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: toggleMic,
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: listening
                        ? const Color(0xFFE34D68)
                        : const Color(0xFF087DFF),
                    border: Border.all(
                      color: const Color(0xFF73D0FF),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF168CFF)
                            .withOpacity(0.35),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: Icon(
                    listening ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'TAP TO SPEAK',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageCard(String title, String message) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 100),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF102638),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF25465D)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF55BFFF),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(
      size.width / 2,
      size.height / 2,
    );

    for (int layer = 0; layer < 7; layer++) {
      final path = Path();
      final paint = Paint()
        ..color = const Color(0xFF168CFF)
            .withOpacity(0.25 + layer * 0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;

      for (int i = 0; i <= 360; i++) {
        final angle = i * math.pi / 180;

        final radius = 83 +
            12 * math.sin(angle * 3 + layer * 0.4) +
            8 * math.cos(angle * 5 + layer * 0.3) +
            layer * 5;

        final x = center.dx + radius * math.cos(angle);
        final y = center.dy + radius * math.sin(angle);

        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) => false;
}