---
name: driving-ctr-console
description: Use when running dartbrew or runtime hardware tests on a real New 3DS-family (CTR) console - arming the Homebrew Launcher netloader remotely (pressing Y/B without touching the console), dismissing netloader errors, uploading with `dartbrew run`/`dartbrew test -d <ip>`, or when a netloader upload fails, is refused, or the console stops answering.
---

# Driving a CTR console for hardware tests

The console runs Luma3DS. Rosalina's **InputRedirection** accepts button presses over UDP, so an agent can press buttons itself instead of asking the user every time.

**The console's networking can fall into a broken state, and ending an app then crashes the system.** Symptoms: uploads slow to about 2 KiB/s or fail (`recv:19`, `inflate:-3`), ping drops, the netloader stops arming. In that state, pressing HOME or an app exiting crashes the system process manager (`pm`) on core 1 (Luma3DS dumps with `r0 = 0xE0E01BF5`). Toggling InputRedirection off and on (Rosalina menu, Miscellaneous options) clears it. The trigger is intermittent and unknown: on 2026-11-21 it happened once with a plain homebrew that never touches the network and once after dartbrew runs, while repeat tests with and without BootNTR's server stayed clean. Check ping between uploads; when it fails, stop, ask the user to toggle InputRedirection before anything ends an app, and record what ran last. The toggle does not always recover it (once the netloader showed a `recv` error and stayed broken); closing an app may then hang on "closing software" instead of crashing. Then only a reboot helps. On a bad radio day the state can recur during the first upload after recovery; stop hardware runs rather than looping.

**After a boot, or after network trouble, the console's Wi-Fi may not connect until InputRedirection is toggled off and on** (Rosalina menu, Miscellaneous options). Observed twice on 2026-11-21, once without BootNTR. If ping fails on a console the user says is ready, ask them to toggle InputRedirection.

## Prerequisites the user must provide once

- The console's IP address (shown on the Homebrew Launcher netloader screen, or in Rosalina).
- InputRedirection on: Rosalina menu (L + Down + Select) -> Miscellaneous options -> InputRedirection. **It turns off after a reboot, a sleep or a Wi-Fi reconnect, and sometimes after an app run.** Verify arming before every upload (Y, then `dartbrew devices`). Stop and ask the user to re-enable it when presses stop landing; don't keep uploading.
- Homebrew Launcher open on the console (the netloader is part of it).
- Windows Firewall allowing the dartbrew executable inbound on TCP and UDP 17491. Windows creates **Block** rules automatically the first time a new exe listens; a moved or rebuilt SDK path gets new rules. Check with `Get-NetFirewallRule -DisplayName dartbrew`. A port rule for inbound TCP and UDP 17491 (not tied to an exe path) avoids the per-path approvals: `New-NetFirewallRule -DisplayName 'dartbrew 17491 TCP' -Direction Inbound -Protocol TCP -LocalPort 17491 -Action Allow`, and the same with `-Protocol UDP`.

## Pressing buttons

```bash
dart .claude/skills/driving-ctr-console/scripts/press.dart <console-ip> B Y
```

Each button is held about 150 ms, then released. Buttons: A B X Y L R START SELECT UP DOWN LEFT RIGHT HOME. The packet is the Rosalina/InputRedirectionClient format: five little-endian u32s (pad = 0xfff XOR pressed bits, touch, circle pad, c-stick, interface buttons) to UDP 4950. UDP gives no acknowledgement. The only proof a press landed is what happens next (the netloader accepts a connection, or the user sees it).

## Arming the netloader and uploading

1. Press **Y only** to start the netloader: `press.dart <ip> Y`. Press B only when you know an error dialog is showing. B on the netloader's waiting screen *cancels* it. Never press A blindly: in the Homebrew Launcher menu it launches the selected app.
2. After an app exits, wait about **15 s** before pressing Y. Homebrew Launcher reloads first and drops presses meanwhile. A second Y 3 s later is harmless: Y does nothing on the netloader screen.
3. Confirm the netloader is armed with `dartbrew devices --wait 5` (UDP only, same subnet). It does not use up the netloader, unlike a TCP connect.
4. Upload: `dartbrew run -d <ip>` or `dartbrew test -d <ip>`. Each upload uses up the netloader, so arm again before every upload.
5. Run hardware uploads **one at a time**. Two dartbrew runs racing the same netloader leave it in a `recv:19` error, and a console abused that way froze on HOME and needed a hard power-off. On Windows, stopping a background shell task does not kill its child processes. Before starting another loop, kill leftovers explicitly: `Get-CimInstance Win32_Process | ? CommandLine -match 'dartbrew\.exe run' | % { Stop-Process -Id $_.ProcessId -Force }`.

