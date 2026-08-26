#!/usr/bin/env python3
"""
PTY Shim for IexCode Interactive Terminal.
Bridges Erlang Port stdio with POSIX PTY master/slave pair.
Protocol: 4-byte length-prefixed binary packets ({:packet, 4}).
"""

import fcntl
import os
import pty
import selectors
import shlex
import signal
import struct
import sys
import termios
import time

# Ignore SIGPIPE to avoid BrokenPipeError on port close
try:
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
except Exception:
    pass

OP_INPUT = 0x01
OP_RESIZE = 0x02
OP_SIGNAL = 0x03
OP_CLOSE = 0x04

OP_OUTPUT = 0x01
OP_EXIT = 0x02
OP_READY = 0x03
OP_INTERRUPT_BOUNDARY = 0x04


def send_packet(opcode: int, payload: bytes = b""):
    body = bytes([opcode]) + payload
    length = len(body)
    header = struct.pack(">I", length)
    try:
        sys.stdout.buffer.write(header + body)
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError):
        sys.exit(0)


def set_winsize(fd: int, cols: int, rows: int):
    try:
        ws = struct.pack("HHHH", max(1, rows), max(1, cols), 0, 0)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, ws)
    except OSError:
        pass


def write_master(fd: int, data: bytes, child_pid: int = 0):
    offset = 0
    deadline = time.monotonic() + 1.0
    while offset < len(data):
        if time.monotonic() > deadline:
            break
        if child_pid > 0:
            try:
                wpid, _ = os.waitpid(child_pid, os.WNOHANG)
                if wpid != 0:
                    break
            except (ChildProcessError, OSError):
                break
        try:
            n = os.write(fd, data[offset:])
            if n == 0:
                break
            offset += n
            deadline = time.monotonic() + 1.0
        except (BlockingIOError, InterruptedError):
            try:
                chunk = os.read(fd, 65536)
                if chunk:
                    send_packet(OP_OUTPUT, chunk)
            except (BlockingIOError, InterruptedError, OSError):
                time.sleep(0.001)
        except OSError:
            break


def kill_child_group(child_pid: int):
    if child_pid <= 0:
        return
    for sig in (signal.SIGHUP, signal.SIGTERM):
        try:
            os.killpg(child_pid, sig)
        except ProcessLookupError:
            break
        except OSError:
            pass

    deadline = time.monotonic() + 0.3
    while time.monotonic() < deadline:
        try:
            pid, _ = os.waitpid(child_pid, os.WNOHANG)
            if pid != 0:
                return
        except (ChildProcessError, OSError):
            return
        time.sleep(0.05)

    try:
        os.killpg(child_pid, signal.SIGKILL)
        os.waitpid(child_pid, os.WNOHANG)
    except (ChildProcessError, ProcessLookupError, OSError):
        pass


def parse_args():
    cols = 80
    rows = 24
    cwd = "."
    shell = ""
    args = sys.argv[1:]
    i = 0
    extra = []
    while i < len(args):
        if args[i] == "--cols" and i + 1 < len(args):
            cols = int(args[i + 1])
            i += 2
        elif args[i] == "--rows" and i + 1 < len(args):
            rows = int(args[i + 1])
            i += 2
        elif args[i] == "--cwd" and i + 1 < len(args):
            cwd = args[i + 1]
            i += 2
        elif args[i] == "--shell" and i + 1 < len(args):
            shell = args[i + 1]
            i += 2
        else:
            extra.append(args[i])
            i += 1
    return cols, rows, cwd, shell, extra


