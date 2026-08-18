import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:archive/archive.dart';


// Couleurs Batman
const batBlack = Color(0xFF050505);
const batDarkGrey = Color(0xFF121212);
const batMidGrey = Color(0xFF1E1E1E);
const batLightGrey = Color(0xFF2A2A2A);
const batYellow = Color(0xFFF2C200);
const batRed = Color(0xFFB00020);
const String modelName = "Gemma 3n E2B";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Notifications & Service Immortel
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  const AndroidNotificationChannel channel = AndroidNotificationChannel('alfred_service', 'ALFRED Service', description: 'Service Batcave', importance: Importance.low);
  await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'alfred_service',
      initialNotificationTitle: 'ALFRED',
      initialNotificationContent: 'Système en veille',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
  await service.startService();

  runApp(const AlfredApp());
}

// --- SERVICE EN ARRIÈRE-PLAN (GEMMA - MODE IMMORTEL) ---
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  LiteLmEngine? engine;
  LiteLmConversation? conversation;
  bool isModelLoaded = false;

  Future<void> initModel() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) throw Exception("Stockage inaccessible.");
      final file = File('${dir.path}/gemma-4-E2B-it.litertlm');
      if (!await file.exists()) throw Exception("Modèle introuvable dans ${dir.path}");

      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/litert_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      engine = await LiteLmEngine.create(LiteLmEngineConfig(
        modelPath: file.path, backend: LiteLmBackend.gpu, audioBackend: LiteLmBackend.cpu, cacheDir: cacheDir.path, maxNumTokens: 2048,
      ));
      conversation = await engine?.createConversation(LiteLmConversationConfig(
        systemInstruction: "Tu es ALFRED, un majordome. Tu es poli et devoue. Tu appelles l'utilisateur 'Monsieur'.",
        samplerConfig: LiteLmSamplerConfig(temperature: 0.7, topK: 40, topP: 0.9),
      ));
      isModelLoaded = true;
      service.invoke('model_loaded');
    } catch (e) {
      service.invoke('model_error', {'error': e.toString()});
    }
  }

  await initModel();
  Timer.periodic(const Duration(seconds: 2), (timer) {
    final usedRamMb = (ProcessInfo.currentRss / (1024 * 1024)).round();
    service.invoke('ram_update', {'used': usedRamMb});
  });

  service.on('check_status').listen((event) {
    if (isModelLoaded) service.invoke('model_loaded');
  });

  service.on('send_message').listen((event) async {
    if (conversation == null) return;
    final prompt = event?['prompt'] as String;
    final audioPath = event?['audioPath'] as String?;
    bool isAudioMessage = audioPath != null;

    final contents = [LiteLmContent.text(prompt), if (audioPath != null) LiteLmContent.audioFile(audioPath)];
    final buffer = StringBuffer();
    int tokenCount = 0;
    DateTime startTime = DateTime.now();

    final subscription = conversation!.sendMultimodalMessageStream(contents).listen(
          (delta) {
        final text = delta.text;
        if (text.isNotEmpty) {
          buffer.write(text);
          tokenCount++;
          final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
          final tps = elapsedMs > 0 ? (tokenCount / (elapsedMs / 1000)).round() : 0;
          service.invoke('new_token', {'text': buffer.toString(), 'tps': tps});
        }
      },
      onDone: () => service.invoke('generation_done', {'speak': isAudioMessage}),
      onError: (e) => service.invoke('generation_error', {'error': e.toString()}),
    );

    service.on('stop_generation').listen((event) {
      subscription.cancel();
      service.invoke('generation_done', {'speak': false});
    });
  });
}

// --- SERVICE SHERPA-ONNX (Voix réaliste hors-ligne) ---
class SherpaTtsService {
  final AudioPlayer _player = AudioPlayer(playerId: "alfred_voice");
  sherpa_onnx.OfflineTts? _tts;
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      // INITIALISATION OBLIGATOIRE DES PONTS NATIFS
      sherpa_onnx.initBindings();

      // On récupère le dossier de stockage externe
      final dir = await getExternalStorageDirectory();
      if (dir == null) throw Exception("Stockage inaccessible.");

      final modelPath = await _copySingleAsset('tts/fr_FR-tom-medium.onnx', 'fr_FR-tom-medium.onnx');
      final tokensPath = await _copySingleAsset('tts/tokens.txt', 'tokens.txt');
      final dataDirPath = await _copyEspeakDataDir();

