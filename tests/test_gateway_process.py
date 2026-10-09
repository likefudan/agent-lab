"""Starting and stopping the gateway process, with a fake gateway."""

from __future__ import annotations

import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from agent_lab import paths
from agent_lab.backend.process import BackendError, State
from agent_lab.gateway import process
from tests.test_backend_process import free_port, port_free

FAKE = Path(__file__).with_name("fake_gateway.py")


def command(port: int, mode: str) -> list[str]:
    return [sys.executable, str(FAKE), str(port), mode, process.MODULE]


@pytest.fixture
def gateway(lab_home: Path) -> Iterator[None]:
    yield
    process.stop(timeout=2)


def test_start_status_stop(gateway: None) -> None:
    port = free_port()
    status, created = process.start("ci-tiny", port, "m", 20, command(port, "ok"))
    assert created and status.state is State.RUNNING  # /healthz answers, even if 503
    assert status.ready is not None and status.ready["hf_hub_offline"] == "1"
    assert status.record is not None
    pid = status.record.pid
    now = process.status()
    assert now.state is State.RUNNING
    assert now.queue == {"pid": pid, "active": 0, "waiting": 0}
    again, created_again = process.start("ci-tiny", port, "m", 20, command(port, "ok"))
    assert not created_again and again.record is not None and again.record.pid == pid
    record, was_running = process.stop()
    assert record is not None and record.pid == pid and was_running
    assert process.status().state is State.STOPPED
    assert port_free(port)
    for path in (paths.gateway_state(), paths.gateway_ready(), paths.gateway_queue()):
        assert not path.exists()


def test_failed_start_reports_the_log(gateway: None) -> None:
    port = free_port()
    with pytest.raises(BackendError, match=r"(?s)exited with status 1.*cannot load the tokenizer"):
        process.start("ci-tiny", port, "m", 20, command(port, "exit"))
    assert process.status().state is State.STOPPED
