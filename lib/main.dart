import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:collection';

// Couleurs Batman
const batBlack = Color(0xFF050505);
const batDarkGrey = Color(0xFF121212);
const batMidGrey = Color(0xFF1E1E1E);
const batLightGrey = Color(0xFF2A2A2A);
const batYellow = Color(0xFFF2C200);
const batRed = Color(0xFFB00020);

// Nom du modèle utilisé
const String modelName = "Gemma 3n E2B";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialiser les notifications locales
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );

  // 2. DEMANDER LA PERMISSION DE NOTIFIER (Requis par Android 13+)
  final bool? granted = await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  // 3. Créer le canal de notification
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'alfred_service',
    'ALFRED Service',
    description: 'Notifications du service en arrière-plan ALFRED',
    importance: Importance.low,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  // 4. Démarrer le service en arrière-plan
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

// --- FONCTION DU SERVICE EN ARRIÈRE-PLAN (Le vrai cerveau) ---
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  LiteLmEngine? engine;
  LiteLmConversation? conversation;
  bool isModelLoaded = false;
  String loadingError = "";

  // Fonction pour charger le modèle
  Future<void> initModel() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) throw Exception("Stockage inaccessible.");
      final file = File('${dir.path}/gemma-4-E2B-it.litertlm');

      if (!await file.exists()) {
        throw Exception("Modèle introuvable dans ${dir.path}");
      }

      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/litert_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: file.path,
          backend: LiteLmBackend.gpu,
          cacheDir: cacheDir.path,
          audioBackend: LiteLmBackend.cpu,
          maxNumTokens: 2048,
        ),
      );

      conversation = await engine?.createConversation(
        LiteLmConversationConfig(
          systemInstruction: "Tu es ALFRED, un majordome. Tu es poli et devoue. Tu appelles l'utilisateur 'Monsieur'.",
          samplerConfig: LiteLmSamplerConfig(temperature: 0.7, topK: 40, topP: 0.9),
        ),
      );
      isModelLoaded = true;
      service.invoke('model_loaded');
    } catch (e) {
      loadingError = e.toString();
      service.invoke('model_error', {'error': loadingError});
    }
  }

  // Lancer le chargement au démarrage du service
  await initModel();

  // Surveiller la RAM toutes les 2 secondes
  Timer.periodic(const Duration(seconds: 2), (timer) {
    final usedRamMb = (ProcessInfo.currentRss / (1024 * 1024)).round();
    service.invoke('ram_update', {'used': usedRamMb});
  });

  // Écouter les requêtes de l'interface
  service.on('check_status').listen((event) {
    if (isModelLoaded) service.invoke('model_loaded');
    else if (loadingError.isNotEmpty) service.invoke('model_error', {'error': loadingError});
  });

  service.on('send_message').listen((event) async {
    if (conversation == null) return;
    final prompt = event?['prompt'] as String;
    final audioPath = event?['audioPath'] as String?;

    // On retient si l'utilisateur a parlé
    bool isAudioMessage = audioPath != null;

    final contents = [
      LiteLmContent.text(prompt),
      if (audioPath != null) LiteLmContent.audioFile(audioPath),
    ];

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
      service.invoke('generation_done');
    });
  });
}

// --- GESTIONNAIRE DE MÉMOIRE ---
class ServerManager {
  final String _serverUrl = "http://100.74.55.124:8000";
  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3)));

  Future<Map<String, dynamic>> checkServerAndGetMemory() async {
    try {
      final response = await _dio.get('$_serverUrl/get_memory');
      if (response.statusCode == 200) {
        return {"online": true, "memory": response.data.toString()};
      }
    } catch (e) {
      return {"online": false, "memory": "Mémoire de secours (hors-ligne)."};
    }
    return {"online": false, "memory": "Aucune mémoire."};
  }
}

