# Changelog

## 0.1.4 - 2026-09-18

- Keep compact usage summaries on one horizontal line across the profile card.
- Give profile names and usage text the available width between the avatar and menu.
- Prevent account names and the active badge from wrapping into tall cards.

## 0.1.3 - 2026-09-18

- Show five-hour and weekly capacity as percentage remaining instead of percentage used.
- Fill usage bars from full to empty as remaining capacity decreases.
- Use blue for healthy capacity, orange below 30% remaining, and red below 10% remaining.

## 0.1.2 - 2026-09-18

- Open the profiles panel automatically when Codex Profiles starts.
- Add an **Open panel at launch** setting, enabled by default.
- Keep the automatic reveal silent and prevent it from taking focus from the current app.

## 0.1.1 - 2026-09-17

- Remove the generated `dist/Codex Profiles.app` bundle after a successful install so Spotlight shows one app copy.
- Keep standalone builds available through `scripts/build-app.sh`.
- Document the installer cleanup behavior and release-version bookkeeping.
