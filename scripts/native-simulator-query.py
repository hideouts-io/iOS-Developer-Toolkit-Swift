#!/usr/bin/env python3
"""Exec the direct hosted control with the Swift request's private context.

The shell writes a footer only after the native command returns. A workflow timeout
can omit it; the reporter must retain that unknown termination, not invent a signal.
No raw output or context is printed or uploaded.
"""

import json
import os
from pathlib import Path
import stat
import sys
import time


def private_bytes(path: Path, bound: int) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1
                or metadata.st_size > bound):
            raise ValueError("Comparison input is not a bounded private regular file")
        data = stream.read(bound + 1)
        if len(data) > bound:
            raise ValueError("Comparison input exceeded its bound")
        return data


def write_new(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def launch(directory: Path, stage: str) -> None:
    context = json.loads(private_bytes(directory / "context.json", 65536))
    fixed = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
             "NSUnbufferedIO": "YES", "NO_COLOR": "1"}
    optional = {"HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR"}
    if (not isinstance(context, dict) or set(context) != {"environment", "workingDirectory"}
            or not isinstance(context["environment"], dict)
            or not isinstance(context["workingDirectory"], str)
            or context["workingDirectory"] != os.getcwd()):
        raise ValueError("Comparison context has an invalid schema or working directory")
    environment = context["environment"]
    if (not set(fixed) <= set(environment) <= set(fixed) | optional
            or any(environment[key] != value for key, value in fixed.items())
            or any(not isinstance(value, str) or not value or "\x00" in value for value in environment.values())
            or any(environment.get(key) != (os.environ.get(key) or None) for key in optional)):
        raise ValueError("Comparison environment changed between controls")
    prefix = directory / ("native-" + stage)
    output = os.open(str(prefix) + ".stdout", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    error = os.open(str(prefix) + ".stderr", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    source = os.open("/dev/null", os.O_RDONLY)
    write_new(Path(str(prefix) + ".start"), str(time.monotonic_ns()).encode("ascii"))
    os.dup2(source, 0)
    os.dup2(output, 1)
    os.dup2(error, 2)
    os.close(source)
    os.close(output)
    os.close(error)
    os.execve("/usr/bin/xcrun", ["/usr/bin/xcrun", "simctl", "list", "devices", "--json"], environment)


def finish(directory: Path, stage: str, status: str) -> None:
    if not status.isascii() or not status.isdecimal() or not 0 <= int(status) <= 255:
        raise ValueError("Native shell exit status is invalid")
    prefix = directory / ("native-" + stage)
    started = int(private_bytes(Path(str(prefix) + ".start"), 64))
    receipt = {"elapsedMilliseconds": (time.monotonic_ns() - started) / 1_000_000,
               "shellExitStatus": int(status)}
    write_new(Path(str(prefix) + ".json"), json.dumps(receipt).encode("utf-8"))


def main(arguments: list[str]) -> None:
    if len(arguments) not in (4, 5) or arguments[3] not in {"before", "after"}:
        raise ValueError("Use native-simulator-query.py launch DIRECTORY STAGE or finish DIRECTORY STAGE STATUS")
    directory = Path(arguments[2])
    metadata = directory.lstat()
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if (not directory.is_absolute() or not directory.resolve(strict=True).is_relative_to(temporary)
            or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700):
        raise ValueError("Comparison requires its dedicated owner-only RUNNER_TEMP directory")
    if arguments[1] == "launch" and len(arguments) == 4:
        launch(directory, arguments[3])
    elif arguments[1] == "finish" and len(arguments) == 5:
        finish(directory, arguments[3], arguments[4])
    else:
        raise ValueError("Comparison command or argument count is invalid")


if __name__ == "__main__":
    main(sys.argv)