// --- ÉCRAN PRINCIPAL ---
class AlfredApp extends StatelessWidget {
  const AlfredApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ALFRED',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: batBlack,
        colorScheme: const ColorScheme.dark(primary: batYellow, surface: batDarkGrey),
        appBarTheme: const AppBarTheme(backgroundColor: batBlack, elevation: 0),
      ),
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
  final FlutterTts _flutterTts = FlutterTts();
  bool _isSpeaking = false;

  bool _shouldSpeakResponse = false;
  int _queuedTextLength = 0; // Remplace _ttsBuffer par la longueur du texte mis en file
  final Queue<String> _ttsQueue = Queue<String>(); // La file d'attente des phrases

  bool _isModelLoading = true;
  bool _isGenerating = false;
  bool _isRecording = false;
  bool _isServerOnline = false;
  String _loadingStatus = "Connexion au Batcave...";

  int _usedRamMb = 0;
  final int _totalRamMb = 8192; // 8 Go

  late FlutterBackgroundService _service;

  @override
  void initState() {
    super.initState();
    _service = FlutterBackgroundService();
    _initTts();
    _connectToService();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("fr-FR");
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setPitch(0.8);

    // Recherche de voix masculine (garde celle que tu as trouvée manuellement si le code la trouve)
    List<dynamic> voices = await _flutterTts.getVoices;
    for (var voice in voices) {
      String voiceStr = voice.toString().toLowerCase();
      if (voiceStr.contains('fr') && (voiceStr.contains('male') || voiceStr.contains('homme'))) {
        await _flutterTts.setVoice(voice);
        break;
      }
    }

    _flutterTts.setStartHandler(() {
      setState(() => _isSpeaking = true);
    });

    // Quand il finit de lire une phrase, on lui demande de lire la suivante dans la file
    _flutterTts.setCompletionHandler(() {
      if (_ttsQueue.isNotEmpty) {
        String nextSentence = _ttsQueue.removeFirst();
        _flutterTts.speak(nextSentence);
      } else {
        setState(() => _isSpeaking = false);
      }
    });
  }

  void _addToTtsQueue(String sentence) {
    if (sentence.trim().isEmpty) return;

    if (!_isSpeaking && _ttsQueue.isEmpty) {
      // Si personne ne parle, on lance directement la phrase
      setState(() => _isSpeaking = true);
      _flutterTts.speak(sentence);
    } else {
      // Sinon, on la met dans la file d'attente
      _ttsQueue.add(sentence);
    }
  }

  void _connectToService() {
    // Écouter les mises à jour du service en arrière-plan
    _service.on('model_loaded').listen((event) {
      setState(() {
        _isModelLoading = false;
        _messages.add({"role": "alfred", "text": "Bonjour Monsieur. Système activé. Je suis à votre écoute.", "tps": 0});
      });
    });

    _service.on('model_error').listen((event) {
      setState(() {
        _isModelLoading = false;
        _loadingStatus = "Erreur: ${event?['error']}";
      });
    });

    _service.on('ram_update').listen((event) {
      setState(() {
        _usedRamMb = event?['used'] ?? 0;
      });
    });

    _service.on('new_token').listen((event) async {
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

            if (lastEnd != -1 && lastEnd >= _queuedTextLength) {
              // On extrait la ou les nouvelles phrases complètes
              String newSentences = currentText.substring(_queuedTextLength, lastEnd + 1);
              _queuedTextLength = lastEnd + 1;

              String cleanSentences = newSentences.replaceAll('*', '').replaceAll('#', '').trim();
              if (cleanSentences.isNotEmpty) {
                _addToTtsQueue(cleanSentences);
              }
            }
          }
        }
      }
    });

    _service.on('generation_done').listen((event) async {
      setState(() => _isGenerating = false);

      if (_shouldSpeakResponse && _messages.isNotEmpty) {
        String finalText = _messages.last['text'] ?? "";
        if (finalText.length > _queuedTextLength) {
          String remainingText = finalText.substring(_queuedTextLength);
          _queuedTextLength = finalText.length;
          String cleanRemaining = remainingText.replaceAll('*', '').replaceAll('#', '').trim();
          if (cleanRemaining.isNotEmpty) {
            _addToTtsQueue(cleanRemaining);
          }
        }
      }
      _shouldSpeakResponse = false;
    });

    _service.on('generation_error').listen((event) {
      setState(() {
        if (_messages.isNotEmpty) _messages[_messages.length - 1]['text'] = "Erreur: ${event?['error']}";
        _isGenerating = false;
      });
    });

    // Demander l'état actuel au service
    _service.invoke('check_status');
  }

  Future<void> _sendMessage({String? audioPath}) async {
    _flutterTts.stop();
    _ttsQueue.clear(); // On vide la file d'attente
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
    final memory = serverData['memory'];
    final promptText = "Memoire: $memory\n\nQuestion: $userText";

    _service.invoke('send_message', {'prompt': promptText, 'audioPath': audioPath});
  }

  void _stopGeneration() {
    _service.invoke('stop_generation');
    _flutterTts.stop();
    _ttsQueue.clear(); // On vide la file si on coupe la parole
    setState(() => _isSpeaking = false);
  }

  Future<void> _toggleRecording() async {
    if (_isGenerating) return;

    if (_isRecording) {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        _sendMessage(audioPath: path);
      }
    } else {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        // On change .m4a en .wav
        final path = '${tempDir.path}/alfred_voice.wav';

        // On force la configuration audio (16kHz, Mono, PCM)
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: path,
        );
        setState(() => _isRecording = true);
      }
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
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
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
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
            Text(_loadingStatus, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildChatScreen() {
    double ramPercent = (_usedRamMb / _totalRamMb) * 100;
    double usedRamGb = _usedRamMb / 1024;
    double totalRamGb = _totalRamMb / 1024;

    return Column(
      children: [
        // Barre RAM
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          color: batDarkGrey,
          child: Row(
            children: [
              const Icon(Icons.memory, size: 16, color: Colors.grey),
              const SizedBox(width: 10),
              Expanded(
                child: LinearProgressIndicator(
                  value: (ramPercent / 100).clamp(0.0, 1.0),
                  backgroundColor: batMidGrey,
                  color: ramPercent > 80 ? batRed : batYellow,
                  minHeight: 5,
                ),
              ),
              const SizedBox(width: 10),
              Text("${usedRamGb.toStringAsFixed(1)}GB / ${totalRamGb.toStringAsFixed(1)}GB (${ramPercent.toStringAsFixed(0)}%)", style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ),
        ),

        // Messages
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(15),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final isUser = msg['role'] == 'user';
              return Align(
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 15),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.80),
                  decoration: BoxDecoration(
                    color: isUser ? batLightGrey : batMidGrey,
                    borderRadius: BorderRadius.circular(8),
                    border: isUser ? null : Border.all(color: batLightGrey, width: 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownBody(
                        data: msg['text']!,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                          // Les mots en **gras** seront en jaune Batman !
                          strong: const TextStyle(color: batYellow, fontWeight: FontWeight.bold),
                          // Les mots en *italique* seront en gris clair
                          em: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                        ),
                      ),
                      if (!isUser && msg['tps'] > 0 && (index == _messages.length - 1 && _isGenerating))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text("${msg['tps']} tok/s", style: const TextStyle(color: batYellow, fontSize: 10, fontWeight: FontWeight.bold)),
                        )
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Zone de saisie
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(color: batDarkGrey, border: Border(top: BorderSide(color: batMidGrey, width: 1))),
          child: Row(
            children: [
              // 1. Bouton Micro (Gauche)
              GestureDetector(
                onTap: _toggleRecording,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: _isRecording ? batRed : batLightGrey, shape: BoxShape.circle),
                  child: Icon(_isRecording ? Icons.stop : Icons.mic, color: _isRecording ? Colors.white : batYellow, size: 20),
                ),
              ),
              const SizedBox(width: 10),

              // 2. Champ Texte (Centre)
              Expanded(
                child: TextField(
                  controller: _inputController,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Écrivez...",
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: batMidGrey,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 10),

              // 3. Bouton Action (Droite : Envoyer / Stop / Couper Voix)
              GestureDetector(
                onTap: () {
                  if (_isSpeaking) {
                    _flutterTts.stop();
                    setState(() => _isSpeaking = false);
                  } else if (_isGenerating) {
                    _stopGeneration();
                  } else {
                    _sendMessage();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: _isSpeaking ? batYellow : (_isGenerating ? batRed : batYellow),
                      shape: BoxShape.circle
                  ),
                  child: Icon(
                      _isSpeaking ? Icons.volume_up : (_isGenerating ? Icons.stop : Icons.send),
                      color: batBlack,
                      size: 20
                  ),
                ),
              ),
            ],
          ),
        )
      ],
    );
  }
}