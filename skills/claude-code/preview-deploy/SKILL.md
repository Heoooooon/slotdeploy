---
name: preview-deploy
description: Puts the current changes on the preview server with slotdeploy-push. Use when the user says "preview로 올려줘", "미리보기에 올려줘", "put it on preview", "deploy to preview", or asks to roll the preview back ("어제 상태로", "방금 전으로", "undo the preview").
---

# Preview deploy (slotdeploy-push)

The user is often not a developer. Keep replies short and in their language.
The preview server rebuilds within 1-2 minutes. A broken build never replaces
the version that is already on the preview server.

## Before editing files
Run `slotdeploy-push start` so the work begins from what the preview server shows now.
If it says there are unsaved changes, skip it and continue on the current branch.

## "Put it on preview"
1. Make sure the requested change is done and saved.
2. Run `slotdeploy-push push "<one-line summary of the change>"`.
3. Run `slotdeploy-push status` and report the uploaded commit. A successful
   push does not prove the server deployed it. If server access is available,
   use `slotdeploy -c <actual-config> status` to verify the live commit;
   otherwise say server health is unverified. Never invent a preview URL.

## "Roll it back"
- "just now / undo" -> `slotdeploy-push rollback prev`
- "yesterday" -> `slotdeploy-push rollback yesterday`
- a specific commit -> `slotdeploy-push rollback <commit>`
Rollback only moves the preview; the user's files stay as they are.

## "What is on preview?"
Run `slotdeploy-push status` and summarise it in one or two sentences.

## Never
- Never push to main/master or any production branch, and never deploy to production.
  Production changes are reviewed and released by a person; offer to ask them.
- Never run `git reset`, `git stash`, `git clean`, or `git checkout -- <file>` for the user.
- Never edit server files; the server only follows the preview branch.
- Never print webhook URLs, bot tokens or chat IDs. Notifications are
  configured in the watcher's environment, not in repository files.
