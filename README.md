# 🦇 ALFRED - Assistant IA Personnel

Un assistant IA vocal et textuel inspiré de JARVIS et du majordome de Batman. Construit de bout en bout sur des technologies locales, gratuites et open-source. ALFRED est capable de discuter par texte et par voix, d'utiliser des outils (heure, météo), de mémoriser des informations via Obsidian, et de fonctionner de n'importe où dans le monde.

## 🏗️ Architecture Globale

Le projet est divisé en trois parties distinctes : le Serveur (Mémoire & Cerveau de secours), le Réseau (Transport), et le Client Mobile (Cerveau principal & Interface).

*   **Serveur Central (Raspberry Pi 5)** : Héberge la mémoire à long terme (Obsidian/Markdown), un LLM de secours (Llama 3.2), et l'API. Tourne 24h/24 sous Raspberry Pi OS Lite + Docker.
*   **Réseau Privé (Tailscale)** : Crée un réseau mondial chiffré (VPN) reliant le Pi, le PC et le téléphone sans aucune configuration de routeur.
*   **Client Mobile (Flutter / Android)** : Une véritable application Android native. C'est le "Cerveau Principal". Elle fait tourner le modèle Gemma 3n E2B localement, gère la reconnaissance vocale, la synthèse vocale (Sherpa-Onnx), et l'interface graphique.

---

## 🛠️ Stack Technologique

**Serveur & Mémoire**
*   **Python 3** & **FastAPI** : API backend légère.
*   **Ollama** : Moteur d'exécution de LLM en local (modèle de secours).
*   **LangChain** : Framework pour lier l'IA à ses outils (Function Calling).
*   **Obsidian** : La mémoire à long terme est stockée sous forme de fichiers Markdown `.md`.

**Client Mobile (Flutter)**
*   **Flutter 3.x (Dart)** : Framework UI multiplateforme.
*   **flutter_litert_lm** : Moteur d'inférence local (Gemma 3n E2B) avec accélération GPU (Vulkan).
*   **sherpa_onnx** : Moteur de synthèse vocale (TTS) hors-ligne ultra-réaliste (Voix masculine "Tom").
*   **flutter_background_service** : Service de Premier Plan (Foreground Service) pour le mode "Immortel" (l'IA reste en RAM en permanence).
*   **record** & **audioplayers** : Capture du micro et lecture audio.

---

## 🔄 Comment tout est relié (Le Flux de Données)

1.  **Lancement de l'application** :
    *   Le `FlutterBackgroundService` démarre en arrière-plan (Mode Immortel). Il charge le modèle Gemma dans la RAM du téléphone via `flutter_litert_lm`.
    *   En parallèle, le thread principal initialise `sherpa_onnx` (Voix de Tom) et charge le dictionnaire `espeak-ng-data`.
2.  **Connexion au Batcave (Serveur)** :
    *   L'application envoie une requête via Tailscale à l'API FastAPI du Raspberry Pi (`/get_memory`).
    *   Si le Pi répond, l'icône Cloud passe en Jaune, et l'application télécharge la mémoire Obsidian.
    *   Si le Pi est éteint, l'application bascule en "Mode Hors-Ligne" avec une mémoire de secours locale.
3.  **Interaction Vocale** :
    *   L'utilisateur appuie sur le bouton Micro. L'audio est enregistré en `.wav` (16kHz, Mono).
    *   L'audio est envoyé au moteur Gemma (qui gère l'audio nativement).
    *   Gemma génère une réponse textuelle en streaming (mot par mot).
4.  **Synthèse Vocale (TTS)** :
    *   Dès qu'ALFRED finit une phrase (point, exclamation, etc.), le texte est nettoyé du Markdown et envoyé à `sherpa_onnx`.
    *   Sherpa-Onnx génère un fichier `.wav` localement (sans internet) et le joue via `audioplayers`. Les phrases s'empilent dans une file d'attente (Queue) pour ne pas se couper.

---

## ⚙️ Configuration Actuelle

- **Modèle IA (Téléphone)** : Gemma 3n E2B (`.litertlm`)
- **Modèle IA (Serveur)** : Llama 3.2 1B (Ollama)
- **Voix TTS** : Piper VITS (Voix masculine "Tom" - Medium)
- **RAM Téléphone** : Limitée à 8 Go (physique) pour éviter le crash sur l'extension de RAM virtuelle.

---

## 🚀 Installation et Démarrage

### 1. Le Serveur (Raspberry Pi)
Le serveur FastAPI expose une route `/get_memory` qui renvoie le contenu du dossier Obsidian, et une route `/chat` qui utilise Llama 3.2 avec des outils (heure, météo).

### 2. L'Application Mobile (Flutter)
```bash
flutter pub get
flutter run
```

**Fichiers nécessaires sur le téléphone (Nothing Phone 1) :**
L'application ne peut pas embarquer de gros fichiers dans ses `assets` (limite de 1 Go sur Android). Les fichiers lourds doivent être placés manuellement dans le stockage du téléphone :
1.  **Modèle Gemma** : Placer `gemma-4-E2B-it.litertlm` dans `Android/data/com.example.alfred_app/files/`.
2.  **Dictionnaire Vocal** : Placer le dossier `espeak-ng-data` dans `Android/data/com.example.alfred_app/files/`.

**Fichiers dans les `assets` de l'application :**
- `assets/tts/fr_FR-tom-medium.onnx` (Le cerveau de la voix).
- `assets/tts/tokens.txt` (Le dictionnaire de la voix).

**Bibliothèques Natives (C++) :**
Les fichiers `.so` de Sherpa-Onnx et LiteRT doivent être placés dans `android/app/src/main/jniLibs/arm64-v8a/` et chargés dans `MainActivity.kt`.

---

## 🛣️ Feuille de Route (Améliorations futures)

Maintenant que le cœur du système (Texte + Voix + Serveur + Mobile) est parfait et infaillible, voici les chantiers possibles pour la suite :

- [ ] **Intégration Calendrier & Mails** : Outils API sur le serveur pour connecter Google Calendar et Gmail (résumé matinal).
- [ ] **Mode Proactif** : Tâches planifiées (Cron) sur le Pi où ALFRED envoie une notification vocale à 7h00 avec la météo et les news.
- [ ] **Auto-amélioration** : Un outil permettant à ALFRED d'écrire et de sauvegarder ses propres scripts Python dans un dossier `/skills/` quand on lui demande d'apprendre quelque chose.
- [ ] **Domotique Home Assistant** : Connecter l'API de HA pour qu'ALFRED puisse allumer/éteindre les lumières du Batcave.
- [ ] **Le Wake Word (Mot déclencheur)** : Permettre à ALFRED de rester en écoute passive en arrière-plan et de s'activer quand tu dis "Alfred", sans avoir à toucher l'écran.

## 📄 Licence
Projet personnel open-source. Libre à vous de l'utiliser, de le modifier et de le partager.
```