def main():
    cols, rows, cwd, shell, extra_args = parse_args()

    shell_cmd = []
    if shell:
        shell_cmd = shlex.split(shell)
    elif extra_args:
        shell_cmd = extra_args
    else:
        if os.path.exists("/bin/zsh"):
            shell_cmd = ["/bin/zsh", "-f"]
        elif os.path.exists("/bin/bash"):
            shell_cmd = ["/bin/bash", "--norc"]
        else:
            shell_cmd = ["/bin/sh"]

    master_fd, slave_fd = pty.openpty()
    set_winsize(master_fd, cols, rows)

    os.set_inheritable(master_fd, False)
    os.set_inheritable(slave_fd, True)

    child_pid = os.fork()
    if child_pid == 0:
        # Child process
        os.close(master_fd)
        os.setsid()

        try:
            fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        except OSError:
            pass

        try:
            attrs = termios.tcgetattr(slave_fd)
            attrs[3] = attrs[3] & ~termios.ICANON
            termios.tcsetattr(slave_fd, termios.TCSANOW, attrs)
        except Exception:
            pass

        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)

        if cwd and os.path.isdir(cwd):
            try:
                os.chdir(cwd)
            except OSError:
                pass

        env = os.environ.copy()
        env["TERM"] = env.get("TERM", "xterm-256color")
        env["COLORTERM"] = "truecolor"
        env["PROMPT_EOL_MARK"] = ""
        env["PROMPT"] = "$ "
        env["PS1"] = "$ "
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"

        try:
            os.execvpe(shell_cmd[0], shell_cmd, env)
        except Exception as e:
            sys.stderr.write(f"Failed to exec {shell_cmd}: {e}\n")
            sys.exit(127)

    # Parent process
    os.close(slave_fd)
    os.set_blocking(master_fd, False)
    os.set_blocking(sys.stdin.fileno(), False)

    def signal_handler(sig, _frame):
        kill_child_group(child_pid)
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    send_packet(OP_READY, struct.pack(">i", child_pid))

    sel = selectors.DefaultSelector()
    sel.register(sys.stdin.fileno(), selectors.EVENT_READ, data="stdin")
    sel.register(master_fd, selectors.EVENT_READ, data="pty")

    stdin_buf = bytearray()
    pending_interrupt_boundaries = []
    running = True

    try:
        while running:
            events = sel.select(timeout=0.01)

            # Check child status
            try:
                wpid, status = os.waitpid(child_pid, os.WNOHANG)
                if wpid == child_pid:
                    exit_code = os.waitstatus_to_exitcode(status)
                    # Drain remaining bytes from master_fd
                    try:
                        while True:
                            chunk = os.read(master_fd, 65536)
                            if not chunk:
                                break
                            send_packet(OP_OUTPUT, chunk)
                    except OSError:
                        pass
                    send_packet(OP_EXIT, struct.pack(">i", exit_code))
                    running = False
                    break
            except (ChildProcessError, OSError):
                running = False
                break

            # A SIGINT acknowledgement alone is not a safe mutation boundary:
            # the foreground job may ignore it. Only tell the BEAM owner that
            # the boundary was reached after the PTY's foreground process group
            # returns to the original interactive shell.
            if pending_interrupt_boundaries:
                try:
                    if os.tcgetpgrp(master_fd) == child_pid:
                        for boundary in pending_interrupt_boundaries:
                            send_packet(OP_INTERRUPT_BOUNDARY, boundary)
                        pending_interrupt_boundaries.clear()
                except OSError:
                    pass

            for key, _mask in events:
                if key.data == "stdin":
                    try:
                        raw = sys.stdin.buffer.read()
                    except OSError:
                        raw = None

                    if raw is None or len(raw) == 0:
                        # Erlang Port closed / EOF
                        kill_child_group(child_pid)
                        running = False
                        break

                    stdin_buf.extend(raw)

                    # Process length-prefixed frames in a fast batch
                    pos = 0
                    buf_len = len(stdin_buf)
                    input_chunks = []

                    while pos + 4 <= buf_len:
                        (length,) = struct.unpack(">I", stdin_buf[pos : pos + 4])
                        if pos + 4 + length > buf_len:
                            break
                        packet = bytes(stdin_buf[pos + 4 : pos + 4 + length])
                        pos += 4 + length

                        if not packet:
                            continue

                        opcode = packet[0]
                        payload = packet[1:]

                        if opcode == OP_INPUT:
                            input_chunks.append(payload)
                        elif opcode == OP_RESIZE:
                            if input_chunks:
                                write_master(master_fd, b"".join(input_chunks), child_pid)
                                input_chunks = []
                            if len(payload) >= 4:
                                cols_val, rows_val = struct.unpack(">HH", payload[:4])
                                set_winsize(master_fd, cols_val, rows_val)
                        elif opcode == OP_SIGNAL:
                            if input_chunks:
                                write_master(master_fd, b"".join(input_chunks), child_pid)
                                input_chunks = []
                            if len(payload) >= 1:
                                sig = payload[0]
                                if len(payload) >= 9:
                                    pending_interrupt_boundaries.append(payload[1:9])
                                try:
                                    # Interactive shells put foreground jobs in
                                    # their own process group. Signalling the
                                    # shell's original group leaves commands
                                    # such as `sleep` running. Ask the PTY for
                                    # its current foreground group so Ctrl+C,
                                    # Ctrl+Z, and continuation target the job
                                    # the user actually sees.
                                    foreground_pgid = os.tcgetpgrp(master_fd)
                                    os.killpg(foreground_pgid, sig)
                                except (ProcessLookupError, OSError):
                                    try:
                                        os.killpg(child_pid, sig)
                                    except (ProcessLookupError, OSError):
                                        pass
                        elif opcode == OP_CLOSE:
                            kill_child_group(child_pid)
                            running = False
                            break

                    if input_chunks:
                        write_master(master_fd, b"".join(input_chunks), child_pid)

                    if pos > 0:
                        del stdin_buf[:pos]

                elif key.data == "pty":
                    try:
                        chunk = os.read(master_fd, 65536)
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        # EIO indicates slave closed
                        chunk = b""

                    if chunk:
                        send_packet(OP_OUTPUT, chunk)
                    else:
                        # Slave closed
                        running = False
                        break

    finally:
        kill_child_group(child_pid)
        try:
            os.close(master_fd)
        except OSError:
            pass
        try:
            sel.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()
