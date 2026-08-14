import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

// Couleurs Batman
const batBlack = Color(0xFF050505);
const batDarkGrey = Color(0xFF121212);
const batMidGrey = Color(0xFF1E1E1E);
const batLightGrey = Color(0xFF2A2A2A);
const batYellow = Color(0xFFF2C200);
const batRed = Color(0xFFB00020);

void main() {
  runApp(const AlfredApp());
}

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
        colorScheme: const ColorScheme.dark(
          primary: batYellow,
          surface: batDarkGrey,
        ),
        appBarTheme: const AppBarTheme(backgroundColor: batBlack, elevation: 0),
      ),
      home: const ChatScreen(),
    );
  }
}

// --- GESTIONNAIRE DE MÉMOIRE & SERVEUR ---
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

  bool _isModelLoading = true;
  bool _isGenerating = false;
  bool _isRecording = false;
  bool _isServerOnline = false;
  bool _isPhoneOnline = true; // À simplifier, on suppose true si on n'attrape pas l'erreur

  double _loadingProgress = 0.0;
  String _loadingStatus = "Initialisation...";

  // Métriques
  int _currentTps = 0;
  int _totalRamMb = 0;
  int _usedRamMb = 0;
  Timer? _ramTimer;

  // Modèle
  final String _modelName = "Gemma 3n E4B"; // Change en E2B quand tu changeras de modèle
  LiteLmEngine? _engine;
  LiteLmConversation? _conversation;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _initModel();
    _startRamTracker();
  }

  void _startRamTracker() {
    _ramTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isModelLoading) return;
      final info = ProcessInfo.currentRss; // RAM utilisée par l'app en bytes
      setState(() {
        _usedRamMb = (info / (1024 * 1024)).round();
      });
    });
  }

  Future<void> _initModel() async {
    try {
      setState(() { _loadingStatus = "Connexion au Batcave..."; _loadingProgress = 0.1; });
      final serverData = await _serverManager.checkServerAndGetMemory();
      _isServerOnline = serverData['online'];

      setState(() { _loadingStatus = "Extraction du cerveau..."; _loadingProgress = 0.3; });
      final modelPath = await _copyAssetToCache('gemma-4-E2B-it.litertlm');

      // Nothing Phone 1 a 8Go de vraie RAM physique.
      // On fixe la limite à 8Go pour éviter d'utiliser la RAM virtuelle (qui ferait crasher l'IA).
      _totalRamMb = 8192;

      setState(() { _loadingStatus = "Allumage du moteur GPU LiteRT..."; _loadingProgress = 0.5; });
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/litert_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      _engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: modelPath,
          backend: LiteLmBackend.gpu,
          cacheDir: cacheDir.path,
          maxNumTokens: 2048,
        ),
      );

      setState(() { _loadingStatus = "Configuration d'ALFRED..."; _loadingProgress = 0.8; });
      _conversation = await _engine?.createConversation(
        LiteLmConversationConfig(
          systemInstruction: "Tu es ALFRED, un majordome. Tu es poli et devoue. Tu appelles l'utilisateur 'Monsieur'.",
          samplerConfig: LiteLmSamplerConfig(temperature: 0.7, topK: 40, topP: 0.9),
        ),
      );

      setState(() { _loadingStatus = "Système prêt."; _loadingProgress = 1.0; });
      await Future.delayed(const Duration(milliseconds: 500));

      setState(() {
        _messages.add({"role": "alfred", "text": "Bonjour Monsieur. Système mobile activé. Je suis à votre écoute.", "tps": 0});
        _isModelLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add({"role": "alfred", "text": "Erreur critique: $e", "tps": 0});
        _isModelLoading = false;
      });
    }
  }

  Future<String> _copyAssetToCache(String assetName) async {
    // On va chercher le dossier de stockage externe de l'app
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw Exception("Impossible d'accéder au stockage.");

    final file = File('${dir.path}/$assetName');

    // Si le modèle est déjà là, on le charge !
    if (await file.exists()) {
      return file.path;
    }

    // Sinon, on lève une erreur très claire pour dire à l'utilisateur quoi faire
    throw Exception(
        "Modèle introuvable.\n\n"
            "Veuillez copier manuellement le fichier '$assetName' dans le dossier :\n"
            "${dir.path}\n\n"
            "Puis relancez l'application."
    );
  }

  Future<void> _sendMessage({String? audioPath}) async {
    final userText = _inputController.text.trim();
    if ((userText.isEmpty && audioPath == null) || _isGenerating || _conversation == null) return;

    setState(() {
      if (userText.isNotEmpty) _messages.add({"role": "user", "text": userText, "tps": 0});
      if (audioPath != null) _messages.add({"role": "user", "text": "🎙️ (Audio)", "tps": 0});

      _inputController.clear();
      _isGenerating = true;
      _currentTps = 0;
      _messages.add({"role": "alfred", "text": "", "tps": 0}); // Message vide pour le streaming
    });

    try {
      final serverData = await _serverManager.checkServerAndGetMemory();
      final memory = serverData['memory'];
      final promptText = "Memoire: $memory\n\nQuestion: $userText";

      final buffer = StringBuffer();
      int currentMsgIndex = _messages.length - 1;
      int tokenCount = 0;
      DateTime startTime = DateTime.now();

      final contents = [
        LiteLmContent.text(promptText),
        if (audioPath != null) LiteLmContent.audioFile(audioPath),
      ];

      _subscription = _conversation!.sendMultimodalMessageStream(contents).listen(
            (delta) {
          final text = delta.text;
          if (text.isNotEmpty) {
            buffer.write(text);
            tokenCount++;

            // Calcul des tokens/s
            final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
            if (elapsedMs > 0) {
              _currentTps = (tokenCount / (elapsedMs / 1000)).round();
            }

            setState(() {
              _messages[currentMsgIndex]['text'] = buffer.toString();
              _messages[currentMsgIndex]['tps'] = _currentTps;
            });
          }
        },
        onDone: () => setState(() => _isGenerating = false),
        onError: (e) {
          setState(() {
            _messages[currentMsgIndex]['text'] = "Erreur: $e";
            _isGenerating = false;
          });
        },
      );
    } catch (e) {
      setState(() {
        _messages.add({"role": "alfred", "text": "Erreur: $e", "tps": 0});
        _isGenerating = false;
      });
    }
  }

  void _stopGeneration() {
    _subscription?.cancel();
    setState(() => _isGenerating = false);
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
        final path = '${tempDir.path}/alfred_voice.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() => _isRecording = true);
      }
    }
  }

  @override
  void dispose() {
    _ramTimer?.cancel();
    _subscription?.cancel();
    _conversation?.dispose();
    _engine?.dispose();
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

  // --- APP BAR ---
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
            child: Text(_modelName, style: const TextStyle(color: Colors.grey, fontSize: 10)),
          ),
        ],
      ),
      actions: [
        // Indicateur Serveur (Batcave)
        Tooltip(
          message: _isServerOnline ? "Serveur Batcave Connecté" : "Serveur Hors-ligne",
          child: Icon(
            _isServerOnline ? Icons.cloud_done : Icons.cloud_off,
            color: _isServerOnline ? batYellow : batRed,
            size: 20,
          ),
        ),
        const SizedBox(width: 15),
      ],
    );
  }

  // --- ÉCRAN DE CHARGEMENT ---
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
            LinearProgressIndicator(
              value: _loadingProgress,
              backgroundColor: batMidGrey,
              color: batYellow,
              minHeight: 4,
            ),
            const SizedBox(height: 20),
            Text(_loadingStatus, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            const SizedBox(height: 5),
            Text("${(_loadingProgress * 100).toInt()}%", style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // --- ÉCRAN DE DISCUSSION ---
  Widget _buildChatScreen() {
    double ramPercent = _totalRamMb > 0 ? (_usedRamMb / _totalRamMb) * 100 : 0;
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
                      // On remplace Text par SelectableText
                      SelectableText(
                        msg['text']!,
                        style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                        cursorColor: batYellow, // Le curseur sera jaune Batman
                        toolbarOptions: const ToolbarOptions(copy: true, selectAll: true),
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
              // Bouton Micro
              GestureDetector(
                onTap: _toggleRecording,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: _isRecording ? batRed : batLightGrey, shape: BoxShape.circle),
                  child: Icon(_isRecording ? Icons.stop : Icons.mic, color: _isRecording ? Colors.white : batYellow, size: 20),
                ),
              ),
              const SizedBox(width: 10),
              // Champ texte
              Expanded(
                child: TextField(
                  controller: _inputController,
                  textCapitalization: TextCapitalization.sentences, // Majuscule au début
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
              // Bouton Envoyer / Stop
              GestureDetector(
                onTap: _isGenerating ? _stopGeneration : () => _sendMessage(),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: _isGenerating ? batRed : batYellow, shape: BoxShape.circle),
                  child: Icon(_isGenerating ? Icons.stop : Icons.send, color: batBlack, size: 20),
                ),
              ),
            ],
          ),
        )
      ],
    );
  }
}