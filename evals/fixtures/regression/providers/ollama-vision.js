'use strict';

const fs = require('fs');
const path = require('path');

/**
 * Local-only Ollama vision provider for the approved multimodal model.
 * Bound to gemma4:12b and loopback Ollama. Never uses hosted APIs.
 */
const MODEL = process.env.AGENT_LAB_VISION_MODEL || 'gemma4:12b';
const BASE = process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434';

class OllamaVisionProvider {
  constructor(options = {}) {
    this.config = options.config || {};
    this.providerId = options.id || `agent-lab:ollama-vision:${MODEL}`;
  }

  id() {
    return this.providerId;
  }

  async callApi(prompt, context) {
    const imageRel =
      context?.vars?.image_path ||
      'fixtures/model-qualification/vision-card.svg.png';
    const imagePath = path.isAbsolute(imageRel)
      ? imageRel
      : path.resolve(__dirname, '../../..', imageRel);
    const imageB64 = fs.readFileSync(imagePath).toString('base64');
    const body = {
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: String(prompt),
          images: [imageB64],
        },
      ],
      stream: false,
      think: false,
      keep_alive: 0,
      options: { temperature: 0, seed: 42, num_ctx: 4096, num_predict: 256 },
    };
    const response = await fetch(`${BASE}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      const text = await response.text();
      return { error: `ollama vision HTTP ${response.status}: ${text}` };
    }
    const data = await response.json();
    return {
      output: data?.message?.content || '',
      tokenUsage: {
        total: (data.prompt_eval_count || 0) + (data.eval_count || 0),
        prompt: data.prompt_eval_count || 0,
        completion: data.eval_count || 0,
      },
    };
  }
}

module.exports = OllamaVisionProvider;