      final config = sherpa_onnx.OfflineTtsConfig(
        model: sherpa_onnx.OfflineTtsModelConfig(
          vits: sherpa_onnx.OfflineTtsVitsModelConfig(
            model: modelPath, tokens: tokensPath, dataDir: dataDirPath,
          ),
        ),
      );

      _tts = sherpa_onnx.OfflineTts(config);
      _isInitialized = true;
      debugPrint("[TTS] Sherpa-Onnx initialisé avec succès (fr_FR-tom-medium) !");
    } catch (e) {
      debugPrint("[TTS] Erreur init TTS: $e");
    }
  }

  // Petite fonction utilitaire pour copier juste le .onnx et le .txt
  Future<String> _copySingleAsset(String assetPath, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) {
      final byteData = await rootBundle.load('assets/$assetPath');
      await file.writeAsBytes(byteData.buffer.asUint8List());
    }
    return file.path;
  }

  // Dézippe espeak-ng-data.zip depuis les assets
  Future<String> _copyEspeakDataDir() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw Exception("Stockage inaccessible.");
    final targetDir = Directory('${dir.path}/espeak-ng-data');
    
    // Vérifie les fichiers CLÉS (pas juste le dossier)
    final frDict = File('${targetDir.path}/fr_dict');
    final phontab = File('${targetDir.path}/phontab');
    final frenchVoice = File('${targetDir.path}/voices/!v/fr');
    bool needsExtract = !await targetDir.exists() || !await frDict.exists() || !await phontab.exists();
    
    if (needsExtract) {
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
        debugPrint("[TTS] espeak-ng-data incomplet, ré-extraction...");
      }
      await targetDir.create(recursive: true);
      // Charge et extrait le zip
      final byteData = await rootBundle.load('assets/tts/espeak-ng-data.zip');
      final bytes = byteData.buffer.asUint8List();
      debugPrint("[TTS] Zip size: ${bytes.length} bytes");
      final archive = ZipDecoder().decodeBytes(bytes);
      debugPrint("[TTS] Archive entries: ${archive.files.length}");
      for (final file in archive) {
        final targetFile = File('${targetDir.path}/${file.name}');
        if (file.isFile) {
          await targetFile.parent.create(recursive: true);
          await targetFile.writeAsBytes(file.content as List<int>);
        } else if (file.isDirectory) {
          await targetFile.create(recursive: true);
        }
      }
      debugPrint("[TTS] espeak-ng-data extrait: ${archive.files.length} fichiers");
    } else {
      debugPrint("[TTS] espeak-ng-data déjà complet");
    }
    
    // CRÉE le fichier voix français manquant pour espeak-ng
    if (!await frenchVoice.exists()) {
      await frenchVoice.parent.create(recursive: true);
      const voiceContent = 'name fr\nlanguage fr\n';
      await frenchVoice.writeAsString(voiceContent);
      debugPrint("[TTS] Fichier voix français créé: voices/!v/fr");
    }
    
    // Vérification finale
    debugPrint("[TTS] fr_dict exists: ${await frDict.exists()}");
    debugPrint("[TTS] phontab exists: ${await phontab.exists()}");
    debugPrint("[TTS] voices/!v/fr exists: ${await frenchVoice.exists()}");
    return targetDir.path;
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty || _tts == null) return;
    try {
      // silenceScale: 0.05 = pauses très courtes (défaut 0.2)
      final audio = _tts!.generateWithConfig(
        text: text,
        config: sherpa_onnx.OfflineTtsGenerationConfig(sid: 0, speed: 1.25, silenceScale: 0.05),
      );

      if (audio.samples.isEmpty) {
        debugPrint("[TTS] Erreur: L'IA n'a pas généré d'audio.");
        return;
      }

      // Pitch shift vers le bas (facteur < 1 = plus grave)
      // 0.92 ≈ -1.5 demi-tons, naturel sans artefacts majeurs
      final shiftedSamples = _pitchShift(audio.samples, 0.92);

      final pcmBytes = _convertFloat32ToPCM16(shiftedSamples);
      final wavBytes = _addWavHeader(pcmBytes, audio.sampleRate);

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/alfred_sherpa.wav');
      await file.writeAsBytes(wavBytes);
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      debugPrint("[TTS] Erreur speak TTS: $e");
    }
  }

  // Pitch shift simple par rééchantillonnage linéaire
  // factor < 1 = plus grave, factor > 1 = plus aigu
  Float32List _pitchShift(Float32List input, double factor) {
    if (factor == 1.0) return input;
    final newLength = (input.length / factor).round();
    final output = Float32List(newLength);
    for (int i = 0; i < newLength; i++) {
      final srcPos = i * factor;
      final idx = srcPos.floor();
      final frac = srcPos - idx;
      if (idx + 1 < input.length) {
        output[i] = input[idx] * (1 - frac) + input[idx + 1] * frac;
      } else if (idx < input.length) {
        output[i] = input[idx];
      }
    }
    return output;
  }

  Uint8List _convertFloat32ToPCM16(Float32List floatSamples) {
    final pcmBytes = Uint8List(floatSamples.length * 2);
    for (int i = 0; i < floatSamples.length; i++) {
      int value = (floatSamples[i] * 32767).clamp(-32768, 32767).toInt();
      pcmBytes[i * 2] = value & 0xFF;
      pcmBytes[i * 2 + 1] = (value >> 8) & 0xFF;
    }
    return pcmBytes;
  }

  Uint8List _addWavHeader(Uint8List pcmData, int sampleRate) {
    final dataSize = pcmData.length;
    final buffer = ByteData(44 + dataSize);
    buffer.setUint32(0, 0x52494646, Endian.big); buffer.setUint32(4, 36 + dataSize, Endian.little); buffer.setUint32(8, 0x57415645, Endian.big);
    buffer.setUint32(12, 0x666d7420, Endian.big); buffer.setUint32(16, 16, Endian.little); buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little); buffer.setUint32(24, sampleRate, Endian.little); buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little); buffer.setUint16(34, 16, Endian.little); buffer.setUint32(36, 0x64617461, Endian.big);
    buffer.setUint32(40, dataSize, Endian.little);
    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(44, 44 + dataSize, pcmData);
    return bytes;
  }

  Future<void> stop() async { await _player.stop(); }
  void setCompletionHandler(void Function() onComplete) { _player.onPlayerComplete.listen((_) { onComplete(); }); }
}

