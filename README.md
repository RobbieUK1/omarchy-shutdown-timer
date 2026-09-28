# Shutdown Timer

Schedule a shutdown from the Omarchy shell bar.

The bar shows a clock button. Click it, pick a delay, and the machine powers
off when the timer expires. While a timer is armed the button counts down
live, and the same panel offers **Cancel Timer**.

Presets are 10 minutes, 15 minutes, 30 minutes and 1 hour, plus **Custom
time…** for anything from 1 second to 1 year.

## Requirements

- Omarchy shell
- `systemd` with user-level transient timers (`systemd-run --user`)

## Install

```sh
omarchy plugin add https://github.com/RobbieUK1/omarchy-shutdown-timer.git --enable
omarchy restart shell
```

The panel shells out to a small helper script, which ships in `bin/` but has to
live outside the plugin directory, so install it too:

```sh
mkdir -p ~/.config/omarchy/bar/scripts
install -m 755 bin/shutdown-timer ~/.config/omarchy/bar/scripts/shutdown-timer
```

Then right-click your bar -> **Configure bar** (or edit
`~/.config/omarchy/shell.json`) and add the widget to a section:

```json
"right": [
  { "id": "robbie.shutdown-timer" }
]
```

## How it works

Arming does not use a shell process that dies with your session. It schedules
`omarchy-system-shutdown` on a **transient user timer** with a stable unit name
(`omarchy-shutdown-timer.timer`):

```sh
systemd-run --user --collect --unit=omarchy-shutdown-timer \
  --on-active=<seconds>s --timer-property=AccuracySec=100ms \
  omarchy-system-shutdown
```

Because the unit name is stable, cancelling works from any later panel session,
and the shutdown still fires correctly after a shell restart. `AccuracySec` is
tightened to 100ms so the countdown means something.

The expiry target is mirrored to
`${XDG_STATE_HOME:-~/.local/state}/omarchy-shutdown-timer` for the UI. `status`
cross-checks that file against `systemctl --user list-timers`: if the state file
says armed but the timer is gone, it self-heals and reports not-armed rather
than showing a countdown that will never fire.

It fires `omarchy-system-shutdown` — the same command the power menu uses — so
the two widgets behave identically.

## Safety

The armed state is visible in two places: the countdown on the bar button, and
the timer banner in [omarchy-menu](https://github.com/RobbieUK1/omarchy-menu).
Cancel from either.

## License

MIT
