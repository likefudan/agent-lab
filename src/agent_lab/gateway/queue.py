"""One request at a time, a few waiting, the rest turned away (design section 6.3).

The backend serves one request at a time (concurrency multiplies KV cache
memory). Requests wait here in arrival order; when ``queue_size`` are already
waiting, a new one gets 429 at once. A request that leaves while waiting (the
client disconnected) gives up its place.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator, Callable


class QueueFull(Exception):
    pass


class RequestQueue:
    def __init__(self, queue_size: int, on_change: Callable[[int, int], None] | None = None):
        self.queue_size = queue_size
        self._lock = asyncio.Lock()  # FIFO: waiters are woken in the order they arrived
        self.waiting = 0
        self.active = 0
        self._on_change = on_change

    def _changed(self) -> None:
        if self._on_change is not None:
            self._on_change(self.active, self.waiting)

    def full(self) -> bool:
        """Whether a new request would be turned away."""
        busy = self._lock.locked() or self.waiting > 0
        return busy and self.waiting >= self.queue_size

    @contextlib.asynccontextmanager
    async def slot(self) -> AsyncIterator[None]:
        """Hold the backend for the duration of the block; raises QueueFull if no room."""
        if self.full():
            raise QueueFull
        self.waiting += 1
        self._changed()
        try:
            await self._lock.acquire()
        finally:
            self.waiting -= 1
            self._changed()
        self.active += 1
        self._changed()
        try:
            yield
        finally:
            self.active -= 1
            self._lock.release()
            self._changed()