// --- GESTIONNAIRE DE MÉMOIRE ---
class ServerManager {
  final String _serverUrl = "http://100.74.55.124:8000";
  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3)));
  Future<Map<String, dynamic>> checkServerAndGetMemory() async {
    try {
      final response = await _dio.get('$_serverUrl/get_memory');
      if (response.statusCode == 200) return {"online": true, "memory": response.data.toString()};
    } catch (e) { return {"online": false, "memory": "Mémoire de secours (hors-ligne)."}; }
    return {"online": false, "memory": "Aucune mémoire."};
  }
}

// --- APP & UI ---
class AlfredApp extends StatelessWidget {
  const AlfredApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ALFRED', debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: batBlack, colorScheme: const ColorScheme.dark(primary: batYellow, surface: batDarkGrey), appBarTheme: const AppBarTheme(backgroundColor: batBlack, elevation: 0)),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final ServerManager _serverManager = ServerManager();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final SherpaTtsService _sherpaTts = SherpaTtsService();
  late FlutterBackgroundService _service;

  bool _isModelLoading = true;
  bool _isGenerating = false;
  bool _isRecording = false;
  bool _isServerOnline = false;
  bool _isSpeaking = false;
  bool _shouldSpeakResponse = false;
  int _queuedTextLength = 0;
  final Queue<String> _ttsQueue = Queue<String>();
  int _usedRamMb = 0;
  final int _totalRamMb = 8192;
  Timer? _ramTimer;

  @override
  void initState() {
    super.initState();
    _service = FlutterBackgroundService();
    _initTts();
    _connectToService();
    _startRamTracker();
  }

