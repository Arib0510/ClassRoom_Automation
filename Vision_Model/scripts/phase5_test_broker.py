"""Optional Windows development-only AMQTT broker. Always binds 127.0.0.1, never LAN."""

import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path


async def serve(port, ready):
    from amqtt.broker import Broker

    if not 1024 <= port <= 65535 or ready.exists():
        raise ValueError("Choose an unprivileged port and a new readiness file")
    broker = Broker(
        {
            "listeners": {
                "default": {"type": "tcp", "bind": f"127.0.0.1:{port}", "max_connections": 8}
            },
            "plugins": {
                "amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True}
            },
        }
    )
    await broker.start()
    ready.write_text(
        json.dumps(
            {"bind": "127.0.0.1", "port": port, "pid": os.getpid(), "hardware_tested": False}
        )
    )
    try:
        await asyncio.Event().wait()
    finally:
        await broker.shutdown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("serve", "test"))
    parser.add_argument("--port", type=int)
    parser.add_argument("--ready", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "serve":
        if args.port is None or args.ready is None:
            raise ValueError("serve needs --port and --ready")
        asyncio.run(serve(args.port, args.ready))
        return 0
    if args.output is None:
        raise ValueError("test needs a new --output directory")
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(
        os.environ, PHASE5_REAL_BROKER_TEST="1", PHASE5_BROKER_LOG_ROOT=str(args.output.resolve())
    )
    command = [
        sys.executable,
        "-m",
        "pytest",
        "tests/integration/test_phase5_broker.py",
        "-ra",
        "--junitxml=" + str(args.output / "broker.xml"),
    ]
    result = subprocess.run(
        command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    (args.output / "tests.log").write_text(result.stdout, encoding="utf-8")
    print(result.stdout)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
