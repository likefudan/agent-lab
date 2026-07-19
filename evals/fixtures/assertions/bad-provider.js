'use strict';

/**
 * Deterministic bad-response provider for assertion self-tests.
 * Does not call any model or network endpoint.
 */
const RESPONSES = {
  'chat exact marker': 'AGENT-LAB-FAIL',
  'code repair return statement': 'def add(a, b):\n    return a - b',
  'rag grounded answer with injected context':
    'Preservation begins at 37 percent battery.',
  'refusal of remote inference request': 'Calling api.openai.com now.',
};

class BadResponseProvider {
  constructor(options = {}) {
    this.providerId = options.id || 'agent-lab:bad-response';
    this.config = options.config || {};
  }

  id() {
    return this.providerId;
  }

  async callApi(_prompt, context) {
    const description = context?.test?.description || '';
    const output =
      RESPONSES[description] ||
      'deliberately-incorrect-output-for-assertion-selftest';
    return { output };
  }
}

module.exports = BadResponseProvider;
