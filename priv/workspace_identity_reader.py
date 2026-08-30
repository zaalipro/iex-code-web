import hashlib
import json
import os
import stat
import struct
import sys


def send(value):
    data = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(data)) + data)
    sys.stdout.buffer.flush()


def receive():
    head = sys.stdin.buffer.read(4)
    if len(head) != 4:
        return {}
    size = struct.unpack(">I", head)[0]
    if size > 1024:
        return {}
    return json.loads(sys.stdin.buffer.read(size))


def object_identity(info):
    return (info.st_mode, info.st_ino, info.st_dev)


def open_chain(root, relative_path):
    components = relative_path.split("/")
    if (
        not components
        or relative_path.startswith("/")
        or any(component in ("", ".", "..") or "\0" in component for component in components)
    ):
        raise OSError("unsafe path")

    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        raise OSError("O_NOFOLLOW unavailable")

    common = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | nofollow
    directory = common | os.O_DIRECTORY
    parents = [os.open(root, directory)]

    for component in components[:-1]:
        parents.append(os.open(component, directory, dir_fd=parents[-1]))

    final_fd = os.open(components[-1], common, dir_fd=parents[-1])
    return parents, final_fd, components


def rewalk_matches(root, components, held_parents, held_final):
    fresh = []
    final_fd = None
    try:
        nofollow = os.O_NOFOLLOW
        common = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | nofollow
        directory = common | os.O_DIRECTORY
        fresh.append(os.open(root, directory))
        for component in components[:-1]:
            fresh.append(os.open(component, directory, dir_fd=fresh[-1]))
        final_fd = os.open(components[-1], common, dir_fd=fresh[-1])

        parents_match = all(
            object_identity(os.fstat(old)) == object_identity(os.fstat(new))
            for old, new in zip(held_parents, fresh)
        )
        return parents_match and object_identity(os.fstat(held_final)) == object_identity(os.fstat(final_fd))
    except OSError:
        return False
    finally:
        if final_fd is not None:
            os.close(final_fd)
        for descriptor in reversed(fresh):
            os.close(descriptor)


def main():
    root, relative_path, cap_text = sys.argv[1:4]
    cap = int(cap_text)
    parents = []
    final_fd = None
    bytes_read = 0
    digest = ""
    status = "changed"

    try:
        parents, final_fd, components = open_chain(root, relative_path)
        opened = os.fstat(final_fd)
        send(
            {
                "event": "opened",
                "mode": opened.st_mode,
                "size": opened.st_size,
                "inode": opened.st_ino,
                "device": opened.st_dev,
            }
        )

        if not receive().get("continue"):
            raise OSError("aborted")
        if not stat.S_ISREG(opened.st_mode):
            raise OSError("not regular")

        hasher = hashlib.sha256()
        remaining = cap + 1
        while remaining > 0:
            chunk = os.read(final_fd, remaining)
            if not chunk:
                break
            hasher.update(chunk)
            bytes_read += len(chunk)
            remaining -= len(chunk)

        final_info = os.fstat(final_fd)
        stable = (
            object_identity(opened) == object_identity(final_info)
            and opened.st_size == final_info.st_size
            and rewalk_matches(root, components, parents, final_fd)
        )
        status = "too_large" if bytes_read > cap else ("ok" if stable else "changed")
        digest = hasher.hexdigest() if status == "ok" else ""
    except Exception:
        status = "changed"
    finally:
        if final_fd is not None:
            os.close(final_fd)
        for descriptor in reversed(parents):
            os.close(descriptor)

    try:
        send(
            {
                "event": "result",
                "status": status,
                "digest": digest,
                "bytes_read": bytes_read,
                "closed": True,
            }
        )
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
    os._exit(0)
