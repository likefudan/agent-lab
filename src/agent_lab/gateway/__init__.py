"""The gateway (design section 6.3): the only endpoint clients reach, at 127.0.0.1:8000.

It authenticates every request, enforces the token limit, fills in defaults,
queues requests for the single-request backend and keeps streams alive.
"""
