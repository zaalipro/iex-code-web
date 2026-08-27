#!/usr/bin/env python3
"""Run one shell command as a dedicated POSIX process-group leader."""

import os
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit(64)

    try:
        os.setsid()
    except PermissionError:
        # Erlang ports are normally already launched as process-group leaders;
        # in that case setsid(2) correctly returns EPERM and the existing group
        # is already the private kill boundary we need.
        if os.getpgrp() != os.getpid():
            raise

    if sys.argv[1] == "--exec":
        if len(sys.argv) < 3:
            sys.exit(64)
        os.execvp(sys.argv[2], sys.argv[2:])
    elif len(sys.argv) == 2:
        os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])
    else:
        sys.exit(64)


if __name__ == "__main__":
    main()
