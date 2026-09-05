# WARDOGS Playtest — Elytra Anti-Cheat on Linux (Steam / Proton)

## The problem

On Windows the game boots through `WardogsLauncher-Shipping.exe`, which starts the
`Elytra.Service` anti-cheat, creates a game session with the heartbeat module, and
then launches the game client.

On Linux/Proton, Steam still launches the launcher — but the launcher dies within
a couple of seconds under Wine (exit code 1, before it can start the service).
(If you run it manually with the Proton environment it fails the same way.)
To get the game to boot at all you have to add this Steam launch option, which
replaces the launcher with the game client:

```
bash -c 'exec "${@/WardogsLauncher-Shipping.exe/Wardogs/Binaries/Win64/WardogsClient-Win64-Shipping.exe}"' -- %command%
```

That boots the game, but the Elytra service still never runs, so after ~1 minute
the server kicks you with:

> "heartbeat missing in window"

## The fix (summary)

1. Put the **heartbeat module cab** into the Proton prefix's Elytra `Content` folder
   (the service auto-installs it when it starts).
2. Start the game normally from Steam (it boots fine — Proton handles D3D12).
3. Run `elytra_session_launch.sh` while the game is running. It starts the Elytra
   service + session and launches a **second** game instance that has the AC
   session attached.
4. Close the first window, play the second one.

## One-time setup

### 1. Get the heartbeat module cab

The Elytra launcher on Windows downloads module cabs from `https://elytra.ac` into
`C:\Program Files\Elytra\Content\`. You need the cab that contains `heartbeat.dll`
(on this machine it is `04206C23AD67D4551CF8E94075B246A8F53049327FC677D61FD353AE6BD937B265AF.cab`).
Get it from a Windows machine that has run the launcher once, or from another player.

Notes:
- The `lighthouse` and `elytraldrfs` cabs contain Windows kernel drivers
  (`lighthouse_driver.sys`, `elytraldrfs_driver.sys`). Kernel drivers cannot run
  under Wine — they are **not needed** and can be deleted.
- If a game update changes the cab, replace the file in the Content folder and
  update `MODULE_HASH` in the script.

### 2. Copy the cab into the prefix

```
~/.local/share/Steam/steamapps/compatdata/4809930/pfx/drive_c/Program Files/Elytra/Content/
```

(Adjust `4809930` if you ever use a different app id.)

Verify after the service starts with:

```
wine 'C:\Program Files\Elytra\control.exe' modules is-installed <MODULE_HASH>
```

### 3. (Optional) Auto-start the Elytra service

Set the service to auto-start in the prefix registry so it comes up whenever the
wineserver starts (e.g. when you launch the game from Steam):

```
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\Elytra.Service" /v Start /t REG_DWORD /d 2
```

(`Start` was `3` = disabled. Do this while no wineserver for that prefix is running,
otherwise the wineserver may overwrite the file on shutdown.)

The script's `session launch` starts the service on its own, so this step is
optional, but it makes the service available before the session is created.

## Per-session usage

(Keep the launch option from above in Steam — without it the launcher is used and
the game won't boot.)

1. Run:
   ```
   ~/wardogs-elytra-fix/elytra_session_launch.sh
   ```
   The script does the whole process:
   - launches the game from Steam if it isn't running yet,
   - waits for the main menu,
   - replicates the running game's full Proton/Steam environment,
   - runs `control.exe session launch ...` which starts the service, installs
     the heartbeat module, primes the session and opens a second game window,
   - waits for the second window to open, then **closes the first (Steam)
     instance** automatically.
   - The line `The background task closed early eof; restart required` in the
     output is a known, harmless message. The session continues.
2. Play the remaining (second) game window — that one has the anti-cheat
   session attached.
3. The service dies when the game closes; just run the script again next
   session.

## Why the script needs the Steam game running

Two things must match the real Steam/Proton session, otherwise the spawned game
exits within ~10 seconds:

| Missing / wrong variable(s)                | Symptom |
|--------------------------------------------|---------|
| `WINEDLLOVERRIDES` (incl. `d3d12=n`, `dxgi=n`, ...) | "DirectX 12 is not supported on your system" — wine falls back to its built-in D3D12 instead of Proton's vkd3d-proton |
| `SteamAppId`, `SteamEnv`, `SteamClientLaunch`, `SteamGameId`, `Steam3Master`, `SteamUser`, ... | The Playtest build (release AppID 1867240 baked in) asks Steam to `steam://run/1867240` → Steam shows **"game is not released"** (`AppError_18`) and the game exits with code 1 |
| `VK_DRIVER_FILES`, `VK_ICD_FILENAMES`, `VK_IMPLICIT_LAYER_PATH`, `ENABLE_VK_LAYER_*`, `FOSSILIZE_*` | Spawned game dies within ~15 s with no error output — these point at `/usr/lib/pressure-vessel/overrides/share/vulkan/...`, which only exists inside the Steam container, not on the host |

The script replicates the **full** environment of the running Steam game from
`/proc/<pid>/environ`, but skips:

- variables already set in your shell (so your live display/session variables —
  `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, pulse, etc. — stay live instead of
  taking stale values from the capture), and
- container-specific bits: stale wineserver sockets, pressure-vessel/SRT
  container vars, systemd unit vars, host `LD_PRELOAD`/`LD_LIBRARY_PATH`,
  Proton loader hacks, and the Vulkan ICD/layer paths above.

Everything else (DXVK/VKD3D settings, shader cache paths, GStreamer paths,
`WINEDLLPATH`, XALIA, Steam identity vars) is replicated so the spawned game
runs the same graphics/media stack as the Steam one.

## Verifying it works

- `control.exe status` → `Service Status: Running`, `Service RPC: OK`.
- `control.exe modules is-installed <MODULE_HASH>` → "is installed".
- Join a match in the second (session) game window: you should no longer be kicked
  with "heartbeat missing in window".

## Troubleshooting

- **Game never boots on a plain Steam launch** — without the launch option, Steam
  runs `WardogsLauncher-Shipping.exe`, which exits (code 1) within seconds under
  Wine. Keep the launch option that swaps in the client.
- **Second window shows the D3D12 error dialog** — the environment capture failed;
  make sure the Steam game is fully up before running the script.
- **Steam shows "game is not released"** — same cause (Steam identity vars
  missing); re-run the script with the game running.
- **`Failed to connect to the Elytra RPC pipe` / service Stopped** — no game/wineserver
  is running yet, or the service died with the last game; start the game and run
  the script.
- **`control.exe modules add` fails ("File not found" / "Failed to convert path to
  volume GUID form")** — don't use `modules add`; the service auto-installs from the
  Content folder. Just put the cab there.
- **Never `pkill -f` with the game name** — the pattern also matches your own shell
  command line and kills your session. Use PIDs.

## Caveats

- This is a workaround for the Proton flow, not an official one; a game or Elytra
  update may change the module hash, cab contents, or paths — re-check the
  `Content` folder and update the script.
- The Elytra service only lives while a game (its wineserver) is running.
- Keep a backup of the cab and of the prefix registry change in case the prefix
  is recreated.
