# WattBar

WattBar shows your Mac's battery charge or discharge rate in watts in the macOS menu bar. Open the menu for battery level, voltage, cycle count, power source, and the origin and age of the current reading when available.

The menu bar shows `↑` for charging, `↓` for draining, `↓~` for estimated drain, `≈0.0` for idle, and `—` when a reading is unavailable. A drain reading while plugged in can occur when the battery is supplementing the power adapter.

## Build and run

Use a Mac with an internal battery and Xcode Command Line Tools. From the repository directory, build and launch WattBar.

```sh
xcrun swiftc -swift-version 5 -O main.swift -o wattbar
./wattbar
```

Run `./wattbar --once` for a single reading in Terminal. The menu bar updates every two seconds by default. Use `./wattbar --interval 5` to update every five seconds.

## Optional fuel gauge helper

The helper reads macOS battery samples from `pmset -g rawlog` and writes the latest sample to `/Users/Shared/wattbar-live.json`. WattBar uses recent helper samples when they match the current power source and can fall back to a macOS battery reading.

Build and run the helper in a separate Terminal window.

```sh
xcrun swiftc -swift-version 5 -O helper.swift -o wattbar-pm
sudo ./wattbar-pm
```

For background use, the included [LaunchDaemon plist](com.jtperez.wattbar-pm.plist) expects the helper at `/usr/local/bin/wattbar-pm`.

## Tests

Run the regression tests for battery reading selection and menu bar display.

```sh
xcrun swiftc -swift-version 5 -D WATTBAR_TEST main.swift simtest.swift -o simtest
./simtest
```
