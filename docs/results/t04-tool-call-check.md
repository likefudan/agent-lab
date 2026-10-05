# Tool-call check against http://127.0.0.1:8100

9 of 9 cases passed.

| Case | Result | Time |
| --- | --- | --- |
| single tool call, non-streaming | PASS | 13.3s total, 408 prompt tokens, 39 completion tokens |
| two tool calls, non-streaming | PASS | 9.6s total, 421 prompt tokens, 53 completion tokens |
| arguments with quotes and newlines, non-streaming | PASS | 13.5s total, 459 prompt tokens, 76 completion tokens |
| answer from a tool result, non-streaming | PASS | 5.3s total, 478 prompt tokens, 20 completion tokens |
| single tool call, streaming | PASS | 7.7s total, 408 prompt tokens, 39 completion tokens |
| two tool calls, streaming | PASS | 9.8s total, 421 prompt tokens, 53 completion tokens, first token after 6.0s, generation 13.7 tok/s |
| arguments with quotes and newlines, streaming | PASS | 13.4s total, 459 prompt tokens, 76 completion tokens |
| answer from a tool result, streaming | PASS | 4.5s total, 478 prompt tokens, 13 completion tokens, first token after 2.8s, generation 7.1 tok/s |
| plain answer of about 200 tokens, streaming (speed, no thinking) | PASS | 26.3s total, 27 prompt tokens, 198 completion tokens, first token after 0.8s, generation 7.7 tok/s |

## single tool call, non-streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] exactly one tool call
- [x] function is get_weather
- [x] arguments are a JSON object
- [x] city is "Paris"
- [x] tool call has an id
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 13.3s total, 408 prompt tokens, 39 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris right now? Use celsius."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-796dd53a-1c70-40fc-818b-2ed950d6c7ef",
  "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g",
  "object": "chat.completion",
  "model": "default_model",
  "created": 1791210454,
  "choices": [
    {
      "index": 0,
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\": \"Paris\", \"unit\": \"celsius\"}"
            },
            "type": "function",
            "id": "71ac498d-f002-47f0-bc24-3c8eb9632142"
          }
        ]
      }
    }
  ],
  "usage": {
    "prompt_tokens": 408,
    "completion_tokens": 39,
    "total_tokens": 447,
    "prompt_tokens_details": {
      "cached_tokens": 0
    }
  }
}
```

## two tool calls, non-streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] two get_weather calls
- [x] one for Paris and one for Tokyo
- [x] tool call ids are distinct
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 9.6s total, 421 prompt tokens, 53 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris and in Tokyo right now? Call the weather tool once for each city, both in this turn."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-d704b835-3be7-4b8b-ad35-9019bb2a07b1",
  "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g",
  "object": "chat.completion",
  "model": "default_model",
  "created": 1791210468,
  "choices": [
    {
      "index": 0,
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": "\n",
        "tool_calls": [
          {
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\": \"Paris\"}"
            },
            "type": "function",
            "id": "4667efe7-86d6-4b9f-99ea-6dc19af65c5e"
          },
          {
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\": \"Tokyo\"}"
            },
            "type": "function",
            "id": "a7e46399-de8a-4115-a207-85c836538440"
          }
        ]
      }
    }
  ],
  "usage": {
    "prompt_tokens": 421,
    "completion_tokens": 53,
    "total_tokens": 474,
    "prompt_tokens_details": {
      "cached_tokens": 0
    }
  }
}
```

