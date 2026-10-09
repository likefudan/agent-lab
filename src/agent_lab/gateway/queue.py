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


class Place:
    """A request's place in the queue, taken when the request is accepted."""

    def __init__(self, queue: RequestQueue) -> None:
        self.queue = queue
        self.waiting = True

    def give_up(self) -> None:
        """Leave the queue if still waiting; a no-op once the request has run."""
        if self.waiting:
            self.waiting = False
            self.queue.waiting -= 1
            self.queue._changed()


class RequestQueue:
    def __init__(self, queue_size: int, on_change: Callable[[int, int], None] | None = None):
        self.queue_size = queue_size
        self._lock = asyncio.Lock()  # FIFO: waiters are woken in the order they arrived
        self.waiting = 0  # accepted, not yet running (including requests just accepted)
        self.active = 0
        self._on_change = on_change

    def _changed(self) -> None:
        if self._on_change is not None:
            self._on_change(self.active, self.waiting)

    def full(self) -> bool:
        """Whether a new request would be turned away: one running plus queue_size waiting."""
        return self.active + self.waiting >= 1 + self.queue_size

    def reserve(self) -> Place:
        """Take a place now (raises QueueFull), so that the answer to the client can be a 429."""
        if self.full():
            raise QueueFull
        self.waiting += 1
        self._changed()
        return Place(self)

    @contextlib.asynccontextmanager
    async def slot(self, place: Place | None = None) -> AsyncIterator[None]:
        """Hold the backend for the duration of the block, in arrival order."""
        place = place or self.reserve()
        try:
            await self._lock.acquire()
        except BaseException:
            place.give_up()
            raise
        place.waiting = False
        self.waiting -= 1
        self.active += 1
        self._changed()
        try:
            yield
        finally:
            self.active -= 1
            self._lock.release()
            self._changed()
