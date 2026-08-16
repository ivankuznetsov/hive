# Bound Telegram poll failure retries

**Action:** Made the bot supervisor apply an interruptible one-second delay after every failed Telegram `getUpdates` call. The Telegram adapter now reports whether its most recent poll failed while retaining the existing empty-update and health-event contract. This prevents invalid credentials and immediate transport errors from creating a CPU/logging loop, and the foreground lifecycle test now has bounded cleanup so a shutdown regression cannot hang the full suite indefinitely.
