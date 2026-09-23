#!/usr/bin/env python3
"""A scriptable /dev/guild client for the token-accounting tests.

Reads one command per line on stdin and answers each with one line on stdout,
so the controlling test always knows what state the client is in without
sleeping. Handles are small integers chosen by the client.

Commands:
    pid                  -> "pid <n>"
    open                 -> "opened <handle>"
    take <handle>        -> "token" once a token has been read (blocks)
    try <handle>         -> "token", or "empty" when the pool has none (EAGAIN)
    give <handle>        -> "gave"
    close <handle>       -> "closed"
    fork                 -> "forked <pid>": a child that inherits every open
                            handle and then only waits to be killed
    exit                 -> exits without closing anything explicitly
Any OSError is answered with "error <ERRNO-NAME>".
"""

from __future__ import annotations

import errno
import fcntl
import os
import signal
import sys

DEVICE = "/dev/guild"


def set_nonblocking(fd: int, enabled: bool) -> None:
    """Toggle the ``O_NONBLOCK`` flag on a file descriptor.

    Parameters
    ----------
    fd : int
        The file descriptor whose flags are to be modified.
    enabled : bool
        ``True`` to set ``O_NONBLOCK``, ``False`` to clear it.

    Returns
    -------
    None
        The descriptor's flags are updated in place.
    """
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    flags = flags | os.O_NONBLOCK if enabled else flags & ~os.O_NONBLOCK
    fcntl.fcntl(fd, fcntl.F_SETFL, flags)


def open_device(handles: dict[int, int]) -> str:
    """Open a new file descriptor on ``/dev/guild`` and register a handle.

    The new handle is one greater than the largest handle currently open,
    or ``1`` when ``handles`` is empty.

    Parameters
    ----------
    handles : dict[int, int]
        Mapping of client-chosen handle to open file descriptor. Updated in
        place with the newly opened descriptor.

    Returns
    -------
    str
        ``"opened <handle>"``, where ``<handle>`` is the integer handle
        assigned to the newly opened descriptor.
    """
    handle = max(handles, default=0) + 1
    handles[handle] = os.open(DEVICE, os.O_RDWR | os.O_CLOEXEC)
    return f"opened {handle}"


def fork_holder() -> str:
    """Fork a child that inherits every open handle and then idles.

    The child process keeps its inherited file descriptors open and waits
    to be signalled; it never returns from this function. The parent
    process returns immediately.

    Returns
    -------
    str
        ``"forked <pid>"``, where ``<pid>`` is the child's process ID, as
        seen by the parent. The child process never reaches this return.
    """
    child = os.fork()
    if child == 0:
        # Keep the inherited descriptors open and do nothing else.
        while True:
            signal.pause()
    return f"forked {child}"


def read_token(fd: int, *, blocking: bool) -> str:
    """Read one token byte from a device handle.

    Parameters
    ----------
    fd : int
        The open file descriptor to read from.
    blocking : bool
        ``True`` to wait for a token to become available, ``False`` to
        return immediately when the pool has none.

    Returns
    -------
    str
        ``"token"`` once a token byte has been read; ``"empty"`` when
        ``blocking`` is ``False`` and no token is available (``EAGAIN``);
        ``"error EOF"`` when the read returns zero bytes.

    Raises
    ------
    OSError
        Propagated for any read or flag failure other than ``EAGAIN``, and
        caught by :func:`main` to produce an ``"error <ERRNO-NAME>"``
        response.
    """
    set_nonblocking(fd, not blocking)
    try:
        return "token" if os.read(fd, 1) else "error EOF"
    except BlockingIOError:
        return "empty"
    finally:
        set_nonblocking(fd, False)


def run_command(handles: dict[int, int], words: list[str]) -> str:
    """Dispatch one parsed command line to the matching action.

    Parameters
    ----------
    handles : dict[int, int]
        Mapping of client-chosen handle to open file descriptor. Read for
        commands that operate on an existing handle, and updated in place
        by ``open`` and ``close``.
    words : list[str]
        The whitespace-split words of the command line, with the command
        name first.

    Returns
    -------
    str
        The command's response: ``"pid <n>"`` for ``pid``; ``"opened
        <handle>"`` for ``open``; ``"forked <pid>"`` for ``fork``; the
        result of :func:`read_token` (``"token"``, ``"empty"`` or ``"error
        EOF"``) for ``take`` and ``try``; ``"gave"`` for ``give``;
        ``"closed"`` for ``close``; ``"error unknown-command-<cmd>"`` for
        an unrecognised command; or ``"error empty-command"`` when
        ``words`` is empty.

    Raises
    ------
    ValueError
        Propagated when a ``<handle>`` argument is not an integer.
    KeyError
        Propagated when ``<handle>`` is not a key in ``handles``.
    OSError
        Propagated from the underlying ``os`` and :func:`read_token`
        calls; caught by :func:`main` to produce an ``"error
        <ERRNO-NAME>"`` response.
    """
    match words:
        case ["pid"]:
            return f"pid {os.getpid()}"
        case ["open"]:
            return open_device(handles)
        case ["fork"]:
            return fork_holder()
        case ["take", handle]:
            return read_token(handles[int(handle)], blocking=True)
        case ["try", handle]:
            return read_token(handles[int(handle)], blocking=False)
        case ["give", handle]:
            os.write(handles[int(handle)], b"+")
            return "gave"
        case ["close", handle]:
            os.close(handles.pop(int(handle)))
            return "closed"
        case [command, *_]:
            return f"error unknown-command-{command}"
    return "error empty-command"


def main() -> int:
    """Read commands from stdin and print one response per line.

    Reads one whitespace-split command per line from stdin until an
    ``exit`` command or end of input, dispatching each to
    :func:`run_command` and printing its response, flushed immediately, so
    the controlling test always knows what state the client is in.
    ``OSError`` raised while running a command is caught and reported as
    ``"error <ERRNO-NAME>"`` (or ``"error <errno>"`` when the errno has no
    known name); ``ValueError`` and ``KeyError`` from a malformed or
    unknown handle are not caught and propagate, terminating the process.

    Returns
    -------
    int
        ``0`` on a normal ``exit`` command or end of input.
    """
    handles: dict[int, int] = {}
    for line in sys.stdin:
        words = line.split()
        if not words:
            continue
        if words[0] == "exit":
            return 0
        try:
            answer = run_command(handles, words)
        except OSError as error:
            answer = f"error {errno.errorcode.get(error.errno or 0, error.errno)}"
        print(answer, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
