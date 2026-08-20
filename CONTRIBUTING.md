# Contributing to DailyPostBox

Thanks for helping improve DailyPostBox.

## Before You Start

- Search existing issues before opening a new one.
- Keep changes focused on one problem or feature.
- Do not include credentials, tokens, personal mail, or `.env` files.
- Open an issue before making a large architectural change.

## Local Checks

Run the checks for each application you changed.

```bash
cd apps/client
flutter analyze
flutter test
```

```bash
cd apps/server
corepack enable
pnpm install --frozen-lockfile
pnpm typecheck
```

## Pull Requests

Describe the behavior changed, the reason for the change, and how it was
verified. Include screenshots for visible client changes.
