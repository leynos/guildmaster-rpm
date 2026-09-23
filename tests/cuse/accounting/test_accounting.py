#!/usr/bin/env python3
"""Token accounting against the real /dev/guild, with capacity two.

Every client is a separate gmclient.py process run as the authorized test
user. The test drives them over pipes and never infers state from elapsed
time alone:

* "the pool is empty" is a non-blocking read answering EAGAIN;
* "this client is waiting" is the kernel reporting that the process is
  inside read(2), polled with a bound, together with the absence of an answer
  on its pipe;
* "this client was admitted" is its answer arriving, awaited with a bound.

The scenarios record what upstream actually does. In particular, guildmaster
keys its accounts on the process that *opened* the device, not on the open
file description its README mentions; the multiple-handle and inherited-handle
scenarios pin that behaviour down.
"""

from __future__ import annotations

import os
import platform
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

CAPACITY = 2
WAIT_SECONDS = 20.0
CLIENT = Path(__file__).with_name("gmclient.py")
MEMBER = os.environ.get("GM_MEMBER", "gm-member")
READ_SYSCALL = {"x86_64": "0", "aarch64": "63"}[platform.machine()]


class CheckFailed(Exception):
    """Raised when a scenario observes behaviour other than what it expects.

    Parameters
    ----------
    *args : object
        Passed through to :class:`Exception`; conventionally a single
        message describing which check failed and why.
    """


