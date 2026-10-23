const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });
const express = require('express');
const cors = require('cors');
const fs = require('fs');

const app = express();
app.use(cors());
app.use(express.json({ limit: '64kb' }));

const PORT = 3000;
const API_KEY = process.env.GEMINI_API_KEY;
const MODEL = process.env.GEMINI_MODEL || 'gemini-2.5-flash';

// Only Kurals with real, checked text are sent to the bot.
function loadKurals() {
  const file = path.join(__dirname, '..', 'assets', 'kurals.json');
  const all = JSON.parse(fs.readFileSync(file, 'utf8'));
  return all.filter(
    (k) => k.meaning && !k.meaning.endsWith('here.') && /[\u0B80-\u0BFF]/.test(k.tamil || '')
  );
}

app.get('/health', (req, res) => {
  res.json({ ok: true, verifiedKurals: loadKurals().length, keySet: !!API_KEY });
});

app.post('/chat', async (req, res) => {
  const message = String(req.body?.message || '').trim();
  if (!message) return res.status(400).json({ error: 'Message is empty.' });
  if (!API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY is missing in backend/.env' });

  const kurals = loadKurals();
  const kuralList = kurals.map((k) => `Kural ${k.number} (${k.chapter}): ${k.meaning}`).join('\n');

  const systemText = `You are ShivaAI, a friendly and warm voice assistant. Talk like a kind friend.
- Answer any question the user asks, accurately and helpfully.
- If the user only greets you, greet them back warmly and ask how you can help.
- Keep replies short (2 to 4 sentences) because they will be read aloud. No markdown, no lists, no emojis.
- Reply in simple English.
- If one of the Thirukural below genuinely fits the topic, set kural_number to that number. Otherwise set it to null. Never invent a Kural number.

Thirukural you may use:
${kuralList || '(none verified yet)'}

Reply ONLY as JSON: {"reply": "your answer", "kural_number": number or null}`;

  // Keep only valid previous turns. Gemini expects "user" and "model" roles, and the first turn must be "user".
  const turns = (Array.isArray(req.body?.history) ? req.body.history : [])
    .filter((h) => h && typeof h.text === 'string' && h.text.trim())
    .slice(-10)
    .map((h) => ({ role: h.role === 'bot' ? 'model' : 'user', parts: [{ text: h.text }] }));
  while (turns.length && turns[0].role === 'model') turns.shift();
  turns.push({ role: 'user', parts: [{ text: message }] });

  try {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: systemText }] },
          contents: turns,
          generationConfig: { responseMimeType: 'application/json', temperature: 0.7 },
        }),
      }
    );
    const data = await r.json();
    if (!r.ok) {
      return res.status(502).json({ error: data.error?.message || `Gemini error ${r.status}` });
    }

    const raw = data.candidates?.[0]?.content?.parts?.[0]?.text || '';
    let answer;
    try {
      answer = JSON.parse(raw.replace(/```json|```/g, '').trim());
    } catch {
      answer = { reply: raw, kural_number: null };
    }

    const reply = String(answer.reply || '').trim() || 'Sorry, I could not think of an answer. Please try again.';
    const k = kurals.find((x) => x.number === Number(answer.kural_number));

    res.json({
      reply,
      kural: k
        ? { number: k.number, chapter: k.chapter, tamil: k.tamil, meaning: k.meaning }
        : null,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`ShivaAI server running on port ${PORT}`);
});