## arguments with quotes and newlines, non-streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] exactly one write_file call
- [x] path is "hello.py"
- [x] content matches exactly (quotes, backslashes, newlines; trailing newline ignored)
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 13.5s total, 459 prompt tokens, 76 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "Create the file hello.py with exactly this content, character for character, with nothing added or changed:\n\n```python\ndef greet(name):\n    print(\"Hello, \\\"\" + name + \"\\\"!\")\n    path = 'C:\\\\temp\\\\out.txt'\n    return f'{name}\\tdone'\n```"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-b0634eb3-a331-4064-bb5a-b4e39b4bd829",
  "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g",
  "object": "chat.completion",
  "model": "default_model",
  "created": 1791210477,
  "choices": [
    {
      "index": 0,
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "function": {
              "name": "write_file",
              "arguments": "{\"path\": \"hello.py\", \"content\": \"def greet(name):\\n    print(\\\"Hello, \\\\\\\"\\\" + name + \\\"\\\\\\\"!\\\")\\n    path = 'C:\\\\\\\\temp\\\\\\\\out.txt'\\n    return f'{name}\\\\tdone'\"}"
            },
            "type": "function",
            "id": "1830b508-4cbe-40b8-9dc0-a793544b8530"
          }
        ]
      }
    }
  ],
  "usage": {
    "prompt_tokens": 459,
    "completion_tokens": 76,
    "total_tokens": 535,
    "prompt_tokens_details": {
      "cached_tokens": 0
    }
  }
}
```

## answer from a tool result, non-streaming: PASS

- [x] no tool calls
- [x] non-empty answer
- [x] no reasoning field
- [x] no <think> or tool-call markup in content
- [x] answer uses the tool result (mentions 18)

Timing: 5.3s total, 478 prompt tokens, 20 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris right now? Use celsius."
    },
    {
      "role": "assistant",
      "content": "",
      "tool_calls": [
        {
          "id": "call_1",
          "type": "function",
          "function": {
            "name": "get_weather",
            "arguments": "{\"city\": \"Paris\", \"unit\": \"celsius\"}"
          }
        }
      ]
    },
    {
      "role": "tool",
      "tool_call_id": "call_1",
      "content": "{\"temperature\": 18, \"sky\": \"cloudy\"}"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-641167b0-efb1-4190-bca3-3ac2c6a837e8",
  "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g",
  "object": "chat.completion",
  "model": "default_model",
  "created": 1791210491,
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "The current weather in Paris is **18°C** with a **cloudy** sky."
      }
    }
  ],
  "usage": {
    "prompt_tokens": 478,
    "completion_tokens": 20,
    "total_tokens": 498,
    "prompt_tokens_details": {
      "cached_tokens": 0
    }
  }
}
```

## single tool call, streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] exactly one tool call
- [x] function is get_weather
- [x] arguments are a JSON object
- [x] city is "Paris"
- [x] tool call has an id
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 7.7s total, 408 prompt tokens, 39 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris right now? Use celsius."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ],
  "stream": true,
  "stream_options": {
    "include_usage": true
  }
}
```

Assembled message:

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "fdeb5eb3-3ab4-4955-b52d-f89d680a583d",
      "type": "function",
      "function": {
        "name": "get_weather",
        "arguments": "{\"city\": \"Paris\", \"unit\": \"celsius\"}"
      }
    }
  ]
}
```

Raw stream:

```text
: keepalive 404/408
: keepalive 407/408
: keepalive 408/408
data: {"id": "chatcmpl-68b58efb-6736-4f48-96bd-e85f6ea61a14", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210496, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "get_weather", "arguments": "{\"city\": \"Paris\", \"unit\": \"celsius\"}"}, "type": "function", "id": "fdeb5eb3-3ab4-4955-b52d-f89d680a583d", "index": 0}]}}]}
data: {"id": "chatcmpl-68b58efb-6736-4f48-96bd-e85f6ea61a14", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210496, "choices": [{"index": 0, "finish_reason": "tool_calls", "delta": {"role": "assistant"}}]}
data: {"id": "chatcmpl-68b58efb-6736-4f48-96bd-e85f6ea61a14", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion", "model": "default_model", "created": 1791210496, "choices": [], "usage": {"prompt_tokens": 408, "completion_tokens": 39, "total_tokens": 447, "prompt_tokens_details": {"cached_tokens": 0}}}
data: [DONE]
```

