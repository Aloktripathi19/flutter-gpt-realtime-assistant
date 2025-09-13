# 🎤 Flutter GPT Realtime Assistant

A cross-platform **Flutter app** that integrates with **OpenAI’s Realtime API** (`gpt-4o-realtime-preview`) to provide a voice-enabled AI assistant.  
It supports **speech-to-text**, **real-time GPT responses**, **audio playback**, and a clean chat-style UI.

---

## ✨ Features

- 🎙️ **Speech Input** using [`speech_to_text`](https://pub.dev/packages/speech_to_text)  
- 🧠 **Realtime GPT** integration via WebSockets  
- 💬 **Chat Bubbles UI** for displaying user ↔ AI messages  
- 🔊 **Voice Output** with [`audioplayers`](https://pub.dev/packages/audioplayers)  
- 📱 Runs on **Android, iOS, Web, macOS, Windows, and Linux**

---

## 🚀 Getting Started

### 1. Clone the repository
```bash
git clone https://github.com/Aloktripathi19/flutter-gpt-realtime-assistant.git
cd flutter-gpt-realtime-assistant
```
### 2. Install dependencies
```bash
flutter pub get 
```

### 3. Add your OpenAI API key
 - const String kOpenAIKey = "sk-API key";

 ### 🛠️ Tech Stack

- Flutter (UI + Cross-platform support)

- speech_to_text → Microphone input

- audioplayers → Audio playback

- web_socket_channel → Realtime GPT WebSocket connection

- permission_handler → Microphone permissions