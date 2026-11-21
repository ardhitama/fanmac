# Changelog

All notable changes to FanMac will be documented in this file.

## [1.0.0] - 2026-11-21

FanMac's first stable release: a menu bar app and `fanmac` command that monitor a Mac's temperatures and control its fans, for macOS 26.1 or later on Apple Silicon and Intel.

### Features
- **Auto**: the fans follow the hotter of the CPU and GPU. They stay at their minimum up to **Speed up from** (40–90 °C), then rise to **Max speed**, which they reach at 90 °C at the Standard **Response**. A rise of 100 RPM goes out at once; a fall waits until it has lasted 10 seconds, so the fans don't chase every degree.
- **Manual**: every fan, or each fan on its own, holds the speed you choose.
- **Every fan stays within its limits**: FanMac never sets a fan below the minimum or above the maximum speed the Mac reports.
- **Fans go back to macOS**: when the Mac sleeps, when FanMac quits, and when Auto can't read a temperature. If FanMac crashes or is force quit, a watchdog process returns them within about a second. If another app hands the fans to macOS or sets its own speed while FanMac runs, FanMac takes them back within a few seconds.
- **Monitoring**: CPU and GPU temperatures, fan speeds and thermal pressure, plus power draw and battery health on laptops, in a popover whose widgets you arrange. The menu bar can show the temperature, power or fan speed next to the icon.
- **Alerts**: a notification when the CPU passes your alert temperature, and an option to switch to Auto when it does.
- **Terminal**: `fanmac watch` is a live view with keyboard control; `fanmac status [--json]`, `fanmac manual` and `fanmac auto` read and change the fans from scripts; `fanmac version` shows the version and license.
- **One password, once**: a small root helper changes the fan speeds. FanMac installs it after one administrator prompt, checking first that it is signed by the same developer as the app, and asks to update it when a release changes it.
- **Install with Homebrew**: `brew install --cask fanmac` installs the app and the `fanmac` command. Releases are signed, notarized and carry a build provenance attestation.
- **Private**: FanMac makes no network connections and collects nothing.

### For users of the 0.x preview releases
- **Auto's Response is back to Standard**: the previews read a Response that was never moved as the quietest, which holds the fans at their minimum at any temperature, and saved it with any other change. FanMac 1.0 resets a Response of the quietest saved by a preview to Standard, once; any other Response stays. If you chose the quietest on purpose, choose it again.
- **Auto is the default**: FanMac starts in Auto at the Standard Response when no mode was ever saved. The previews held the fans at 2000 RPM in Manual.
- **Opening Settings could quit FanMac**: when the Settings form measured a fraction of a point, which a window can't be, the window resized back and forth until macOS stopped FanMac. On a MacBook Pro running macOS 27, 0.2.3 quit each time Settings opened. The window now rounds its height up.
- **Update Helper**: the helper changed, so FanMac asks once for your password to update it. `fanmac status` now says whether the helper needs installing or updating, and how; it said to install a helper that only needed an update.
- **Auto sends its speed again after a failed write**: the previews counted a speed as sent before the helper wrote it, so after a failure the fans could keep a lower speed until the temperature rose further.
- **Fewer password prompts**: when the helper isn't allowed to run, FanMac asks for a password once rather than once for each fan and again at each change of Auto's speed, and never as the Mac goes to sleep.
- **Install Helper works the first time**: the previews kept showing "The helper is missing" after the first install, which asked for the password again.
- **Steadier readings**: a fan limit or speed that fails to read keeps its last good value instead of a fallback, which moved Auto's curve and clamped saved speeds; a fan whose speed failed to read at launch is still counted; values that aren't numbers no longer crash FanMac.
- **One-fan Macs**: `fanmac manual 3000 --fan 1` turned on separate speeds, which left the popover's slider changing nothing.
- **Battery temperature** is read in hundredths of a degree, as other tools read it.
- **Licensing**: Settings has an About section with the version, copyright and license, and the app carries the GPL and FanMac's notices. The FanMac name and icon are now covered by an additional term (see NOTICE).