## two tool calls, streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] two get_weather calls
- [x] one for Paris and one for Tokyo
- [x] tool call ids are distinct
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 9.8s total, 421 prompt tokens, 53 completion tokens, first token after 6.0s, generation 13.7 tok/s

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris and in Tokyo right now? Call the weather tool once for each city, both in this turn."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ],
  "stream": true,
  "stream_options": {
    "include_usage": true
  }
}
```

Assembled message:

```json
{
  "role": "assistant",
  "content": "\n",
  "tool_calls": [
    {
      "id": "8c4dfd52-2a56-49b4-a98d-6253ec6651b6",
      "type": "function",
      "function": {
        "name": "get_weather",
        "arguments": "{\"city\": \"Paris\"}"
      }
    },
    {
      "id": "2537219f-1581-4184-bc00-aff334f58c19",
      "type": "function",
      "function": {
        "name": "get_weather",
        "arguments": "{\"city\": \"Tokyo\"}"
      }
    }
  ]
}
```

Raw stream:

```text
: keepalive 417/421
: keepalive 420/421
: keepalive 421/421
data: {"id": "chatcmpl-215aecf5-712e-448c-a94b-0297da9d7ce9", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210504, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "get_weather", "arguments": "{\"city\": \"Paris\"}"}, "type": "function", "id": "8c4dfd52-2a56-49b4-a98d-6253ec6651b6", "index": 0}]}}]}
data: {"id": "chatcmpl-215aecf5-712e-448c-a94b-0297da9d7ce9", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210504, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "\n"}}]}
data: {"id": "chatcmpl-215aecf5-712e-448c-a94b-0297da9d7ce9", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210504, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "get_weather", "arguments": "{\"city\": \"Tokyo\"}"}, "type": "function", "id": "2537219f-1581-4184-bc00-aff334f58c19", "index": 1}]}}]}
data: {"id": "chatcmpl-215aecf5-712e-448c-a94b-0297da9d7ce9", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210504, "choices": [{"index": 0, "finish_reason": "tool_calls", "delta": {"role": "assistant"}}]}
data: {"id": "chatcmpl-215aecf5-712e-448c-a94b-0297da9d7ce9", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion", "model": "default_model", "created": 1791210504, "choices": [], "usage": {"prompt_tokens": 421, "completion_tokens": 53, "total_tokens": 474, "prompt_tokens_details": {"cached_tokens": 0}}}
data: [DONE]
```

## arguments with quotes and newlines, streaming: PASS

- [x] finish_reason is "tool_calls"
- [x] exactly one write_file call
- [x] path is "hello.py"
- [x] content matches exactly (quotes, backslashes, newlines; trailing newline ignored)
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 13.4s total, 459 prompt tokens, 76 completion tokens

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "Create the file hello.py with exactly this content, character for character, with nothing added or changed:\n\n```python\ndef greet(name):\n    print(\"Hello, \\\"\" + name + \"\\\"!\")\n    path = 'C:\\\\temp\\\\out.txt'\n    return f'{name}\\tdone'\n```"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ],
  "stream": true,
  "stream_options": {
    "include_usage": true
  }
}
```

Assembled message:

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "08d12912-7ff3-4b8d-b708-b37ea16b590c",
      "type": "function",
      "function": {
        "name": "write_file",
        "arguments": "{\"path\": \"hello.py\", \"content\": \"def greet(name):\\n    print(\\\"Hello, \\\\\\\"\\\" + name + \\\"\\\\\\\"!\\\")\\n    path = 'C:\\\\\\\\temp\\\\\\\\out.txt'\\n    return f'{name}\\\\tdone'\"}"
      }
    }
  ]
}
```

Raw stream:

```text
: keepalive 455/459
: keepalive 458/459
: keepalive 459/459
data: {"id": "chatcmpl-380f1e4e-c607-4c98-b312-0596045119c5", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210513, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "write_file", "arguments": "{\"path\": \"hello.py\", \"content\": \"def greet(name):\\n    print(\\\"Hello, \\\\\\\"\\\" + name + \\\"\\\\\\\"!\\\")\\n    path = 'C:\\\\\\\\temp\\\\\\\\out.txt'\\n    return f'{name}\\\\tdone'\"}"}, "type": "function", "id": "08d12912-7ff3-4b8d-b708-b37ea16b590c", "index": 0}]}}]}
data: {"id": "chatcmpl-380f1e4e-c607-4c98-b312-0596045119c5", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210513, "choices": [{"index": 0, "finish_reason": "tool_calls", "delta": {"role": "assistant"}}]}
data: {"id": "chatcmpl-380f1e4e-c607-4c98-b312-0596045119c5", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion", "model": "default_model", "created": 1791210513, "choices": [], "usage": {"prompt_tokens": 459, "completion_tokens": 76, "total_tokens": 535, "prompt_tokens_details": {"cached_tokens": 0}}}
data: [DONE]
```

## answer from a tool result, streaming: PASS

- [x] no tool calls
- [x] non-empty answer
- [x] no reasoning field
- [x] no <think> or tool-call markup in content
- [x] answer uses the tool result (mentions 18)

