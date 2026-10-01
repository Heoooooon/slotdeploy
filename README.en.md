# slotdeploy

**Let non-developers say "put it on preview" — and never break the preview server.**

[한국어](README.md)

Designers, marketers and other teammates ship their edits to a preview server through an AI agent (or one terminal command).
If the change fails to build or the server does not come up, **the preview server keeps showing the previous version.**
The production (main) branch is never touched; a person reviews and releases to production.

![demo](demo/demo.gif)

- Two bash scripts (`bin/slotdeploy`, `bin/slotdeploy-push`). Needs only `bash`, `git` and `curl`.
- The server checks the `preview` branch every minute from a systemd timer (Linux) or launchd (macOS).
- Works with the stock macOS bash 3.2.

## Why it is safe

```
Teammate's machine                         Preview server
slotdeploy-push push "new banner"          slotdeploy watch  (every minute)
  1. commit on a work branch (work/...)      1. did preview move?
  2. back the work branch up to the remote   2. install -> build -> check in the idle slot (a or b)
  3. point preview at that commit            3. if it passed: atomic symlink switch -> restart
     (never pushes main)                     4. health check fails: switch straight back
                                             5. one log line with the result
```

| Situation | Result |
|---|---|
| Build fails (type error, ...) | No switch. The previous build keeps serving. `FAIL ... build failed, kept 1a2b3c4` |
| Build passes but the app does not come up | Link restored to the previous slot and restarted. `FAIL ... health failed, kept ...` |
| Same failed commit | Not rebuilt every minute. A new commit is tried again |
| Two deploys overlap | A lock lets one run. A lock left by a dead process is cleaned up |
| Need to undo | `slotdeploy-push rollback prev` / `yesterday` / `<commit>` — moves preview only; local files stay |

The client never pushes `main` and never runs `git reset` or `git stash`. Edits made on main are carried to a new work branch first.

## Install

```bash
git clone https://github.com/Heoooooon/slotdeploy.git
sudo install -m 755 slotdeploy/bin/slotdeploy slotdeploy/bin/slotdeploy-push /usr/local/bin/
```

## Server

1. Write a config — examples: [Next.js](examples/nextjs/slotdeploy.env), [static site](examples/static/slotdeploy.env)

   ```ini
   REPO_URL=git@github.com:example/myapp.git
   BRANCH=preview
   ROOT=/srv/myapp
   INSTALL_CMD=npm ci
   BUILD_CMD=npm run build
   CHECK_CMD=test -f .next/BUILD_ID          # must pass before switching
   RESTART_CMD=sudo systemctl restart myapp
   HEALTH_URL=http://127.0.0.1:3000/          # checked after switching; failure switches back
   ```

   | Key | Meaning | Default |
   |---|---|---|
   | `REPO_URL` | git remote | (required) |
   | `BRANCH` | branch to follow | `preview` |
   | `ROOT` | working dir: `ROOT/slots/a`, `ROOT/slots/b`, `ROOT/current` (symlink) | (required) |
   | `INSTALL_CMD`, `BUILD_CMD` | run inside the idle slot | none |
   | `CHECK_CMD` | check **before** switching; failure leaves the service untouched | none |
   | `RESTART_CMD` | run after switching | none |
   | `HEALTH_URL` | `curl -f` **after** switching; failure restores the previous slot | none |
   | `HEALTH_RETRIES`, `HEALTH_INTERVAL` | attempts / seconds between attempts | `30`, `2` |
   | `SHARED_DIR` | files not in git (.env, ...) copied into each slot | none |
   | `KEEP` | paths kept when a slot is rebuilt | `node_modules` |

   Values are not evaluated by the shell when the file is loaded (command keys run with `bash -c` at their step). Unknown keys are rejected.

2. Run the app from `ROOT/current` — [myapp.service](examples/nextjs/myapp.service), [nginx.conf](examples/static/nginx.conf).
   If `ROOT/current` is an existing real directory, move it first (slotdeploy refuses to replace it).
3. Schedule it — [systemd](examples/systemd/), [launchd](examples/launchd/com.example.slotdeploy.plist)

   ```bash
   slotdeploy -c /srv/myapp/slotdeploy.env deploy   # first deploy by hand
   slotdeploy -c /srv/myapp/slotdeploy.env status
   tail -f /srv/myapp/slotdeploy.log
   ```

Log lines:

```
2026-05-04 10:12:31 OK   preview 3f9c1d2 slot=b 58s | Update opening hours
2026-05-04 10:27:05 FAIL preview 8e41a7b build failed, kept 3f9c1d2 (slot=b) | Type error: Property 'title' does not exist
```

The full output of the last failed build is kept in `ROOT/logs/last-failed.log`.

## Teammate's machine (client)

```bash
slotdeploy-push start                    # before editing: new work branch from current preview
# ... edit files ...
slotdeploy-push push "Fix banner text"   # commit -> back up branch -> update preview
slotdeploy-push status                   # what is on preview now
slotdeploy-push rollback prev            # the one before (alias: 이전)
slotdeploy-push rollback yesterday       # last state before today 00:00 (alias: 어제)
slotdeploy-push rollback 1a2b3c4         # a specific commit
```

Settings via environment or `git config`: `slotdeploy.remote` (origin), `slotdeploy.branch` (preview), `slotdeploy.prefix` (work/), `slotdeploy.protected` ("main master").

## With an AI agent

Drop [examples/agent-skill/SKILL.md](examples/agent-skill/SKILL.md) into your agent's skills folder. It runs the commands above for
"put it on preview" or "roll the preview back to yesterday", never deploys to production, and asks a person to release.

## Try it locally (no server)

```bash
source demo/sandbox.sh      # creates a remote, a server and a teammate clone in /tmp/slotdeploy-demo
edit_page "Hello"; slotdeploy-push push "hello"; slotdeploy watch; site
break_build; slotdeploy-push push "broken"; slotdeploy watch; site   # previous page stays
```

## Tests

```bash
bash test/run.sh            # real bare git remote + fake builds that pass or fail
shellcheck bin/* test/run.sh demo/sandbox.sh
```

Covered: previous build kept on build / health / check failure, failed commit not retried, locking, rollback (prev / yesterday / commit) leaves local files alone, remote main unchanged, protected branch refused, config values not executed.

## Non-goals

- Production deploys. slotdeploy is for preview servers.
- Zero downtime. A restart can drop requests briefly (static sites only switch a link, so no gap).
- Build time limits. Wrap it if needed: `BUILD_CMD=timeout 600 npm run build`.

## License

MIT
