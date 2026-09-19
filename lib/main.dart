import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Web環境で効果音を鳴らすためのJavaScript連携
import 'dart:js_interop' as js;

@js.JS('eval')
external void _evalJs(String code);

// Web Audio APIを使った効果音再生関数
void _playSoundEffect(bool isCorrect) {
  if (!kIsWeb) return;

  if (isCorrect) {
    const jsCode = '''
      (function() {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        function playNote(freq, startTime, duration) {
          const osc = ctx.createOscillator();
          const gain = ctx.createGain();
          osc.type = 'sine';
          osc.frequency.setValueAtTime(freq, ctx.currentTime + startTime);
          gain.gain.setValueAtTime(0.15, ctx.currentTime + startTime);
          gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + startTime + duration);
          osc.connect(gain);
          gain.connect(ctx.destination);
          osc.start(ctx.currentTime + startTime);
          osc.stop(ctx.currentTime + startTime + duration);
        }
        playNote(659.25, 0, 0.2);
        playNote(880.00, 0.15, 0.4);
      })();
    ''';
    try { _evalJs(jsCode); } catch (_) {}
  } else {
    const jsCode = '''
      (function() {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        function playBuzz(startTime, duration) {
          const osc = ctx.createOscillator();
          const gain = ctx.createGain();
          osc.type = 'sawtooth';
          osc.frequency.setValueAtTime(130, ctx.currentTime + startTime);
          gain.gain.setValueAtTime(0.2, ctx.currentTime + startTime);
          gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + startTime + duration);
          osc.connect(gain);
          gain.connect(ctx.destination);
          osc.start(ctx.currentTime + startTime);
          osc.stop(ctx.currentTime + startTime + duration);
        }
        playBuzz(0, 0.2);
        playBuzz(0.25, 0.3);
      })();
    ''';
    try { _evalJs(jsCode); } catch (_) {}
  }
}

void main() => runApp(const MooThaiTypingApp());

class MooThaiTypingApp extends StatelessWidget {
  const MooThaiTypingApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moo Teacher Thai Typing',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        fontFamily: 'SF Pro Display',
      ),
      home: const MooThaiTyping(),
    );
  }
}

class MooThaiTyping extends StatefulWidget {
  const MooThaiTyping({Key? key}) : super(key: key);

  @override
  State<MooThaiTyping> createState() => _MooThaiTypingState();
}

class _MooThaiTypingState extends State<MooThaiTyping> {
  static const String backendUrl = 'https://thai-ai-typing-backend.onrender.com/translate';

  final FlutterTts _flutterTts = FlutterTts();

  final TextEditingController _userTextController = TextEditingController();
  final TextEditingController _thaiInputController = TextEditingController();

  String _selectedLang = 'JA';
  String _translatedThai = '';
  String _phoneticText = ''; // 追加: 発音記号（アルファベット）の管理
  bool _isTranslating = false;
  bool _isCorrect = false;
  bool? _lastSoundState;
  Timer? _debounceTimer;

  // 単語帳用リスト [{original: "ホテル", thai: "โรงแรม", phonetic: "roong-raem"}]
  List<Map<String, String>> _savedWords = [];

