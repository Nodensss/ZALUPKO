import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = ThemeData.light().textTheme;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Сканер ответа',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0C7C8C),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        textTheme: GoogleFonts.ibmPlexSansTextTheme(baseTextTheme),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const OcrHomePage(),
    );
  }
}

class OcrHomePage extends StatefulWidget {
  const OcrHomePage({super.key});

  @override
  State<OcrHomePage> createState() => _OcrHomePageState();
}

class _OcrHomePageState extends State<OcrHomePage> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _endpointController =
      TextEditingController(
        text:
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',
      );

  Uint8List? _imageBytes;
  String? _imageName;
  bool _isProcessing = false;
  String? _errorMessage;
  String? _rawText;
  ParsedQuestion? _parsed;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _apiKeyController.addListener(_saveApiKey);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString('ocr_api_key') ?? '';
    if (!mounted) {
      return;
    }
    setState(() {
      _prefs = prefs;
      if (savedKey.isNotEmpty) {
        _apiKeyController.text = savedKey;
      }
    });
  }

  void _saveApiKey() {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    prefs.setString('ocr_api_key', _apiKeyController.text.trim());
  }

  @override
  void dispose() {
    _apiKeyController.removeListener(_saveApiKey);
    _apiKeyController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() {
      _errorMessage = null;
    });
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null) {
      return;
    }
    final file = result.files.single;
    if (file.bytes == null) {
      setState(() {
        _errorMessage = 'Не удалось прочитать файл. Попробуйте другой файл.';
      });
      return;
    }
    setState(() {
      _imageBytes = file.bytes;
      _imageName = file.name;
      _rawText = null;
      _parsed = null;
    });
  }

  Future<void> _runOcr() async {
    if (_imageBytes == null) {
      setState(() {
        _errorMessage = 'Сначала выберите скриншот.';
      });
      return;
    }
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _errorMessage = 'Введите API-ключ OCR сервиса.';
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
      _rawText = null;
      _parsed = null;
    });

    try {
      final mimeType = _guessMimeType(_imageName);
      final base64Image = base64Encode(_imageBytes!);
      final prompt = _buildPrompt();
      final payload = jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'inline_data': {
                  'mime_type': mimeType,
                  'data': base64Image,
                }
              },
              {'text': prompt},
            ],
          }
        ],
      });

      final response = await http.post(
        Uri.parse(_endpointController.text.trim()),
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': apiKey,
        },
        body: payload,
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Gemini API вернул статус ${response.statusCode}. ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('Gemini не вернул ответ.');
      }
      final parts =
          (candidates.first as Map<String, dynamic>)['content']?['parts'] as List?;
      if (parts == null || parts.isEmpty) {
        throw Exception('Gemini не вернул текст.');
      }
      final text = (parts.first as Map<String, dynamic>)['text'] as String? ?? '';
      final cleanedText = text.trim();
      if (cleanedText.isEmpty) {
        throw Exception('Gemini вернул пустой текст.');
      }

      final parsed = parseGeminiOutput(cleanedText);
      if (!mounted) {
        return;
      }
      setState(() {
        _rawText = cleanedText;
        _parsed = parsed;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (!mounted) {
        return;
      }
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _copyResult() async {
    final parsed = _parsed;
    if (parsed == null) {
      return;
    }
    final buffer = StringBuffer();
    if (parsed.question != null && parsed.question!.isNotEmpty) {
      buffer.writeln('Вопрос: ${parsed.question}');
    }
    for (var i = 0; i < parsed.options.length; i++) {
      buffer.writeln('${i + 1}. ${parsed.options[i]}');
    }
    if (parsed.correctAnswer != null && parsed.correctAnswer!.isNotEmpty) {
      buffer.writeln('Правильный ответ: ${parsed.correctAnswer}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано в буфер обмена')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сканер правильных ответов'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFE7F3F4),
              Color(0xFFFDF7EC),
            ],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildIntroCard(context),
                  const SizedBox(height: 16),
                  _buildUploadCard(context),
                  const SizedBox(height: 16),
                  if (_errorMessage != null) _buildErrorCard(_errorMessage!),
                  if (_isProcessing) _buildLoadingCard(),
                  if (_parsed != null) ...[
                    const SizedBox(height: 16),
                    _buildResultCard(_parsed!),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _copyResult,
                      icon: const Icon(Icons.copy),
                      label: const Text('Копировать текст'),
                    ),
                  ],
                  if (_rawText != null) ...[
                    const SizedBox(height: 16),
                    _buildRawTextCard(_rawText!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntroCard(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white.withOpacity(0.9),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Загрузите скриншот, и приложение выделит правильный ответ.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'Используется Gemini API (Google AI Studio) для извлечения текста.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadCard(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'Gemini API ключ',
                helperText: 'Ключ из Google AI Studio',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _endpointController,
              decoration: const InputDecoration(
                labelText: 'Gemini endpoint',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image_outlined),
              label: Text(_imageBytes == null ? 'Выбрать скриншот' : 'Выбрать другой'),
            ),
            const SizedBox(height: 12),
            if (_imageBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  _imageBytes!,
                  height: 260,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _isProcessing ? null : _runOcr,
              child: const Text('Распознать'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return Card(
      color: const Color(0xFFFFE7E3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFB3261E)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFF7A1D16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: const [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text('Распознаём текст, это занимает несколько секунд...'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(ParsedQuestion parsed) {
    final correctIndex = parsed.correctIndex;
    return Card(
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              parsed.question ?? 'Вопрос не найден',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ...List.generate(parsed.options.length, (index) {
              final isCorrect = index == correctIndex;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isCorrect ? const Color(0xFFE6F7ED) : const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isCorrect ? const Color(0xFF1F8B4C) : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isCorrect ? Icons.check_circle : Icons.circle_outlined,
                      color: isCorrect ? const Color(0xFF1F8B4C) : Colors.black54,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(parsed.options[index])),
                  ],
                ),
              );
            }),
            if (parsed.correctAnswer != null && parsed.correctAnswer!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Правильный ответ: ${parsed.correctAnswer}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRawTextCard(String rawText) {
    return Card(
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Распознанный текст',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(rawText),
          ],
        ),
      ),
    );
  }
}

class ParsedQuestion {
  ParsedQuestion({
    required this.question,
    required this.options,
    required this.correctAnswer,
    required this.correctIndex,
  });

  final String? question;
  final List<String> options;
  final String? correctAnswer;
  final int? correctIndex;
}

ParsedQuestion parseOcrText(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  String? correctAnswer;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = RegExp(
      r'правильн\w*\s+ответ\w*\s*[:\-–]\s*(.+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (match != null) {
      correctAnswer = match.group(1)?.trim();
      break;
    }
    if (line.toLowerCase().contains('правильный') &&
        line.toLowerCase().contains('ответ')) {
      if (i + 1 < lines.length) {
        correctAnswer = lines[i + 1].trim();
      }
      break;
    }
  }

  int questionIndex = -1;
  String? question;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.contains('?')) {
      questionIndex = i;
      question = line;
      break;
    }
  }

  final stopTokens = [
    'неправильный',
    'правильный',
    'баллов',
    'назад',
    'далее',
    'завершить',
  ];

  final options = <String>[];
  if (questionIndex != -1) {
    for (var i = questionIndex + 1; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase();
      if (stopTokens.any(lower.contains)) {
        break;
      }
      if (_isNoiseLine(line)) {
        continue;
      }
      options.add(line);
    }
  }

  int? correctIndex;
  if (correctAnswer != null && correctAnswer!.isNotEmpty) {
    final normalizedCorrect = _normalize(correctAnswer!);
    for (var i = 0; i < options.length; i++) {
      final normalizedOption = _normalize(options[i]);
      if (normalizedOption == normalizedCorrect ||
          normalizedOption.contains(normalizedCorrect) ||
          normalizedCorrect.contains(normalizedOption)) {
        correctIndex = i;
        break;
      }
    }
  }

  return ParsedQuestion(
    question: question,
    options: options,
    correctAnswer: correctAnswer,
    correctIndex: correctIndex,
  );
}

ParsedQuestion parseGeminiOutput(String text) {
  final cleaned = _stripCodeFence(text);
  final jsonCandidate = _tryExtractJson(cleaned);
  if (jsonCandidate != null) {
    final question = (jsonCandidate['question'] as String?)?.trim();
    final options = (jsonCandidate['options'] as List?)
            ?.whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        <String>[];
    final correctAnswer =
        (jsonCandidate['correct_answer'] as String?)?.trim();
    int? correctIndex;
    if (correctAnswer != null && correctAnswer.isNotEmpty) {
      final normalizedCorrect = _normalize(correctAnswer);
      for (var i = 0; i < options.length; i++) {
        final normalizedOption = _normalize(options[i]);
        if (normalizedOption == normalizedCorrect ||
            normalizedOption.contains(normalizedCorrect) ||
            normalizedCorrect.contains(normalizedOption)) {
          correctIndex = i;
          break;
        }
      }
    }
    return ParsedQuestion(
      question: question,
      options: options,
      correctAnswer: correctAnswer,
      correctIndex: correctIndex,
    );
  }

  return parseOcrText(cleaned);
}

String _buildPrompt() {
  return '''
Ты получишь скриншот тестового вопроса на русском языке.
Нужно извлечь:
1) вопрос
2) список вариантов ответов
3) правильный ответ (по строке "Правильный ответ: ...", если есть)

Ответ верни строго в JSON без пояснений:
{"question":"...","options":["...","..."],"correct_answer":"..."}
''';
}

String _guessMimeType(String? fileName) {
  if (fileName == null) {
    return 'image/png';
  }
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'image/png';
}

String _stripCodeFence(String text) {
  final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
  final match = fenced.firstMatch(text);
  if (match != null && match.group(1) != null) {
    return match.group(1)!.trim();
  }
  return text.trim();
}

Map<String, dynamic>? _tryExtractJson(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {}

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start == -1 || end == -1 || end <= start) {
    return null;
  }
  final candidate = text.substring(start, end + 1);
  try {
    final decoded = jsonDecode(candidate);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {}
  return null;
}

bool _isNoiseLine(String line) {
  final lower = line.toLowerCase();
  if (lower.startsWith('екэ') || lower.startsWith('ек')) {
    return true;
  }
  if (lower.contains('оператор') || lower.contains('полимеризация')) {
    return true;
  }
  if (RegExp(r'^\d+(\s*из\s*\d+)?$').hasMatch(lower)) {
    return true;
  }
  return false;
}

String _normalize(String input) {
  return input.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