  void _startRamTracker() {
    _ramTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isModelLoading) return;
      final info = ProcessInfo.currentRss;
      setState(() => _usedRamMb = (info / (1024 * 1024)).round());
    });
  }

  Future<void> _initTts() async {
    await _sherpaTts.init();
    _sherpaTts.setCompletionHandler(() {
      if (_ttsQueue.isNotEmpty) {
        String next = _ttsQueue.removeFirst();
        _sherpaTts.speak(next);
      } else {
        setState(() => _isSpeaking = false);
      }
    });
  }

  void _connectToService() {
    _service.on('model_loaded').listen((event) {
      setState(() {
        _isModelLoading = false;
        _messages.add({"role": "alfred", "text": "Bonjour Monsieur. Système mobile activé. Je suis à votre écoute.", "tps": 0});
      });
    });
    _service.on('model_error').listen((event) {
      setState(() { _isModelLoading = false; _messages.add({"role": "alfred", "text": "Erreur: ${event?['error']}", "tps": 0}); });
    });
    _service.on('ram_update').listen((event) { setState(() => _usedRamMb = event?['used'] ?? 0); });
    _service.on('new_token').listen((event) {
      if (_messages.isNotEmpty) {
        setState(() {
          _messages[_messages.length - 1]['text'] = event?['text'];
          _messages[_messages.length - 1]['tps'] = event?['tps'];
        });
        if (_shouldSpeakResponse) {
          String currentText = event?['text'] ?? "";
          if (currentText.length > _queuedTextLength) {
            int lastEnd = -1;
            
            for (var char in ['.', '!', '?', '\n']) {
              int idx = currentText.lastIndexOf(char);
              if (idx > lastEnd) lastEnd = idx;
            }
            // Enqueue seulement si: phrase complète ET (>=2 phrases OU fin de génération approximative)
            if (lastEnd != -1 && lastEnd >= _queuedTextLength) {
              String newSentences = currentText.substring(_queuedTextLength, lastEnd + 1);
              int sentenceCount = newSentences.split(RegExp(r'[.!?]')).where((s) => s.trim().isNotEmpty).length;
              bool isLikelyEnd = (currentText.length - lastEnd) < 50; // peu de texte restant
              
              if (sentenceCount >= 2 || isLikelyEnd) {
                _queuedTextLength = lastEnd + 1;
                String cleanSentences = _cleanTextForTTS(newSentences);
                if (cleanSentences.isNotEmpty) _addToTtsQueue(cleanSentences);
              }
            }
          }
        }
      }
    });
    _service.on('generation_done').listen((event) async {
      setState(() => _isGenerating = false);
      if (event?['speak'] == true && _messages.isNotEmpty) {
        String finalText = _messages.last['text'] ?? "";
        if (finalText.length > _queuedTextLength) {
          String remainingText = finalText.substring(_queuedTextLength);
          _queuedTextLength = finalText.length;

          // ON UTILISE LE VRAI FILTRE ICI AUSSI
          String cleanRemaining = _cleanTextForTTS(remainingText);

          if (cleanRemaining.isNotEmpty) _addToTtsQueue(cleanRemaining);
        }
      }
      _shouldSpeakResponse = false;
    });

    _service.on('generation_error').listen((event) {
      setState(() { if (_messages.isNotEmpty) _messages[_messages.length - 1]['text'] = "Erreur: ${event?['error']}"; _isGenerating = false; });
    });
    _service.invoke('check_status');
  }

  // Fonction pour nettoyer le Markdown et les caractères bizarres avant de l'envoyer à la voix
  String _cleanTextForTTS(String text) {
    // 1. Enlever les blocs de code (ex: ```python ... ```)
    text = text.replaceAll(RegExp(r'```.*?```', dotAll: true), '');
    // 2. Enlever le code en ligne (ex: `variable`)
    text = text.replaceAll(RegExp(r'`([^`]*)`'), '\$1');
    // 3. Enlever les liens Markdown (ex: [texte](url) -> texte)
    text = text.replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), '\$1');
    // 4. Enlever les symboles de formatage Markdown
    text = text.replaceAll(RegExp(r'[*_#>`~|-]'), '');
    // 5. Enlever les parenthèses et crochets isolés
    text = text.replaceAll(RegExp(r'[\[\]\(\)]'), '');
    // 6. Remplacer les multiples espaces/sauts de ligne par un seul espace
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  void _addToTtsQueue(String sentence) {
    if (sentence.trim().isEmpty) return;
    if (!_isSpeaking && _ttsQueue.isEmpty) {
      setState(() => _isSpeaking = true);
      _sherpaTts.speak(sentence);
    } else {
      _ttsQueue.add(sentence);
    }
  }

  Future<void> _sendMessage({String? audioPath}) async {
    _sherpaTts.stop();
    _ttsQueue.clear();
    _shouldSpeakResponse = (audioPath != null);
    _queuedTextLength = 0;

    final userText = _inputController.text.trim();
    if ((userText.isEmpty && audioPath == null) || _isGenerating) return;

    setState(() {
      if (userText.isNotEmpty) _messages.add({"role": "user", "text": userText, "tps": 0});
      if (audioPath != null) _messages.add({"role": "user", "text": "🎙️ (Audio)", "tps": 0});
      _inputController.clear();
      _isGenerating = true;
      _messages.add({"role": "alfred", "text": "", "tps": 0});
    });

    final serverData = await _serverManager.checkServerAndGetMemory();
    _isServerOnline = serverData['online'];
    final memory = serverData['memory'];
    final promptText = "Memoire: $memory\n\nQuestion: $userText";

    _service.invoke('send_message', {'prompt': promptText, 'audioPath': audioPath});
  }

  void _stopGeneration() {
    _service.invoke('stop_generation');
    _sherpaTts.stop();
    _ttsQueue.clear();
    setState(() { _isSpeaking = false; _isGenerating = false; });
  }

  Future<void> _toggleRecording() async {
    if (_isGenerating) return;
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) _sendMessage(audioPath: path);
    } else {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/alfred_voice.wav';
        await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);
        setState(() => _isRecording = true);
      }
    }
  }

  @override
  void dispose() {
    _ramTimer?.cancel();
    _audioRecorder.dispose();
    _sherpaTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: batBlack,
      appBar: _isModelLoading ? null : _buildAppBar(),
      body: _isModelLoading ? _buildLoadingScreen() : _buildChatScreen(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min,
        children: [
          const Text('ALFRED', style: TextStyle(color: batYellow, fontWeight: FontWeight.w900, letterSpacing: 4)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: batLightGrey, width: 1), borderRadius: BorderRadius.circular(4)),
            child: const Text(modelName, style: TextStyle(color: Colors.grey, fontSize: 10)),
          ),
        ],
      ),
      actions: [
        Tooltip(
          message: _isServerOnline ? "Serveur Connecté" : "Serveur Hors-ligne",
          child: Icon(_isServerOnline ? Icons.cloud_done : Icons.cloud_off, color: _isServerOnline ? batYellow : batRed, size: 20),
        ),
        const SizedBox(width: 15),
      ],
    );
  }

  Widget _buildLoadingScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.brightness_low, size: 80, color: batYellow),
            const SizedBox(height: 40),
            const Text('ALFRED', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 5, color: batYellow)),
            const SizedBox(height: 40),
            const CircularProgressIndicator(color: batYellow),
            const SizedBox(height: 20),
            Text("Initialisation du système...", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildChatScreen() {
    double ramPercent = (_usedRamMb / _totalRamMb) * 100;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8), color: batDarkGrey,
          child: Row(children: [
            const Icon(Icons.memory, size: 16, color: Colors.grey), const SizedBox(width: 10),
            Expanded(child: LinearProgressIndicator(value: (ramPercent / 100).clamp(0.0, 1.0), backgroundColor: batMidGrey, color: ramPercent > 80 ? batRed : batYellow, minHeight: 5)),
            const SizedBox(width: 10),
            Text("${(_usedRamMb / 1024).toStringAsFixed(1)}GB / ${(_totalRamMb / 1024).toStringAsFixed(1)}GB (${ramPercent.toStringAsFixed(0)}%)", style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(15), itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final isUser = msg['role'] == 'user';
              return Align(
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 15), padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.80),
                  decoration: BoxDecoration(color: isUser ? batLightGrey : batMidGrey, borderRadius: BorderRadius.circular(8), border: isUser ? null : Border.all(color: batLightGrey, width: 1)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownBody(
                        data: msg['text']!, selectable: true,
                        styleSheet: MarkdownStyleSheet(p: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4), strong: const TextStyle(color: batYellow, fontWeight: FontWeight.bold), em: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
                      ),
                      if (!isUser && msg['tps'] > 0 && (index == _messages.length - 1 && _isGenerating))
                        Padding(padding: const EdgeInsets.only(top: 8), child: Text("${msg['tps']} tok/s", style: const TextStyle(color: batYellow, fontSize: 10, fontWeight: FontWeight.bold)))
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(color: batDarkGrey, border: Border(top: BorderSide(color: batMidGrey, width: 1))),
          child: Row(children: [
            GestureDetector(
              onTap: _toggleRecording,
              child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: _isRecording ? batRed : batLightGrey, shape: BoxShape.circle), child: Icon(_isRecording ? Icons.stop : Icons.mic, color: _isRecording ? Colors.white : batYellow, size: 20)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _inputController, textCapitalization: TextCapitalization.sentences, style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(hintText: "Écrivez...", hintStyle: const TextStyle(color: Colors.grey), filled: true, fillColor: batMidGrey, contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none)),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () {
                if (_isSpeaking) { _sherpaTts.stop(); setState(() => _isSpeaking = false); }
                else if (_isGenerating) { _stopGeneration(); }
                else { _sendMessage(); }
              },
              child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: _isSpeaking ? batYellow : (_isGenerating ? batRed : batYellow), shape: BoxShape.circle), child: Icon(_isSpeaking ? Icons.volume_up : (_isGenerating ? Icons.stop : Icons.send), color: batBlack, size: 20)),
            ),
          ]),
        )
      ],
    );
  }
}