  final Map<String, Map<String, String>> _i18n = {
    'JA': {
      'flag': '🇯🇵',
      'label': '日本語',
      'titleHeader': 'ムー先生のタイ文字レッスン 🇹🇭',
      'inputLabel': '覚えたい言葉を入力',
      'translationHeader': '【タイ語翻訳】',
      'typeLabel': '上のタイ文字をタイピング',
      'typeHint': 'タイ語キーボードで入力...',
      'correctMsg': '🎉 正解！',
      'incorrectMsg': '❌ 不正解',
      'defaultText': 'ありがとう',
      'targetLangName': 'Japanese',
      'vocabBookTitle': 'マイ単語帳',
      'emptyVocab': '保存された単語はありません',
    },
    'EN': {
      'flag': '🇺🇸',
      'label': 'English',
      'titleHeader': 'Moo Teacher Thai Typing 🇹🇭',
      'inputLabel': 'Enter any phrase',
      'translationHeader': '【Thai Translation】',
      'typeLabel': 'Type the Thai text above',
      'typeHint': 'Type with Thai keyboard...',
      'correctMsg': '🎉 Correct!',
      'incorrectMsg': '❌ Incorrect',
      'defaultText': 'Thank you',
      'targetLangName': 'English',
      'vocabBookTitle': 'Vocabulary Book',
      'emptyVocab': 'No saved words yet',
    },
    'KO': {
      'flag': '🇰🇷',
      'label': '한국어',
      'titleHeader': '무 선생님의 태국어 타이핑 🇹🇭',
      'inputLabel': '원하는 단어/문장 입력',
      'translationHeader': '【태국어 번역】',
      'typeLabel': '위의 태국어를 타이핑하세요',
      'typeHint': '태국어 키보드로 입력...',
      'correctMsg': '🎉 정답입니다!',
      'incorrectMsg': '❌ 오답입니다',
      'defaultText': '감사합니다',
      'targetLangName': 'Korean',
      'vocabBookTitle': '내 단어장',
      'emptyVocab': '저장된 단어가 없습니다',
    },
    'ZH': {
      'flag': '🇨🇳',
      'label': '中文',
      'titleHeader': 'Moo老师泰语打字练习 🇹🇭',
      'inputLabel': '输入任意词句',
      'translationHeader': '【泰语翻译】',
      'typeLabel': '请打出上面的泰文字',
      'typeHint': '使用泰语键盘输入...',
      'correctMsg': '🎉 回答正确！',
      'incorrectMsg': '❌ 回答错误',
      'defaultText': '谢谢',
      'targetLangName': 'Chinese',
      'vocabBookTitle': '我的单词本',
      'emptyVocab': '暂无保存的单词',
    },
  };

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadSavedWords(); // ローカルストレージから単語帳を読込
    _userTextController.text = _i18n[_selectedLang]!['defaultText']!;
    _translateText(_userTextController.text);
  }

  void _initTts() async {
    try {
      await _flutterTts.setLanguage("th-TH");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      if (kIsWeb) {
        await _flutterTts.awaitSpeakCompletion(true);
      }
    } catch (e) {
      debugPrint("TTS Init Error: $e");
    }
  }

  // --- 単語帳のローカル保存（SharedPreferences） ---
  Future<void> _loadSavedWords() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString('saved_words');
    if (jsonString != null) {
      final List<dynamic> decoded = jsonDecode(jsonString);
      setState(() {
        _savedWords = decoded.map((item) => Map<String, String>.from(item)).toList();
      });
    }
  }

  Future<void> _toggleSaveWord() async {
    if (_translatedThai.isEmpty || _userTextController.text.trim().isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final currentWord = {
      'original': _userTextController.text.trim(),
      'thai': _translatedThai,
      'phonetic': _phoneticText,
    };

    final isSaved = _savedWords.any((w) => w['thai'] == _translatedThai);

    setState(() {
      if (isSaved) {
        _savedWords.removeWhere((w) => w['thai'] == _translatedThai);
      } else {
        _savedWords.add(currentWord);
      }
    });

    await prefs.setString('saved_words', jsonEncode(_savedWords));
  }

  void _changeLanguage(String langCode) {
    setState(() {
      _selectedLang = langCode;
      if (_userTextController.text.isEmpty ||
          _i18n.values.any((m) => m['defaultText'] == _userTextController.text)) {
        _userTextController.text = _i18n[_selectedLang]!['defaultText']!;
        _translateText(_userTextController.text);
      }
    });
  }

  Future<void> _translateText(String text) async {
    final query = text.trim();
    if (query.isEmpty) {
      setState(() {
        _translatedThai = '';
        _phoneticText = '';
        _isCorrect = false;
        _lastSoundState = null;
      });
      return;
    }

    setState(() => _isTranslating = true);

    try {
      final response = await http.post(
        Uri.parse(backendUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': query,
          'target_language': _i18n[_selectedLang]!['targetLangName'] ?? 'Japanese',
        }),
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final rawResult = body['result'] as String;

        String cleanedJson = rawResult
            .replaceAll(RegExp(r'^```json\s*'), '')
            .replaceAll(RegExp(r'^```\s*'), '')
            .replaceAll(RegExp(r'\s*```$'), '')
            .trim();

        final Map<String, dynamic> parsed = jsonDecode(cleanedJson);

        if (mounted) {
          setState(() {
            _translatedThai = (parsed['thai_text'] ?? '').toString().trim();
            _phoneticText = (parsed['phonetic'] ?? '').toString().trim(); // 発音記号をセット
            _checkInput(_thaiInputController.text);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _translatedThai = 'サーバーエラー (${response.statusCode})';
            _phoneticText = '';
          });
        }
      }
    } catch (e) {
      debugPrint("Translate API Error: $e");
      if (mounted) {
        setState(() {
          _translatedThai = '通信エラーが発生しました';
          _phoneticText = '';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isTranslating = false);
      }
    }
  }

  void _onUserTextChanged(String text) {
    setState(() {});
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _translateText(text);
    });
  }

  void _clearUserText() {
    _userTextController.clear();
    _thaiInputController.clear();
    setState(() {
      _translatedThai = '';
      _phoneticText = '';
      _isCorrect = false;
      _lastSoundState = null;
    });
  }

  void _speakThai(String text) async {
    if (text.isEmpty) return;
    try {
      await _flutterTts.stop();
      await _flutterTts.setLanguage("th-TH");
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint("Speak Error: $e");
    }
  }

  void _checkInput(String input) {
    final bool correct = (_translatedThai.isNotEmpty && input.trim() == _translatedThai.trim());
    final bool hasInput = input.trim().isNotEmpty;

    setState(() {
      _isCorrect = correct;
    });

    if (hasInput) {
      if (_lastSoundState != correct) {
        _playSoundEffect(correct);
        _lastSoundState = correct;
      }
    } else {
      _lastSoundState = null;
    }
  }

  // --- 単語帳モーダル表示 ---
  void _showVocabDialog() {
    final t = _i18n[_selectedLang]!;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.menu_book_rounded, color: Color(0xFFC8102E)),
                  const SizedBox(width: 8),
                  Text(t['vocabBookTitle']!, style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: _savedWords.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24.0),
                        child: Text(t['emptyVocab']!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _savedWords.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final item = _savedWords[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              item['thai'] ?? '',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                            ),
                            subtitle: Text("${item['original']} (${item['phonetic']})"),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.grey),
                              onPressed: () async {
                                final prefs = await SharedPreferences.getInstance();
                                setState(() {
                                  _savedWords.removeAt(index);
                                });
                                setDialogState(() {});
                                await prefs.setString('saved_words', jsonEncode(_savedWords));
                              },
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _userTextController.text = item['original'] ?? '';
                              _thaiInputController.clear();
                              _translateText(item['original'] ?? '');
                            },
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  child: const Text('閉じる', style: TextStyle(color: Color(0xFFC8102E))),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _userTextController.dispose();
    _thaiInputController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[_selectedLang]!;
    final bool hasInput = _thaiInputController.text.trim().isNotEmpty;
    final bool isSaved = _savedWords.any((w) => w['thai'] == _translatedThai && _translatedThai.isNotEmpty);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 28.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ヘッダー（単語帳ボタン ＋ 言語選択）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _showVocabDialog,
                        icon: const Icon(Icons.bookmark_rounded, size: 18, color: Color(0xFFC8102E)),
                        label: Text(
                          "📚 (${_savedWords.length})",
                          style: const TextStyle(color: Color(0xFF374151), fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                            side: const BorderSide(color: Color(0xFFE5E7EB)),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: _changeLanguage,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        offset: const Offset(0, 44),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(t['flag']!, style: const TextStyle(fontSize: 16)),
                              const SizedBox(width: 8),
                              Text(
                                t['label']!,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF374151),
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.language_rounded, color: Color(0xFFC8102E), size: 20),
                            ],
                          ),
                        ),
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'JA', child: Text('🇯🇵 日本語')),
                          const PopupMenuItem(value: 'EN', child: Text('🇺🇸 English')),
                          const PopupMenuItem(value: 'KO', child: Text('🇰🇷 한국어')),
                          const PopupMenuItem(value: 'ZH', child: Text('🇨🇳 中文')),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.asset(
                        'assets/moosensei_typing.jpg',
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: const Color(0xFFFDE8E8),
                            padding: const EdgeInsets.all(16),
                            child: const Center(
                              child: Text(
                                '🐷 assets/moosensei_typing.jpg\nが見つかりません',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFFC8102E),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  Text(
                    t['titleHeader']!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 24),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                        child: Text(
                          t['inputLabel']!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF374151),
                          ),
                        ),
                      ),
                      TextField(
                        controller: _userTextController,
                        onChanged: _onUserTextChanged,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFC8102E), width: 1.5),
                          ),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isTranslating)
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFC8102E)),
                                  ),
                                ),
                              if (_userTextController.text.isNotEmpty)
                                IconButton(
                                  icon: const Icon(Icons.cancel_rounded, color: Color(0xFF9CA3AF), size: 22),
                                  onPressed: _clearUserText,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // 【タイ語翻訳】カード（発音記号 ＆ お気に入り⭐ボタンを追加）
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                        child: Text(
                          t['translationHeader']!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF374151),
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            decoration: const BoxDecoration(
                              border: Border(
                                left: BorderSide(color: Color(0xFFC8102E), width: 6),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _translatedThai.isNotEmpty ? _translatedThai : '...',
                                        style: const TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF111827),
                                          height: 1.2,
                                        ),
                                      ),
                                      if (_phoneticText.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          _phoneticText,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF6B7280),
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                // 単語帳お気に入り（⭐）ボタン
                                IconButton(
                                  onPressed: _toggleSaveWord,
                                  icon: Icon(
                                    isSaved ? Icons.star_rounded : Icons.star_outline_rounded,
                                    color: isSaved ? const Color(0xFFF59E0B) : const Color(0xFF9CA3AF),
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // 音声再生ボタン
                                IconButton(
                                  onPressed: () => _speakThai(_translatedThai),
                                  icon: const Icon(Icons.volume_up_rounded, color: Color(0xFFA81B34), size: 28),
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFFFDE8E8),
                                    padding: const EdgeInsets.all(10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                        child: Text(
                          t['typeLabel']!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF374151),
                          ),
                        ),
                      ),
                      TextField(
                        controller: _thaiInputController,
                        onChanged: _checkInput,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                        decoration: InputDecoration(
                          hintText: t['typeHint'],
                          hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: !hasInput
                                  ? const Color(0xFFD1D5DB)
                                  : (_isCorrect ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                              width: hasInput ? 2 : 1,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: !hasInput
                                  ? const Color(0xFFD1D5DB)
                                  : (_isCorrect ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                              width: hasInput ? 2 : 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: !hasInput
                                  ? const Color(0xFFC8102E)
                                  : (_isCorrect ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                              width: 1.5,
                            ),
                          ),
                          suffixIcon: !hasInput
                              ? null
                              : (_isCorrect
                                  ? const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 26)
                                  : const Icon(Icons.cancel_rounded, color: Color(0xFFEF4444), size: 26)),
                        ),
                      ),
                    ],
                  ),

                  if (hasInput) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: _isCorrect ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isCorrect ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA),
                        ),
                      ),
                      child: Text(
                        _isCorrect ? t['correctMsg']! : t['incorrectMsg']!,
                        style: TextStyle(
                          color: _isCorrect ? const Color(0xFF047857) : const Color(0xFFDC2626),
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}