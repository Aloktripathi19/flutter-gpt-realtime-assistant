// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// ───────────────────────────────────────────────────────────────
///  PUT YOUR API KEY HERE (dev only — for production use ephemeral keys)
/// ───────────────────────────────────────────────────────────────
const String kOpenAIKey = "sk-API key";

/// Model
const String kRealtimeModel = "gpt-4o-realtime-preview-2024-12-17";

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPT Realtime Assistant',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const VoiceAgentPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Simple message model
class Message {
  final String text;
  final bool isUser;
  Message(this.text, this.isUser);
}

class VoiceAgentPage extends StatefulWidget {
  const VoiceAgentPage({super.key});
  @override
  State<VoiceAgentPage> createState() => _VoiceAgentPageState();
}

class _VoiceAgentPageState extends State<VoiceAgentPage> {
  WebSocketChannel? _channel;
  bool _connected = false;

  // Speech
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;

  // Chat state
  final List<Message> _messages = [];
  final _scrollCtrl = ScrollController();

  // Audio
  final AudioPlayer _player = AudioPlayer();
  final BytesBuilder _audioBuffer = BytesBuilder();
  bool _gotAudioThisTurn = false;
  bool _isSpeaking = false;

  bool _mounted = true;

  @override
  void initState() {
    super.initState();
    _player.setReleaseMode(ReleaseMode.stop);
    _connectRealtime();
  }

  @override
  void dispose() {
    _mounted = false;
    _channel?.sink.close();
    _player.dispose();
    _speech.stop();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────
  // Connect Realtime API
  // ───────────────────────────────────────────────────────────────
  Future<void> _connectRealtime() async {
    try {
      final url = Uri.parse("wss://api.openai.com/v1/realtime?model=$kRealtimeModel");

      _channel = IOWebSocketChannel.connect(
        url,
        headers: {
          "Authorization": "Bearer $kOpenAIKey",
          "OpenAI-Beta": "realtime=v1",
        },
      );

      _channel!.stream.listen(
            (raw) async {
          final data = jsonDecode(raw);

          switch (data["type"]) {
            case "session.created":
              setState(() => _connected = true);

              // Update session
              final update = {
                "type": "session.update",
                "session": {
                  "voice": "marin",
                  "output_audio_format": "pcm16",
                  "turn_detection": {
                    "type": "server_vad",
                    "create_response": false,
                    "silence_duration_ms": 300
                  }
                }
              };
              _channel!.sink.add(jsonEncode(update));
              break;

            case "response.created":
              _audioBuffer.clear();
              _gotAudioThisTurn = false;
              _isSpeaking = true;
              setState(() {
                _messages.add(Message("", false));
              });
              break;

            case "response.output_text.delta":
              setState(() {
                final last = _messages.removeLast();
                _messages.add(Message(last.text + (data["delta"] ?? ""), false));
              });
              _scrollToEndSoon();
              break;

            case "response.audio_transcript.delta":
              setState(() {
                final last = _messages.removeLast();
                _messages.add(Message(last.text + (data["delta"] ?? ""), false));
              });
              _scrollToEndSoon();
              break;

            case "response.audio.delta":
              final b64 = data["delta"];
              if (b64 is String && b64.isNotEmpty) {
                _audioBuffer.add(base64Decode(b64));
                _gotAudioThisTurn = true;
              }
              break;

            case "response.audio.done":
            case "response.completed":
              if (_gotAudioThisTurn && _audioBuffer.isNotEmpty) {
                final pcmBytes = _audioBuffer.toBytes();
                _audioBuffer.clear();
                _gotAudioThisTurn = false;

                final wavBytes = _pcm16ToWav(pcmBytes);
                await _player.stop();
                await _player.play(BytesSource(wavBytes));
                _isSpeaking = true;

                _player.onPlayerComplete.listen((_) {
                  if (_mounted) {
                    setState(() => _isSpeaking = false);
                  }
                });
              }
              break;

            case "error":
              print("❌ Realtime error: ${data["error"]}");
              break;
          }
        },
        onDone: () {
          print("🔌 Realtime socket closed");
          if (_mounted) setState(() => _connected = false);
        },
        onError: (e) {
          print("❌ Realtime socket error: $e");
          if (_mounted) setState(() => _connected = false);
        },
      );

      print("✅ Connected to Realtime API");
    } catch (e) {
      print("❌ Failed to connect: $e");
      if (_mounted) setState(() => _connected = false);
    }
  }

  // ───────────────────────────────────────────────────────────────
  // Speech input
  // ───────────────────────────────────────────────────────────────
  Future<void> _startListening() async {
    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      final r = await Permission.microphone.request();
      if (!r.isGranted) return;
    }

    final available = await _speech.initialize(
      onStatus: (s) => print("🎙️ Speech status: $s"),
      onError: (e) => print("🎙️ Speech error: $e"),
    );

    if (!available) {
      print("❌ Speech recognition not available");
      return;
    }

    setState(() {
      _isListening = true;
    });

    _speech.listen(
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
      partialResults: true,
      localeId: "en_US",
      onResult: (result) {
        if (_mounted) {
          if (result.finalResult) {
            _sendToGPT(result.recognizedWords);
            setState(() => _isListening = false);
          }
        }
      },
    );
  }

  // ───────────────────────────────────────────────────────────────
  // Send to GPT
  // ───────────────────────────────────────────────────────────────
  void _sendToGPT(String text) {
    setState(() {
      _messages.add(Message(text, true));
    });
    _scrollToEndSoon();

    final userItem = {
      "type": "conversation.item.create",
      "item": {
        "type": "message",
        "role": "user",
        "content": [
          {"type": "input_text", "text": text}
        ]
      }
    };
    _channel!.sink.add(jsonEncode(userItem));

    final makeResponse = {
      "type": "response.create",
      "response": {
        "modalities": ["audio", "text"],
        "instructions": "Speak naturally with expression."
      }
    };
    _channel!.sink.add(jsonEncode(makeResponse));
  }

  // ───────────────────────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────────────────────
  void _scrollToEndSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Uint8List _pcm16ToWav(Uint8List pcmBytes,
      {int sampleRate = 24000, int channels = 1}) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final dataSize = pcmBytes.lengthInBytes;
    final chunkSize = 36 + dataSize;

    final header = BytesBuilder();
    void writeString(String s) => header.add(s.codeUnits);
    void writeUint32(int v) =>
        header.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
    void writeUint16(int v) =>
        header.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

    writeString('RIFF');
    writeUint32(chunkSize);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1);
    writeUint16(channels);
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(16);
    writeString('data');
    writeUint32(dataSize);

    return Uint8List.fromList([...header.toBytes(), ...pcmBytes]);
  }

  Widget _bubble(Message msg) {
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: msg.isUser ? Colors.blueAccent : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          msg.text,
          style: TextStyle(
            fontSize: 16,
            color: msg.isUser ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────
  // Build UI
  // ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text("🎤 GPT Realtime Assistant"),
        backgroundColor: Colors.blueAccent,
        actions: [
          Icon(
            _connected ? Icons.cloud_done : Icons.cloud_off,
            color: Colors.white,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              itemCount: _messages.length,
              itemBuilder: (context, i) => _bubble(_messages[i]),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
                    label: Text(_isListening ? "Listening…" : "Talk"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                      _isListening ? Colors.orangeAccent : Colors.blueAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _isListening ? null : _startListening,
                  ),
                ),
                const SizedBox(width: 10),
                if (_isSpeaking)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text("Stop"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(100, 48),
                    ),
                    onPressed: () async {
                      await _player.stop();
                      setState(() => _isSpeaking = false);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
