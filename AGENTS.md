# Project instructions

This repository is a distributable macOS app, not a personal work journal.

- Keep user tasks, local settings, thread IDs and credentials out of tracked files and release bundles.
- Use temporary data directories for tests. Do not modify the user's real checklist.
- Preserve atomic writes, stable task IDs and file locking when changing persistence.
- Document actual behavior separately from planned progress/review features.
- Run `python3 scripts/test.py` and the appropriate build for code changes.
- Native task entry must continue to work without Codex, Python or network access.
- If an assistant is asked to add a real task, wait for explicit task content. Use the bundled helper with the user's state path and a stable idempotency ID. Never manufacture work completion.
