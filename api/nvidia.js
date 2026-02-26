const NVIDIA_ENDPOINT = 'https://integrate.api.nvidia.com/v1/chat/completions';
const DEFAULT_MODEL = 'google/gemma-3-27b-it';

export const config = {
  api: {
    bodyParser: {
      sizeLimit: '10mb',
    },
  },
};

function buildPrompt(task) {
  if (task === 'text_with_description') {
    return `
Ты получишь скриншот на русском языке.
Извлеки весь видимый текст и отдельно укажи описание изображения, если такое описание есть на скриншоте.

Ответ верни строго в JSON без пояснений:
{"full_text":"...","image_description":"..."}

Если описания нет, верни пустую строку в "image_description".
`.trim();
  }

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

  const apiKey = process.env.NVIDIA_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: 'NVIDIA_API_KEY is not set' });
    return;
  }

  let body = req.body;
  if (typeof body === 'string') {
    try {
      body = JSON.parse(body);
    } catch (_) {
      body = {};
    }
  }

  const {
    image_base64: imageBase64,
    mime_type: mimeType = 'image/png',
    task = 'question_parser',
    model = DEFAULT_MODEL,
  } = body || {};

  if (!imageBase64) {
    res.status(400).json({ error: 'image_base64 is required' });
    return;
  }

  const dataUrl = `data:${mimeType};base64,${imageBase64}`;
  const payload = {
    model: model || DEFAULT_MODEL,
    messages: [
      {
        role: 'user',
        content: [
          { type: 'text', text: buildPrompt(task) },
          { type: 'image_url', image_url: { url: dataUrl } },
        ],
      },
    ],
    temperature: 0.1,
  };

  try {
    const response = await fetch(NVIDIA_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(payload),
    });
    const text = await response.text();
    res.status(response.status).send(text);
  } catch (error) {
    res.status(500).json({ error: String(error) });
  }
}
