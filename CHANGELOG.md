# Changelog

## 0.2.0 - 2026-10-02

- POSIX one-line installer with install, update and uninstall actions,
  custom binary directory and local-source installation.
- Interactive `slotdeploy init` and unattended flags generate protected
  configuration plus user systemd timers or launchd agents without activation.
- Optional environment-based Telegram, Discord and Slack notifications for
  deployment success, failure and restoration of the previous live slot.
  Bounded delivery failures do not change deployment results; credentials
  are excluded from build subprocesses and notification diagnostics.
- Installable omo and Claude Code preview-deploy skill packages.
- English, Chinese, Japanese and Korean setup instructions.
- Existing two-slot health gating, rollback and protected branches retained;
  Bash 3.2 compatibility and LF shell checkouts preserved.

## 0.1.0 - 2026-10-02

- Two-slot, health-checked preview deployments from a Git branch.
- Safe client work branches, preview push and history-based rollback.
