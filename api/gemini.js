const GEMINI_ENDPOINT =
  'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

function buildPrompt() {
  return `
Ты получишь скриншот тестового вопроса на русском языке.
Нужно извлечь:
1) вопрос
2) список вариантов ответов
3) правильный ответ (по строке "Правильный ответ: ...", если есть)

Ответ верни строго в JSON без пояснений:
{"question":"...","options":["...","..."],"correct_answer":"..."}
`.trim();
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: 'GEMINI_API_KEY is not set' });
    return;
  }

  const { image_base64: imageBase64, mime_type: mimeType } = req.body || {};
  if (!imageBase64) {
    res.status(400).json({ error: 'image_base64 is required' });
    return;
  }

  const payload = {
    contents: [
      {
        parts: [
          {
            inline_data: {
              mime_type: mimeType || 'image/png',
              data: imageBase64,
            },
          },
          { text: buildPrompt() },
        ],
      },
    ],
  };

  try {
    const response = await fetch(GEMINI_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify(payload),
    });

    const text = await response.text();
    res.status(response.status).send(text);
  } catch (error) {
    res.status(500).json({ error: String(error) });
  }
}
