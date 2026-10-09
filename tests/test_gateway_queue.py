from __future__ import annotations

import asyncio

import pytest

from agent_lab.gateway.queue import QueueFull, RequestQueue


def test_one_at_a_time_in_order_and_full() -> None:
    async def scenario() -> None:
        changes: list[tuple[int, int]] = []
        queue = RequestQueue(2, lambda active, waiting: changes.append((active, waiting)))
        order: list[int] = []
        release = asyncio.Event()

        async def request(n: int) -> None:
            async with queue.slot():
                order.append(n)
                await release.wait()

        tasks = [asyncio.ensure_future(request(n)) for n in range(3)]
        await asyncio.sleep(0.01)
        assert (queue.active, queue.waiting) == (1, 2)
        assert queue.full()
        with pytest.raises(QueueFull):
            async with queue.slot():
                pass
        release.set()
        await asyncio.gather(*tasks)
        assert order == [0, 1, 2]
        assert (queue.active, queue.waiting) == (0, 0)
        assert changes[-1] == (0, 0)

    asyncio.run(scenario())


def test_cancelled_waiter_gives_up_its_place() -> None:
    async def scenario() -> None:
        queue = RequestQueue(1)
        release = asyncio.Event()

        async def request() -> None:
            async with queue.slot():
                await release.wait()

        first = asyncio.ensure_future(request())
        second = asyncio.ensure_future(request())
        await asyncio.sleep(0.01)
        assert queue.full()
        second.cancel()
        await asyncio.sleep(0.01)
        assert (queue.active, queue.waiting) == (1, 0)
        assert not queue.full()
        release.set()
        await first
        assert (queue.active, queue.waiting) == (0, 0)

    asyncio.run(scenario())


def test_queue_size_zero_allows_only_the_running_request() -> None:
    async def scenario() -> None:
        queue = RequestQueue(0)
        assert not queue.full()
        async with queue.slot():
            assert queue.full()

    asyncio.run(scenario())


def test_places_are_taken_when_accepted() -> None:
    async def scenario() -> None:
        queue = RequestQueue(1)
        first = queue.reserve()  # accepted, not yet running
        second = queue.reserve()
        assert (queue.active, queue.waiting) == (0, 2)
        with pytest.raises(QueueFull):  # a third is refused before anything runs
            queue.reserve()
        second.give_up()
        second.give_up()  # only counts once
        assert queue.waiting == 1
        async with queue.slot(first):
            assert (queue.active, queue.waiting) == (1, 0)
            first.give_up()  # no effect once running
            assert (queue.active, queue.waiting) == (1, 0)
        assert (queue.active, queue.waiting) == (0, 0)

    asyncio.run(scenario())
