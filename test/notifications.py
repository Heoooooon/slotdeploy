# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# Run: python3 test/notifications.py (stdlib only; bash, git and curl required).
"""Real CLI and HTTP notification integration, with no timing-based waits."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from collections.abc import Callable
from typing import override

type Json = None | bool | int | float | str | list[Json] | dict[str, Json]


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    requests: list[tuple[str, dict[str, str], int, str]] = []
    decode: Callable[[str], Json] = json.loads

    class Receiver(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            match decode(self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8")):
                case {"chat_id": str(chat_id), "text": str(text)}:
                    body = {"chat_id": chat_id, "text": text}
                case {"content": str(content)}:
                    body = {"content": content}
                case {"text": str(text)}:
                    body = {"text": text}
                case _:
                    raise AssertionError("notification payload must contain string fields")
            status = 503 if self.path.startswith("/reject") else (
                204 if self.path.startswith("/discord") else 200
            )
            content_type = self.headers["Content-Type"]
            assert content_type == "application/json"
            requests.append((self.path, body, status, content_type))
            self.send_response(status)
            self.end_headers()
            _ = self.wfile.write(b"ok")

        @override
        def log_message(self, format: str, *args: str) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="slotdeploy-notifications-") as tmp:
            t = Path(tmp)
            env = dict(os.environ, HOME=str(t / "home"), GIT_CONFIG_NOSYSTEM="1")
            Path(env["HOME"]).mkdir()
            env["GIT_CONFIG_GLOBAL"] = str(t / "gitconfig")

            def run(*args: str, expected: int = 0) -> str:
                p = subprocess.run(args, env=env, text=True, capture_output=True, check=False)
                assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
                return p.stdout + p.stderr

            _ = run("git", "config", "--global", "user.name", "tester")
            _ = run("git", "config", "--global", "user.email", "tester@example.invalid")
            _ = run("git", "init", "--bare", str(t / "remote.git"))
            _ = run("git", "clone", str(t / "remote.git"), str(t / "app"))
            app = t / "app"
            config = t / "slotdeploy.env"
            root = t / "deploy"
            _ = config.write_text(
                f"REPO_URL={t / 'remote.git'}\nROOT={root}\nBRANCH=preview\n" +
                "BUILD_CMD=bash build.sh\n" +
                f"HEALTH_URL=file://{root}/current/out/index.html\n" +
                "HEALTH_RETRIES=1\nHEALTH_INTERVAL=0\n",
                encoding="utf-8",
            )
            endpoint = f"http://127.0.0.1:{server.server_port}"
            secrets = ["fake-telegram-token", "fake-discord-token", "fake-slack-token", 'private-"chat\\\t\x01']
            env.update(
                SLOTDEPLOY_TELEGRAM_URL=f"{endpoint}/telegram/{secrets[0]}",
                SLOTDEPLOY_TELEGRAM_CHAT_ID=secrets[3],
                SLOTDEPLOY_DISCORD_URL=f"{endpoint}/discord/{secrets[1]}",
                SLOTDEPLOY_SLACK_URL=f"{endpoint}/slack/{secrets[2]}",
            )

            def publish(script: str, subject: str) -> None:
                _ = (app / "build.sh").write_text(script, encoding="utf-8")
                _ = run("git", "-C", str(app), "add", ".")
                _ = run("git", "-C", str(app), "commit", "-m", subject)
                _ = run("git", "-C", str(app), "push", "--force", "origin", "HEAD:preview")

            def deploy(expected: int = 0) -> str:
                return run("bash", str(project / "bin/slotdeploy"), "-c", str(config), "watch", expected=expected)

            def events_since(start: int, expected: list[str]) -> None:
                received = requests[start:]
                assert len(received) == 3 * len(expected), received
                for index, event in enumerate(expected):
                    for path, body, _status, _content_type in received[index * 3 : index * 3 + 3]:
                        provider = path.split("/")[1]
                        key = {"discord": "content", "telegram": "text", "slack": "text"}[provider]
                        assert f"slotdeploy {event} " in body[key], body
                        if "chat_id" in body:
                            assert body["chat_id"] == secrets[3], body

            # Print environment names only after proving credentials are not inherited.
            good = (
                'test -z "${SLOTDEPLOY_TELEGRAM_URL:-}${SLOTDEPLOY_TELEGRAM_CHAT_ID:-}' +
                '${SLOTDEPLOY_DISCORD_URL:-}${SLOTDEPLOY_SLACK_URL:-}" || exit 1\n' +
                "mkdir -p out\nprintf healthy >out/index.html\n"
            )
            publish(good, "healthy")
            output = deploy()
            events_since(0, ["success"])
            assert (root / "current/out/index.html").read_text() == "healthy"
            first = os.readlink(root / "current")

            start = len(requests)
            publish("printf failed >&2\nexit 1\n", "failed")
            output += deploy(expected=1)
            events_since(start, ["failure"])
            assert os.readlink(root / "current") == first

            start = len(requests)
            publish("mkdir -p out\n", "unhealthy")
            output += deploy(expected=1)
            events_since(start, ["failure", "rollback"])
            assert os.readlink(root / "current") == first
            assert (root / "current/out/index.html").read_text() == "healthy"

            start = len(requests)
            for key in ("SLOTDEPLOY_TELEGRAM_URL", "SLOTDEPLOY_DISCORD_URL", "SLOTDEPLOY_SLACK_URL"):
                env[key] = endpoint + "/reject/" + secrets[0]
            publish(good + "printf newer >out/index.html\n", "delivery rejected")
            output += deploy()
            assert len(requests[start:]) == 3
            assert (root / "current/out/index.html").read_text() == "newer"
            publish("exit 1\n", "failed with delivery rejected")
            output += deploy(expected=1)
            # Every persistent log is checked, not just the CLI transcript.
            logs = "".join(p.read_text() for p in root.rglob("*.log"))
            assert not any(secret in output + logs for secret in secrets), "credential appeared in output/logs"
            print("ok   notifications real HTTP: 3 providers, success/failure/rollback, rejected delivery, secrets")
            if evidence := env.get("SLOTDEPLOY_QA_EVIDENCE"):
                captures = [
                    {
                        "method": "POST",
                        "provider": path.split("/")[1],
                        "request_headers": {"Content-Type": content_type},
                        "request_body": {k: "[redacted]" if k == "chat_id" else v for k, v in body.items()},
                        "response_status": status,
                    }
                    for path, body, status, content_type in requests
                ]
                _ = Path(evidence).write_text(json.dumps(captures, indent=2), encoding="utf-8")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        assert not thread.is_alive(), "receiver did not stop"
    print(f"ok   notifications captured {len(requests)} HTTP requests; receiver and fixtures cleaned")


if __name__ == "__main__":
    main()
