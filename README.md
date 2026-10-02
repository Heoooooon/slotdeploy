**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

# slotdeploy

**Let non-developers say "put it on preview" — without ever breaking the preview server.**

Designers, marketers, and ops teammates ship their edits to a preview server through an AI agent (or a single terminal command).
If a change fails to build or the server doesn't come back up, **the preview server keeps serving the previous version.**
The production (`main`) branch is never touched. Releasing to production stays a human decision, made after review.

![slotdeploy demo: a good change goes live, a broken build is rejected and the previous page stays up](demo/demo.gif)

- Bash commands (`bin/slotdeploy`, `bin/slotdeploy-push`) and the init helper. Runtime requirements: `bash`, `git`, and `curl`.
- The server checks the `preview` branch every minute from a systemd timer (Linux) or launchd (macOS).
- Works with the stock macOS bash 3.2.

## Why it's safe

```
Teammate's machine                         Preview server
slotdeploy-push push "new banner"          slotdeploy watch  (every minute)
  1. commit on a work branch (work/...)      1. has preview moved?
  2. push the work branch as a backup        2. install -> build -> check in the idle slot (a or b)
  3. point preview at that commit            3. on success: swap the current symlink atomically -> restart
     (never pushes main)                     4. health check fails: swap straight back to the previous slot
                                             5. log the result as one line
```

| Situation | Result |
|---|---|
| Build fails (type error, etc.) | No switch. The previous build keeps serving. `FAIL ... build failed, kept 1a2b3c4` |
| Build passes but the app doesn't come up | Symlink restored to the previous slot, app restarted. `FAIL ... health failed, kept ...` |
| Same failing commit | Not rebuilt every minute. A new commit triggers a fresh attempt |
| Two deploys overlap | A lock lets only one run. Stale locks left by dead processes are cleaned up automatically |
| You want to undo | `slotdeploy-push rollback prev` / `yesterday` / `<commit>` — moves preview only; your local files stay as they are |

The client never pushes `main` and never runs `git reset` or `git stash`. If you edited on top of `main`, your changes are carried over to a new work branch before anything is pushed.

## Install

```bash
git clone https://github.com/Heoooooon/slotdeploy.git
sh slotdeploy/install.sh --source slotdeploy
```

Or install in one line (default `~/.local/bin`, no sudo):

```sh
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
# Update / remove binaries; config, timers and deployed sites are kept.
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh -s -- update
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh -s -- uninstall
```

Use `--bin-dir /usr/local/bin` with appropriate permissions, or `--ref <branch/tag/commit>` to select a version. The default tracks `main`; no release tag is required.

## Quick setup (v0.2.0)

`slotdeploy init` asks for the repository, deployment directory, branch, build/restart commands, health URL and scheduler. Unattended setup:

```bash
slotdeploy -c "$HOME/site/slotdeploy.env" init --yes \
  --repo git@github.com:example/site.git --root "$HOME/site" \
  --build 'npm run build' --install 'npm ci' \
  --health-url http://127.0.0.1:3000/ --timer systemd
```

The config is private (mode 600), and existing files are never overwritten. `--timer systemd` writes user units in `~/.config/systemd/user`; `--timer launchd` writes a plist in `~/Library/LaunchAgents`; `--timer none` writes only config. `--timer-dir`, `--every 60`, `--name` and `--check` customize setup. Timers are **generated, not activated**: init prints the activation command. Run the first deploy manually; user systemd timers need `loginctl enable-linger "$USER"` to continue after logout. macOS launch agents run while the user is logged in.

## Notifications

Set these variables in the **watcher's environment**, not `slotdeploy.env` or Git:

| Provider | Environment variables |
|---|---|
| Telegram | `SLOTDEPLOY_TELEGRAM_URL` (full bot `/sendMessage` URL), `SLOTDEPLOY_TELEGRAM_CHAT_ID` |
| Discord | `SLOTDEPLOY_DISCORD_URL` (webhook URL) |
| Slack | `SLOTDEPLOY_SLACK_URL` (incoming webhook URL) |

The watcher sends `success`, `failure`, and an additional `rollback` when it restores a previous live slot after restart/health failure. Client `slotdeploy-push rollback` moves the branch; the watcher reports the resulting deployment, not a separate client notification. A rejected notification never changes the deployment result. Requests have bounded timeouts; only structured branch/commit/slot/stage facts are sent. URL/chat secrets and provider responses are not logged, and notification credentials are not passed to build commands.

For a generated systemd service, use a private `EnvironmentFile=` in a service drop-in; for launchd, configure `EnvironmentVariables` privately or use `launchctl setenv` before loading the agent. Restart/reload the watcher after changing its environment. Never paste real tokens into shared logs or enable shell tracing with secrets.

## Server setup

