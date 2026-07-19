'use strict';

/**
 * Local-only Ollama tool-call provider for Agent Lab Promptfoo suites.
 * Calls http://127.0.0.1:11434 only. Never uses hosted APIs.
 */
const DEFAULT_MODEL = process.env.AGENT_LAB_TOOL_MODEL || 'qwen3.5:4b';
const BASE = process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434';

const TOOL = {
  type: 'function',
  function: {
    name: 'get_weather',
    description: 'Get current weather for a city',
    parameters: {
      type: 'object',
      properties: {
        city: { type: 'string' },
      },
      required: ['city'],
    },
  },
};

class OllamaToolsProvider {
  constructor(options = {}) {
    this.config = options.config || {};
    this.model = this.config.model || DEFAULT_MODEL;
    this.providerId =
      options.id || `agent-lab:ollama-tools:${this.model}`;
  }

  id() {
    return this.providerId;
  }

  async callApi(prompt) {
    const body = {
      model: this.model,
      messages: [{ role: 'user', content: String(prompt) }],
      tools: [TOOL],
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
      return { error: `ollama tools HTTP ${response.status}: ${text}` };
    }
    const data = await response.json();
    const toolCalls = data?.message?.tool_calls;
    if (Array.isArray(toolCalls) && toolCalls.length > 0) {
      const call = toolCalls[0];
      const name = call.function?.name || call.name;
      const args = call.function?.arguments || call.arguments || {};
      return {
        output: JSON.stringify({ name, arguments: args }),
        tokenUsage: {
          total: data.eval_count || 0,
          prompt: data.prompt_eval_count || 0,
          completion: data.eval_count || 0,
        },
      };
    }
    return {
      output: JSON.stringify({
        name: null,
        arguments: {},
        content: data?.message?.content || '',
      }),
    };
  }
}

module.exports = OllamaToolsProvider;