## Rules learned the hard way

- **Never probe port 17491 with a TCP connect test** (`Test-NetConnection -Port 17491`, `nc -z`). The netloader accepts exactly one connection; a connect that sends nothing fails its first `recv` (the console shows `recv:19`) and returns it to the menu. Ping is the safe check.
- **Discovery (`dartbrew devices`, `-d console`) only works on the same subnet.** It is a UDP broadcast. When the console is on another subnet (for example PC on 192.168.8.x behind a travel router, console on 192.168.1.x), always pass `-d <ip>`.
- **NAT between PC and console breaks the connect-back.** The console connects back to the address it saw the upload come from. If a router NATs that traffic, the host never sees the connection and `run` exits 1 with the "never connected back / check the firewall" message. Put both on one network, or forward TCP 17491 to the PC.
- **`recv:19` or `inflate:-3` partway through an upload, or throughput collapsing to about 2 KiB/s:** stop uploads and check ping and netloader state. These symptoms also occurred without BootNTR. After a failed ping, ask the owner to toggle InputRedirection and confirm the console is back in Homebrew Launcher before another upload.
- **Console freezes on HOME** have followed episodes of network trouble (Wi-Fi not reconnecting, failed transfers). The cause remains unresolved. The user has to hold POWER to force it off, then re-enable InputRedirection after the reboot.
- **A separate console subnet behind a NAT router needs a port forward.** The console cannot join a combined 2.4/5 GHz SSID, so it may live on its own network. In the observed setup the PC (192.168.8.30) sits behind router 192.168.8.1, whose WAN side is on the console's network (192.168.1.x, upstream router 192.168.1.254). Uploads work with `-d <ip>`, but the app's connect-back reaches the router's WAN address. Forward WAN TCP 17491 on 192.168.8.1 to 192.168.8.30:17491 (or whichever port `--host-port` uses). `tracert -d <console-ip>` shows the hops.
- **A dropped console** (ping says host unreachable) means it slept, lost Wi-Fi or changed address. Ask the user. After it returns, InputRedirection may need re-enabling.
- Netloader errors on screen read `<function>:<errno>`, from hbmenu's `source/ui/netloader.c` (fincs/new-hbmenu): for example `recv:19`, `chunksize:<n>`, `inflate:<n>`. Read that file before guessing at protocol bugs.
- A console link with 200-700 ms ping is normal for 3DS Wi-Fi. A large JIT app (about 14 MB, 5 MB compressed) takes much longer to upload than on a desktop LAN.

## Notes for networking fixtures and spikes

- **Networking fixtures need a host peer.** Socket, DNS, HTTP and TLS fixtures talk to a server on the PC, so the PC must be reachable from the console on the same subnet (no NAT in between), with its firewall open for the fixture's port.
- **A netloader error dialog blocks arming.** While a dialog such as `recv:19` or `inflate:-3` (a corrupted upload) is showing, Y does nothing. Press B to clear it, then Y.
- **When arming keeps failing, `press.dart <ip> B Y` is safe.** B clears an error dialog or cancels a waiting netloader, and Y re-arms it. Confirm with `dartbrew devices --wait 5`.
- **A plain .3dsx spike can serve its log over TCP.** The console listens and the PC connects out to it, so no firewall rule is needed on the PC. That spike serves on TCP 17500 for 90 s (START skips); read it with `curl --max-time 10 telnet://<ip>:17500` or any TCP client. See `serve_log` in `runtime/ctr/test/loader/ctr_main.c`.

## Crashes and dumps

- **Never change the app CPU-time limit (`APT_SetAppCpuTimeLimit`) or run app threads on core 1 in a test.** On 2026-11-21 the U4 scheduling spike did both as its last step. The setting outlives the app inside Homebrew Launcher, and the system process manager (`pm`) then crashed on core 1 with a Luma3DS exception. Core 2 is safe for app threads; core 1 is the system's.
- On a Luma3DS exception screen, ask the user to save the dump, then fetch it with ftpd running on the console (FTP port 5000, anonymous): dumps are under `/luma/dumps/arm11/`. Decode with TuxSH's parser, saved at `B:/tools/luma-dump-parser/luma_dump_parser.py` (put devkitARM's `arm-none-eabi-objdump` on `PATH` for disassembly). The `Current process` line says whether the crash was in the app (`3dsx_app`) or the system.
- Recovery after a crash: hold POWER to turn the console off, start it again (without BootNTR), then re-enable InputRedirection.