1. Write a config file — examples: [Next.js](examples/nextjs/slotdeploy.env), [static site](examples/static/slotdeploy.env)

   ```ini
   REPO_URL=git@github.com:example/myapp.git
   BRANCH=preview
   ROOT=/srv/myapp
   INSTALL_CMD=npm ci
   BUILD_CMD=npm run build
   CHECK_CMD=test -f .next/BUILD_ID          # must pass before switching
   RESTART_CMD=sudo systemctl restart myapp
   HEALTH_URL=http://127.0.0.1:3000/          # checked after switching; on failure, switch back
   ```

   | Key | Meaning | Default |
   |---|---|---|
   | `REPO_URL` | git remote URL | (required) |
   | `BRANCH` | branch to watch | `preview` |
   | `ROOT` | working directory: `ROOT/slots/a`, `ROOT/slots/b`, `ROOT/current` (symlink) | (required) |
   | `INSTALL_CMD`, `BUILD_CMD` | run inside the idle slot | none |
   | `CHECK_CMD` | check **before** switching; on failure the running service is left untouched | none |
   | `RESTART_CMD` | run after switching | none |
   | `HEALTH_URL` | `curl -f` **after** switching; on failure the previous slot is restored | none |
   | `HEALTH_RETRIES`, `HEALTH_INTERVAL` | number of health checks / seconds between them | `30`, `2` |
   | `SHARED_DIR` | files that aren't in git (`.env`, etc.), copied into every slot | none |
   | `KEEP` | paths not deleted when a slot is rebuilt | `node_modules` |

   Config values are never evaluated by the shell when the file is loaded (only command keys run, via `bash -c`, at their step). Unknown keys are rejected with an error.

2. Make your app service run from `ROOT/current` — [myapp.service](examples/nextjs/myapp.service), [nginx.conf](examples/static/nginx.conf).
   If `ROOT/current` is already a real directory, move it out of the way first (slotdeploy refuses to replace it).
3. Register the timer — [systemd](examples/systemd/), [launchd](examples/launchd/com.example.slotdeploy.plist)

   ```bash
   slotdeploy -c /srv/myapp/slotdeploy.env deploy   # run the first deploy by hand
   slotdeploy -c /srv/myapp/slotdeploy.env status
   tail -f /srv/myapp/slotdeploy.log
   ```

Example log:

```
2026-05-04 10:12:31 OK   preview 3f9c1d2 slot=b 58s | Update opening hours
2026-05-04 10:27:05 FAIL preview 8e41a7b build failed, kept 3f9c1d2 (slot=b) | Type error: Property 'title' does not exist
```

The full output of the last failed build is kept in `ROOT/logs/last-failed.log`.

## Teammate's machine (client)

```bash
slotdeploy-push start                    # before editing: new work branch from the current preview
# ... edit files ...
slotdeploy-push push "Fix banner text"   # commit -> back up the work branch -> update preview
slotdeploy-push status                   # what's on preview right now
slotdeploy-push rollback prev            # back to the previous one (alias: 이전)
slotdeploy-push rollback yesterday       # last state before 00:00 today (alias: 어제)
slotdeploy-push rollback 1a2b3c4         # a specific commit
```

Configure with environment variables or `git config`: `slotdeploy.remote` (origin), `slotdeploy.branch` (preview), `slotdeploy.prefix` (work/), `slotdeploy.protected` ("main master").

## Use it with an AI agent

Drop [examples/agent-skill/SKILL.md](examples/agent-skill/SKILL.md) into your agent's skills folder, and it will run the commands above
when someone says "put it on preview" or "roll the preview back to yesterday".
The skill tells the agent never to deploy to production and to ask a person before anything is released.

From a cloned checkout, install the packaged skill for either agent:

```bash
mkdir -p "$HOME/.omo/agent/skills" "$HOME/.claude/skills"
cp -R skills/omo/preview-deploy "$HOME/.omo/agent/skills/"
cp -R skills/claude-code/preview-deploy "$HOME/.claude/skills/"
```

Example: **"preview로 올려줘"** or **"put it on preview"**. Reload skills/restart the agent after installation. The skill reports the pushed commit and distinguishes it from verified server health; it never invents a preview URL.

## Try it locally (no server needed)

```bash
source demo/sandbox.sh      # sets up a remote, a server, and a teammate's clone in /tmp/slotdeploy-demo
edit_page "Hello"; slotdeploy-push push "hello"; slotdeploy watch; site
break_build; slotdeploy-push push "broken"; slotdeploy watch; site   # the previous page stays up
```

## Tests

```bash
bash test/run.sh            # a real bare git remote + fake builds that pass or fail
shellcheck bin/* install.sh test/*.sh demo/sandbox.sh
```

Tests additionally require Python 3.12+ for local HTTP notification and plist validation; the runtime binaries still need only Bash, Git and curl.
What's covered: the previous build is kept on build, health, or check failure; a failed commit isn't retried; locking; rollback (prev / yesterday / commit) leaves local files untouched; the remote `main` is never changed; protected branches are refused; config values are never executed.

## Non-goals

- Production deploys. slotdeploy is built for preview servers.
- Zero downtime. Requests may drop briefly while the app restarts (static sites only swap a symlink, so there's no gap).
- Build timeouts. Wrap the command if you need one: `BUILD_CMD=timeout 600 npm run build`.

## License

MIT
