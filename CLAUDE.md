# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Python daemon that runs on a Raspberry Pi running **Venus OS** (Victron Energy). It monitors the [SH-RPi (Sailor Hat for Raspberry Pi)](https://hatlabs.fi/product/sh-rpi/) power management board via I2C, publishes metrics to the Venus OS D-Bus, and triggers graceful shutdown when input power is lost for too long.

This is a fork of the upstream SH-RPi daemon adapted for Venus OS: the HTTP server is disabled, polling is 1 Hz instead of 10 Hz, and Venus OS D-Bus/GUI integration is added.

## Development commands

Uses [Poetry](https://python-poetry.org/) for dependency management.

```bash
make install        # Install dependencies (poetry install)
make test           # Run pytest with coverage
make codestyle      # Run isort + black formatters
make lint           # Run mypy + pylint + darglint
make check-safety   # Run bandit + safety checks
make docker-build   # Build Docker image
make docker-run     # Run in Docker
```

Run a single test:
```bash
poetry run pytest tests/test_example/test_hello.py::test_hello -v
```

## Architecture

### Layers

**`i2c.py`** — Hardware abstraction. `SHRPiDevice` is a factory that auto-detects hardware and returns a `SHRPiV1Device` or `SHRPiV2Device`. All I2C register reads/writes go through here. The two device classes differ in voltage/current scaling constants.

**`state_machine.py`** — Core logic. `StateMachine` runs a 1 Hz GLib timer loop that reads device state, transitions between `START → OK ↔ BLACKOUT → SHUTDOWN → DEAD`, and publishes values to the Venus OS D-Bus as the service `com.victronenergy.sailorhat`. Settings (e.g. blackout time limit) are persisted via Victron's `SettingsDevice` under `com.victronenergy.settings/Settings/Sailorhat/`.

**`daemon.py`** — Entry point (`shrpid` command). Parses args and `/etc/shrpid.conf`, detects the I2C device, creates a Unix socket, then hands control to `StateMachine.run()`.

**`cli.py`** — Monitoring CLI (`shrpi` command). Connects to the daemon socket via async HTTP and displays status using Rich.

**`server.py`** — Async HTTP server. Present in the codebase but **disabled** in this Venus OS fork (import errors at startup are intentionally suppressed).

### Venus OS integration

- D-Bus service `com.victronenergy.sailorhat` publishes `/State`, `/VoltageIn`, `/CurrentIn`, `/ShutdownCountdown`
- The GUI page lives in `GUI/v2/SailorHat_PageSailorHat.qml` (GUI v2) and `GUI/PageSailorHat.qml` (GUI v1)
- GUI v2 uses `gui-v2-plugin-compiler.py` to compile QML into a JSON plugin bundle; the compiler writes `NAME.json` to its **current working directory** (no `--output` flag)

### Installation on Venus OS

`install-venus.sh` is the single script to install/reinstall everything on a live Venus OS device. It is safe to re-run. It:
1. Installs Python deps via `opkg` + `pip` (with workarounds for Venus OS Python 3.12 quirks)
2. Copies `src/shrpi/*.py` to `/data/sh-rpi-venus/`
3. Creates daemontools service in `/opt/victronenergy/service/sh-rpi-venus` and `/service/sh-rpi-venus`
4. Compiles and installs the GUI plugin

Check daemon logs on the device:
```bash
tail -f /var/log/sh-rpi-venus/current
svstat /service/sh-rpi-venus
```

### GUI v2 QML notes

- Use `precision` (not `decimals`) on `ListQuantity`
- `ListSpinBox` does not have a `decimals` property
- The GUI service is `/service/gui-v2` on current Venus OS builds
- After changing QML: re-run the compiler from within the app dir, then `svc -t /service/gui-v2`