class Client:
    """A gmclient.py process run as the authorized test user, driven over pipes.

    Parameters
    ----------
    name : str
        A short label for the client, used to identify it in failure
        messages.

    Attributes
    ----------
    name : str
        The label passed to the constructor.
    process : subprocess.Popen[str]
        The running gmclient.py process, connected via ``setpriv``.
    pid : int
        The process ID of the client, as reported by its own ``pid``
        command, verified to match the started process.

    Raises
    ------
    CheckFailed
        If the client's reported PID does not match the PID of the process
        that was started.
    """

    def __init__(self, name: str) -> None:
        self.name = name
        self.process = subprocess.Popen(
            # setpriv execs the client directly, so this process *is* the
            # client: killing it kills the token holder, not a wrapper.
            [
                "setpriv",
                f"--reuid={MEMBER}",
                f"--regid={MEMBER}",
                "--init-groups",
                sys.executable,
                str(CLIENT),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.pid = int(self.ask("pid").split()[1])
        if self.pid != self.process.pid:
            raise CheckFailed(f"{name}: the client is not the process that was started")

    def send(self, command: str) -> None:
        """Write one command line to the client's stdin and flush it.

        Parameters
        ----------
        command : str
            The command to send, without a trailing newline.

        Returns
        -------
        None
        """
        assert self.process.stdin is not None, "client stdin pipe was not created"
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def has_answer(self, timeout: float) -> bool:
        """Report whether the client's stdout has an answer ready to read.

        Parameters
        ----------
        timeout : float
            Seconds to wait for output to become readable; ``0`` polls
            without blocking.

        Returns
        -------
        bool
            ``True`` if the client's stdout is ready for reading within
            ``timeout`` seconds, ``False`` otherwise.
        """
        assert self.process.stdout is not None, "client stdout pipe was not created"
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        return bool(ready)

    def answer(self) -> str:
        """Read and return the client's next answer line.

        Returns
        -------
        str
            The next answer line from the client's stdout, with the
            trailing newline stripped.

        Raises
        ------
        CheckFailed
            If no answer arrives within :data:`WAIT_SECONDS`.
        """
        if not self.has_answer(WAIT_SECONDS):
            raise CheckFailed(f"{self.name}: no answer within {WAIT_SECONDS}s")
        assert self.process.stdout is not None, "client stdout pipe was not created"
        return self.process.stdout.readline().strip()

    def ask(self, command: str) -> str:
        """Send a command and return the client's answer to it.

        Parameters
        ----------
        command : str
            The command to send, without a trailing newline.

        Returns
        -------
        str
            The client's answer line, with the trailing newline stripped.

        Raises
        ------
        CheckFailed
            If no answer arrives within :data:`WAIT_SECONDS`.
        """
        self.send(command)
        return self.answer()

    def expect(self, command: str, wanted: str) -> None:
        """Send a command and assert that the answer matches exactly.

        Parameters
        ----------
        command : str
            The command to send, without a trailing newline.
        wanted : str
            The exact answer expected in response.

        Returns
        -------
        None

        Raises
        ------
        CheckFailed
            If no answer arrives within :data:`WAIT_SECONDS`, or if the
            answer received does not equal ``wanted``.
        """
        got = self.ask(command)
        if got != wanted:
            raise CheckFailed(
                f"{self.name}: '{command}' answered '{got}', expected '{wanted}'"
            )

    def open(self) -> int:
        """Send ``open`` and return the handle the client assigned.

        Returns
        -------
        int
            The integer handle reported in the client's ``opened
            <handle>`` answer.

        Raises
        ------
        CheckFailed
            If no answer arrives within :data:`WAIT_SECONDS`, or if the
            answer does not start with ``"opened "``.
        """
        answer = self.ask("open")
        if not answer.startswith("opened "):
            raise CheckFailed(f"{self.name}: open answered '{answer}'")
        return int(answer.split()[1])

    def wait_until_blocked_in_read(self) -> None:
        """Positively observe the client sleeping inside read(2).

        Polls ``/proc/<pid>/syscall`` and the client's stdout, bounded by
        :data:`WAIT_SECONDS`, until the process is inside a read(2) syscall
        with no answer yet pending.

        Returns
        -------
        None

        Raises
        ------
        CheckFailed
            If the client is never observed blocked in read(2) within
            :data:`WAIT_SECONDS`.
        """
        deadline = time.monotonic() + WAIT_SECONDS
        while time.monotonic() < deadline:
            syscall = Path(f"/proc/{self.pid}/syscall").read_text().split()
            if syscall and syscall[0] == READ_SYSCALL and not self.has_answer(0):
                return
            time.sleep(0.05)
        raise CheckFailed(f"{self.name}: never observed blocked in read(2)")

    def kill(self) -> None:
        """Send SIGKILL to the client and wait for it to exit.

        Returns
        -------
        None
        """
        self.process.send_signal(signal.SIGKILL)
        self.process.wait(timeout=WAIT_SECONDS)

    def finish(self) -> None:
        """Ask the client to exit cleanly, killing it if that fails.

        Sends ``exit`` and waits for the process to exit, bounded by
        :data:`WAIT_SECONDS`. Does nothing if the process has already
        exited. Falls back to SIGKILL if the pipe is broken or the process
        does not exit in time.

        Returns
        -------
        None
        """
        if self.process.poll() is None:
            try:
                self.send("exit")
                self.process.wait(timeout=WAIT_SECONDS)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()


def drain(client: Client, handle: int) -> int:
    """Take tokens without blocking until the pool is empty; return how many."""
    taken = 0
    while client.ask(f"try {handle}") == "token":
        taken += 1
        if taken > CAPACITY + 8:
            raise CheckFailed("the pool yielded far more tokens than its capacity")
    return taken


def expect_pool(probe: Client, handle: int, wanted: int, why: str) -> None:
    """The pool holds exactly `wanted` tokens; leaves it as it found it."""
    taken = drain(probe, handle)
    for _ in range(taken):
        probe.expect(f"give {handle}", "gave")
    if taken != wanted:
        raise CheckFailed(f"{why}: {taken} token(s) available, expected {wanted}")
    print(f"ok: {why}: {taken} token(s) available")


def scenario_capacity_and_waiting(clients: list[Client]) -> None:
    a, b, c, probe = (Client(n) for n in ("a", "b", "c", "probe"))
    clients += [a, b, c, probe]
    ha, hb, hc, hp = a.open(), b.open(), c.open(), probe.open()
    expect_pool(probe, hp, CAPACITY, "a fresh pool holds the configured capacity")

    a.expect(f"take {ha}", "token")
    b.expect(f"take {hb}", "token")
    print("ok: two clients are admitted")
    probe.expect(f"try {hp}", "empty")
    print("ok: the pool is then empty (EAGAIN)")

    c.send(f"take {hc}")
    c.wait_until_blocked_in_read()
    print("ok: a third client waits inside read(2)")

    a.expect(f"give {ha}", "gave")
    if c.answer() != "token":
        raise CheckFailed("the waiting client was not admitted when a token returned")
    print("ok: returning a token admits the waiting client")
    probe.expect(f"try {hp}", "empty")

    # Closing the last handle with tokens outstanding returns them.
    b.expect(f"close {hb}", "closed")
    expect_pool(probe, hp, 1, "closing a handle returns its client's token")
    c.expect(f"close {hc}", "closed")
    expect_pool(probe, hp, CAPACITY, "final closure restores full capacity")


def scenario_abrupt_death(clients: list[Client]) -> None:
    victim, waiter, probe = Client("victim"), Client("waiter"), Client("probe")
    clients += [victim, waiter, probe]
    hv, hw, hp = victim.open(), waiter.open(), probe.open()
    victim.expect(f"take {hv}", "token")
    victim.expect(f"take {hv}", "token")
    probe.expect(f"try {hp}", "empty")

    waiter.send(f"take {hw}")
    waiter.wait_until_blocked_in_read()
    victim.kill()
    if waiter.answer() != "token":
        raise CheckFailed("a waiter was not admitted after the holder was killed")
    print("ok: SIGKILL of a holder admits a waiting client")
    waiter.expect(f"give {hw}", "gave")
    expect_pool(probe, hp, CAPACITY, "abrupt death restores the dead client's tokens")


def scenario_unmatched_writes(clients: list[Client]) -> None:
    writer, probe = Client("writer"), Client("probe")
    clients += [writer, probe]
    hw, hp = writer.open(), probe.open()
    for _ in range(5):
        writer.expect(f"give {hw}", "gave")
    expect_pool(probe, hp, CAPACITY, "writes without a matching read do not add tokens")

    writer.expect(f"take {hw}", "token")
    for _ in range(3):
        writer.expect(f"give {hw}", "gave")
    expect_pool(
        probe, hp, CAPACITY, "returning more than was taken does not add tokens"
    )


def scenario_multiple_handles(clients: list[Client]) -> None:
    owner, probe = Client("owner"), Client("probe")
    clients += [owner, probe]
    first, second, hp = owner.open(), owner.open(), probe.open()
    owner.expect(f"take {first}", "token")

    # One account per opening process: the second handle can return a token
    # that was taken through the first.
    owner.expect(f"give {second}", "gave")
    expect_pool(
        probe,
        hp,
        CAPACITY,
        "a token may be returned through another handle of the same process",
    )

    owner.expect(f"take {first}", "token")
    owner.expect(f"close {first}", "closed")
    expect_pool(
        probe,
        hp,
        CAPACITY - 1,
        "closing one of several handles does not return the process's tokens",
    )
    owner.expect(f"close {second}", "closed")
    expect_pool(probe, hp, CAPACITY, "closing the process's last handle returns them")


def scenario_inherited_handles(clients: list[Client]) -> None:
    parent, probe = Client("parent"), Client("probe")
    clients += [parent, probe]
    handle, hp = parent.open(), probe.open()
    parent.expect(f"take {handle}", "token")
    child_pid = int(parent.ask("fork").split()[1])
    try:
        # The child shares the parent's open file description. The kernel
        # releases it only when the last copy is closed, so the parent's
        # death alone returns nothing.
        parent.kill()
        expect_pool(
            probe,
            hp,
            CAPACITY - 1,
            "a token survives its taker while an inherited handle is open",
        )
    finally:
        os.kill(child_pid, signal.SIGKILL)
    deadline = time.monotonic() + WAIT_SECONDS
    while Path(f"/proc/{child_pid}").exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    # Release is asynchronous with respect to the child's exit; await it
    # through the pool itself, with a bound.
    while time.monotonic() < deadline:
        taken = drain(probe, hp)
        for _ in range(taken):
            probe.expect(f"give {hp}", "gave")
        if taken == CAPACITY:
            break
        time.sleep(0.05)
    expect_pool(
        probe, hp, CAPACITY, "closing the last inherited copy returns the token"
    )


SCENARIOS = [
    scenario_capacity_and_waiting,
    scenario_abrupt_death,
    scenario_unmatched_writes,
    scenario_multiple_handles,
    scenario_inherited_handles,
]


def main() -> int:
    failures = 0
    for scenario in SCENARIOS:
        print(f"--- {scenario.__name__}")
        clients: list[Client] = []
        try:
            scenario(clients)
        except CheckFailed as failure:
            failures += 1
            print(f"FAIL: {scenario.__name__}: {failure}", file=sys.stderr)
        finally:
            for client in clients:
                client.finish()
    if failures:
        print(f"{failures} scenario(s) failed", file=sys.stderr)
        return 1
    print("all accounting scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
