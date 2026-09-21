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
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    flags = flags | os.O_NONBLOCK if enabled else flags & ~os.O_NONBLOCK
    fcntl.fcntl(fd, fcntl.F_SETFL, flags)


def run_command(handles: dict[int, int], words: list[str]) -> str:
    command = words[0]
    if command == "pid":
        return f"pid {os.getpid()}"
    if command == "open":
        handle = max(handles, default=0) + 1
        handles[handle] = os.open(DEVICE, os.O_RDWR | os.O_CLOEXEC)
        return f"opened {handle}"
    if command == "fork":
        child = os.fork()
        if child == 0:
            # Keep the inherited descriptors open and do nothing else.
            while True:
                signal.pause()
        return f"forked {child}"

    fd = handles[int(words[1])]
    if command == "take":
        set_nonblocking(fd, False)
        return "token" if os.read(fd, 1) else "error EOF"
    if command == "try":
        set_nonblocking(fd, True)
        try:
            return "token" if os.read(fd, 1) else "error EOF"
        except BlockingIOError:
            return "empty"
        finally:
            set_nonblocking(fd, False)
    if command == "give":
        os.write(fd, b"+")
        return "gave"
    if command == "close":
        os.close(handles.pop(int(words[1])))
        return "closed"
    return f"error unknown-command-{command}"


def main() -> int:
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