Timing: 4.5s total, 478 prompt tokens, 13 completion tokens, first token after 2.8s, generation 7.1 tok/s

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "What is the weather in Paris right now? Use celsius."
    },
    {
      "role": "assistant",
      "content": "",
      "tool_calls": [
        {
          "id": "call_1",
          "type": "function",
          "function": {
            "name": "get_weather",
            "arguments": "{\"city\": \"Paris\", \"unit\": \"celsius\"}"
          }
        }
      ]
    },
    {
      "role": "tool",
      "tool_call_id": "call_1",
      "content": "{\"temperature\": 18, \"sky\": \"cloudy\"}"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {
              "type": "string",
              "description": "City name, e.g. Paris"
            },
            "unit": {
              "type": "string",
              "enum": [
                "celsius",
                "fahrenheit"
              ]
            }
          },
          "required": [
            "city"
          ]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path of the file"
            },
            "content": {
              "type": "string",
              "description": "Full content of the file"
            }
          },
          "required": [
            "path",
            "content"
          ]
        }
      }
    }
  ],
  "stream": true,
  "stream_options": {
    "include_usage": true
  }
}
```

Assembled message:

```json
{
  "role": "assistant",
  "content": "It's currently 18°C and cloudy in Paris."
}
```

Raw stream:

```text
: keepalive 477/478
: keepalive 478/478
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "It"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "'s"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " currently"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " 1"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "8"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "\u00b0C"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " cloudy"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " in"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Paris"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210527, "choices": [{"index": 0, "finish_reason": "stop", "delta": {"role": "assistant"}}]}
data: {"id": "chatcmpl-79a2d951-92b7-4ebf-a3b1-98aefdbf9124", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion", "model": "default_model", "created": 1791210527, "choices": [], "usage": {"prompt_tokens": 478, "completion_tokens": 13, "total_tokens": 491, "prompt_tokens_details": {"cached_tokens": 0}}}
data: [DONE]
```

## plain answer of about 200 tokens, streaming (speed, no thinking): PASS

- [x] no tool calls
- [x] non-empty answer
- [x] no reasoning field
- [x] no <think> or tool-call markup in content

Timing: 26.3s total, 27 prompt tokens, 198 completion tokens, first token after 0.8s, generation 7.7 tok/s

Request:

```json
{
  "messages": [
    {
      "role": "user",
      "content": "In about 150 words, explain why the sky is blue."
    }
  ],
  "max_tokens": 400,
  "stream": true,
  "stream_options": {
    "include_usage": true
  }
}
```

Assembled message:

```json
{
  "role": "assistant",
  "content": "The sky appears blue due to a phenomenon called Rayleigh scattering. Sunlight, which is actually white, is composed of a spectrum of colors, each with a different wavelength. When this light enters Earth’s atmosphere, it collides with gas molecules like nitrogen and oxygen. Shorter wavelengths of light, such as blue and violet, scatter much more efficiently than longer wavelengths like red and orange. While violet scatters even more than blue, our eyes are less sensitive to violet, and some of it is absorbed by the upper atmosphere. Consequently, the scattered blue light dominates what we see when looking up. This effect is most visible when the sun is high in the sky, as the light travels through a thinner layer of atmosphere. At sunrise or sunset, the light travels through more atmosphere, scattering away the blue and leaving the longer red and orange wavelengths to reach our eyes, creating those vibrant hues. Thus, the interplay between light physics and atmospheric composition paints our daytime sky in blue."
}
```

Raw stream:

```text
: keepalive 23/27
: keepalive 26/27
: keepalive 27/27
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "The"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sky"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " appears"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " due"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " to"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " a"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " phenomenon"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " called"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Ray"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "leigh"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " scattering"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Sun"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " which"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " is"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " actually"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " white"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " is"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " composed"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " of"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " a"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " spectrum"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " of"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " colors"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " each"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " with"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " a"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " different"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " wavelength"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " When"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " this"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " enters"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Earth"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "\u2019s"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " atmosphere"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " it"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " coll"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "ides"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " with"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " gas"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " molecules"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " like"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " nitrogen"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " oxygen"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Short"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "er"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " wavelengths"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " of"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " such"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " as"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " violet"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " scatter"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " much"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " more"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " efficiently"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " than"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " longer"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " wavelengths"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " like"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " red"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " orange"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " While"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " violet"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sc"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "atters"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " even"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " more"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " than"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " our"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " eyes"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " are"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " less"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sensitive"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " to"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " violet"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " some"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " of"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " it"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " is"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " absorbed"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " by"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " upper"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " atmosphere"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Consequently"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " scattered"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " dominates"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " what"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " we"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " see"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " when"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " looking"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " up"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " This"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " effect"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " is"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " most"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " visible"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " when"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sun"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " is"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " high"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " in"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sky"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " as"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " travels"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " through"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " a"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " thinner"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " layer"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " of"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " atmosphere"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " At"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sunrise"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " or"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sunset"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " travels"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " through"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " more"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " atmosphere"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " scattering"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " away"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " leaving"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " longer"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " red"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " orange"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " wavelengths"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " to"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " reach"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " our"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " eyes"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " creating"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " those"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " vibrant"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " hues"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " Thus"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": ","}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " the"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " inter"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "play"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " between"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " light"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " physics"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " and"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " atmospheric"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " composition"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " paints"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " our"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " daytime"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " sky"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " in"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": " blue"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "."}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion.chunk", "model": "default_model", "created": 1791210531, "choices": [{"index": 0, "finish_reason": "stop", "delta": {"role": "assistant"}}]}
data: {"id": "chatcmpl-c0d52cb7-5f86-4e42-b247-ea3c253c8350", "system_fingerprint": "0.32.0-0.32.3-macOS-26.5.2-arm64-arm-64bit-Mach-O-applegpu_g17g", "object": "chat.completion", "model": "default_model", "created": 1791210531, "choices": [], "usage": {"prompt_tokens": 27, "completion_tokens": 198, "total_tokens": 225, "prompt_tokens_details": {"cached_tokens": 0}}}
data: [DONE]
```
