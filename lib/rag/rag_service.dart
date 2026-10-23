cat /tmp/fixes/rag_service_FIXED.dart
Response
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'chunker.dart';
import 'gemini_client.dart';
import 'kural_loader.dart';
import 'vector_store.dart';

class RagAnswer {
  final String text;
  final List<String> sources;
  RagAnswer(this.text, this.sources);
}

class RagService {
  RagService({GeminiClient? client}) : _gemini = client ?? GeminiClient();

  final GeminiClient _gemini;
  final VectorStore _store = VectorStore();
  List<Kural> _kurals = [];
  static const _notesKey = 'shivaai_user_notes_v1';

  int get chunkCount => _store.chunks.length;

  Future<void> init() async {
    print('🔄 RagService: Starting init...');
    
    await _store.load();
    print('📚 Loaded ${_store.chunks.length} cached chunks');

    // Load kurals FIRST
    _kurals = await KuralLoader.load();
    print('📜 Loaded ${_kurals.length} kurals');

    // Embed kurals
    await _embedKurals();
    print('✅ Kurals embedded');

    // Sync other documents
    await _sync(await _collectDocuments());
    print('✅ Documents synced. Total chunks: ${_store.chunks.length}');
  }

  Future<void> _embedKurals() async {
    if (_kurals.isEmpty) {
      print('⚠  No kurals to embed');
      return;
    }

    // Check which kurals are already embedded
    final existing = {
      for (final c in _store.chunks)
        if (c.id.startsWith('kural_')) 
          int.tryParse(c.id.replaceFirst('kural_', '')): c
    };

    final pending = <(int num, Kural k)>[];
    for (final k in _kurals) {
      if (!existing.containsKey(k.number)) {
        pending.add((k.number, k));
      }
    }

    if (pending.isEmpty) {
      print('✅ All kurals already embedded');
      return;
    }

    print('🔄 Embedding ${pending.length} new kurals...');
    final texts = [for (final (_, k) in pending) k.embeddingText];
    
    try {
      final vectors = await _gemini.embedDocuments(texts);
      
      for (var i = 0; i < pending.length; i++) {
        final (num, k) = pending[i];
        _store.chunks.add(DocChunk(
          id: 'kural_$num',
          source: k.sourceLabel,
          text: k.displayText,
          hash: _hash(k.embeddingText),
          embedding: vectors[i],
        ));
        print('  ✓ Kural #$num embedded');
      }
      await _store.save();
      print('✅ ${pending.length} kurals embedded & saved');
    } catch (e) {
      print('❌ Error embedding kurals: $e');
    }
  }

  Future<Map<String, String>> _collectDocuments() async {
    final docs = <String, String>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final path in manifest.listAssets()) {
        if (path.startsWith('assets/knowledge/') &&
            (path.endsWith('.md') || path.endsWith('.txt'))) {
          docs[path.split('/').last] = await rootBundle.loadString(path);
        }
      }
    } catch (e) {
      print('⚠  Error loading knowledge assets: $e');
    }
    
    final notes = await getNotes();
    notes.forEach((title, body) => docs['Note: $title'] = body);
    return docs;
  }

  Future<void> _sync(Map<String, String> docs) async {
    if (docs.isEmpty) {
      print('✅ No documents to sync');
      return;
    }

    final existing = {for (final c in _store.chunks) c.id: c};
    final kept = <DocChunk>[];
    final pending = <({String id, String source, String text, String hash})>[];

    docs.forEach((source, content) {
      final pieces = chunkText(content,
          size: AppConfig.chunkSize, overlap: AppConfig.chunkOverlap);
      for (var i = 0; i < pieces.length; i++) {
        final id = '$source#$i';
        final hash = _hash(pieces[i]);
        final old = existing[id];
        if (old != null && old.hash == hash) {
          kept.add(old);
        } else {
          pending.add((id: id, source: source, text: pieces[i], hash: hash));
        }
      }
    });

    if (pending.isNotEmpty) {
      print('🔄 Embedding ${pending.length} document chunks...');
      final vectors = await _gemini
       