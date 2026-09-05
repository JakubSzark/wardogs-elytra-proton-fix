#!/bin/bash
# elytra_session_launch.sh
# Full anti-cheat launch flow for WARDOGS Playtest on Linux/Steam Proton.
#
# Does the whole process:
#   1. Launches the game from Steam (unless it is already running).
#   2. Waits for it to reach the main menu.
#   3. Replicates the running game's full Proton/Steam environment.
#   4. Starts the Elytra service + session and launches a SECOND game
#      instance with the anti-cheat session attached.
#   5. Waits for the second instance to open, then closes the first game
#      process and the Steam overlay UI that Steam spawned for it (these hold
#      the Steam pipes that stall "join game" events). The shared wineserver
#      is left running so the second instance keeps playing.
#
# Afterwards: play the remaining (second) game window. Wait for the script to
# report "First instance closed" and then ~5 extra seconds before using the
# Steam overlay to join a friend, so Steam only has the second instance to
# route the lobby invite to.
#
# PREREQUISITES
#   - Steam is running (the script will try to launch it otherwise).
#   - Steam launch option set for WARDOGS Playtest (see README.md):
#       bash -c 'exec "${@/WardogsLauncher-Shipping.exe/Wardogs/Binaries/Win64/WardogsClient-Win64-Shipping.exe}"' -- %command%
#     (without it the launcher is used and the game won't boot under Wine.)
#   - The heartbeat module cab (containing heartbeat.dll) is in:
#       <SteamDir>/steamapps/compatdata/4809930/pfx/drive_c/Program Files/Elytra/Content/

set -u

APPID=4809930
STEAM_DIR="${HOME}/.local/share/Steam"
PROTON_DIR="${STEAM_DIR}/steamapps/common/Proton Hotfix"
WINE="${PROTON_DIR}/files/bin/wine"
PFX="${STEAM_DIR}/steamapps/compatdata/${APPID}/pfx"
GAME_EXE='S:\steamapps\common\WARDOGS Playtest\Wardogs\Binaries\Win64\WardogsClient-Win64-Shipping.exe'
# Hash of the heartbeat module cab in the Content folder (the cab that
# contains heartbeat.dll). Re-check after game updates.
MODULE_HASH='04206C23AD67D4551CF8E94075B246A8F53049327FC677D61FD353AE6BD937B265AF'

# How long to wait for the first game to reach the menu, and for the second
# game to open, in seconds (game boots to the menu in ~15-30s).
MENU_WAIT=30
OPEN_WAIT=30

CONTENT_DIR="${PFX}/drive_c/Program Files/Elytra/Content"

if [ ! -d "$CONTENT_DIR" ]; then
    echo "ERROR: Content dir not found: $CONTENT_DIR"
    echo "Make sure the Elytra files are installed in the Proton prefix."
    exit 1
fi
if ! ls "$CONTENT_DIR"/*.cab >/dev/null 2>&1; then
    echo "ERROR: no .cab files in $CONTENT_DIR"
    echo "Copy the heartbeat module cab (containing heartbeat.dll) there first."
    exit 1
fi

# Returns the PIDs of running Wine game instances (one PID per line).
# Matches the wine path "S:\...\WardogsClient..." and verifies /proc environ
# carries WINEDLLOVERRIDES (excludes the grep process itself and other
# helpers whose cmdline also contains the path).
find_game_pids() {
    local pid
    for pid in $(COLUMNS=2000 ps -ef | grep -E 'S:.*WardogsClient' | awk '{print $2}'); do
        [ -r "/proc/$pid/environ" ] || continue
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "^WINEDLLOVERRIDES=" || continue
        echo "$pid"
    done
}

pid_alive() { [ -d "/proc/$1" ]; }

# Prints every PID in the process tree rooted at $1 (root included).
descendants() {
    local root="$1" tbl cpid ppid p k dup
    tbl=$(ps -eo pid=,ppid=)
    local stack=("$root") found=()
    while [ ${#stack[@]} -gt 0 ]; do
        p="${stack[0]}"; stack=("${stack[@]:1}")
        found+=("$p")
        while read -r cpid ppid; do
            [ "$ppid" != "$p" ] && continue
            dup=0
            for k in "${found[@]}" "${stack[@]}"; do
                [ "$k" = "$cpid" ] && { dup=1; break; }
            done
            [ "$dup" = 0 ] && stack+=("$cpid")
        done <<< "$tbl"
    done
    printf '%s\n' "${found[@]}"
}

# SIGTERM then SIGKILL the first game process. Do NOT kill its container root
# or wineserver: the second instance shares that wineserver (same WINEPREFIX),
# and tearing it down freezes the second instance.

# --- 1. Make sure the game is running (launch it from Steam if needed) ---
FIRST=""
for pid in $(find_game_pids); do FIRST="$pid"; done

if [ -z "$FIRST" ]; then
    echo "Game not running - launching from Steam (steam://run/$APPID)..."
    command -v steam >/dev/null 2>&1 || { echo "ERROR: steam command not found"; exit 1; }
    nohup steam "steam://run/$APPID" >/dev/null 2>&1 &
    disown || true
    for i in $(seq 1 30); do
        sleep 10
        for pid in $(find_game_pids); do FIRST="$pid"; break; done
        [ -n "$FIRST" ] && break
        echo "  waiting for the game to appear... ($((i*10))s)"
    done
    if [ -z "$FIRST" ]; then
        echo "ERROR: the game did not start. Check Steam and the launch option."
        exit 1
    fi
fi
echo "First game running: PID $FIRST"

# --- 2. Wait for it to reach the main menu ---
echo "Waiting ${MENU_WAIT}s for the main menu..."
sleep "$MENU_WAIT"
if ! pid_alive "$FIRST"; then
    echo "ERROR: the first game exited while waiting for the menu."
    exit 1
fi

# --- 3. Replicate the game's full environment ---
ENVF=$(mktemp)
trap 'rm -f "$ENVF"' EXIT
tr '\0' '\n' < "/proc/$FIRST/environ" > "$ENVF"

# Skip: variables already set in this shell (keep your live display/session
# values), and container-specific bits that are stale/wrong on the host
# (stale wineserver sockets, pressure-vessel/SRT container vars, systemd
# bits, host LD_PRELOAD/LD_LIBRARY_PATH, Proton loader hacks, and the
# Vulkan ICD/layer paths that only exist inside the Steam container).
BLACKLIST_REGEX='^(WINESERVERSOCKET|WINESERVER|WINELOADERNOEXEC|WINEPRELOADRESERVE|container|PRESSURE_VESSEL_[A-Z_]*|SRT_[A-Z_]*|INVOCATION_ID|JOURNAL_STREAM|MANAGERPID|MANAGERPIDFDID|SYSTEMD_EXEC_PID|MEMORY_PRESSURE_[A-Z_]*|PAM_KWALLET5_LOGIN|LD_LIBRARY_PATH|ORIG_LD_LIBRARY_PATH|LD_PRELOAD|VK_DRIVER_FILES|VK_ICD_FILENAMES|VK_IMPLICIT_LAYER_PATH|ENABLE_VK_LAYER_[A-Za-z_]*|FOSSILIZE_[A-Z_]*|STEAM_FOSSILIZE_[A-Z_]*)$'

export WINEPREFIX="$PFX"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%=*}"
    [[ "$name" == "$line" ]] && continue          # no '=' in line
    [[ "$name" =~ $BLACKLIST_REGEX ]] && continue
    [ -z "${!name+x}" ] || continue              # keep existing shell value
    export "$name=${line#*=}"
done < "$ENVF"

export WINEESYNC="${WINEESYNC:-1}"
export WINEFSYNC="${WINEFSYNC:-1}"
export WINE_LARGE_ADDRESS_AWARE="${WINE_LARGE_ADDRESS_AWARE:-1}"

if [ -z "${WINEDLLOVERRIDES:-}" ] || [ -z "${SteamAppId:-}" ]; then
    echo "ERROR: could not capture WINEDLLOVERRIDES / SteamAppId from the game."
    exit 1
fi
echo "Environment replicated: SteamAppId=$SteamAppId Steam3Master=${Steam3Master:-?}"

# Explicit Steam identity for the second instance. The replicated env already
# carries these from the first instance when Steam set them; fill in Proton's
# usual values if they were missing so Steam unambiguously treats this process
# as the game's own client (this is what "join game"/lobby invites bind to).
[ -z "${SteamGameId:-}" ] && export SteamGameId="steam_app_${APPID}"
[ -z "${SteamOverlayGameId:-}" ] && export SteamOverlayGameId="$APPID"

# --- Steam overlay on the second (session) instance ---
# The second game is launched directly with wine, not by Steam, so Steam does
# not inject its overlay automatically. Replicate what Steam does for a normal
# launch: preload gameoverlayrenderer.so (input hooks / overlay UI / IPC) and
# enable the Vulkan overlay layer via Steam's implicit-layer manifests that it
# writes to ~/.local/share/vulkan/implicit_layer.d (steamoverlay_*.json).
OVERLAY64="$STEAM_DIR/ubuntu12_64/gameoverlayrenderer.so"
OVERLAY32="$STEAM_DIR/ubuntu12_32/gameoverlayrenderer.so"
if [ -f "$OVERLAY64" ]; then
    export ENABLE_VK_LAYER_VALVE_steam_overlay_1=1
    unset DISABLE_VK_LAYER_VALVE_steam_overlay_1
    export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$OVERLAY64:$OVERLAY32"
    echo "Steam overlay enabled for the second instance (gameoverlayrenderer + Vulkan layer)."
else
    echo "WARNING: gameoverlayrenderer.so not found in $STEAM_DIR - the second instance will have no Steam overlay."
fi

# --- 4. Start the Elytra session and launch the second game instance ---
# NOTE: "The background task closed early eof; restart required" in the output
# is a known, harmless message - the session continues and the game keeps running.
echo "Starting Elytra session (this launches the second game window)..."
"$WINE" 'C:\Program Files\Elytra\control.exe' session launch -m "$MODULE_HASH" -- \
    "$GAME_EXE" -PragmaEnvironment=live -EnableFirstLookSDK -stdout

# --- 5. Wait for the second instance to open ---
SECOND=""
for i in $(seq 1 12); do
    sleep 10
    for pid in $(find_game_pids); do
        [ "$pid" = "$FIRST" ] || { SECOND="$pid"; break; }
    done
    [ -n "$SECOND" ] && break
    echo "  waiting for the second game to appear... ($((i*10))s)"
done
if [ -z "$SECOND" ]; then
    echo "ERROR: the second (anti-cheat) game window did not open."
    exit 1
fi
echo "Second game running: PID $SECOND"

echo "Waiting ${OPEN_WAIT}s for it to open fully..."
sleep "$OPEN_WAIT"
if ! pid_alive "$SECOND"; then
    echo "ERROR: the second game exited while opening."
    exit 1
fi

# --- 6. Close the first (Steam) game process and its overlay UI ---
# The second instance shares the first instance's wineserver (same WINEPREFIX),
# so that wine/container tree must stay up or the second instance freezes. The
# only things that need to go are the first game process (its Steam pipe dies
# with it) and the gameoverlayui Steam spawned for it - that overlay UI holds a
# second Steam pipe, and Steam routes "join game"/lobby events to whichever
# pipe asks first, so while it lives the join can be claimed by the dying first
# instance and never reach the anti-cheat window.
echo "Closing the first instance (PID $FIRST) and its Steam overlay UI..."

FIRSTTREE=()
while IFS= read -r p; do FIRSTTREE+=("$p"); done < <(descendants "$FIRST")

kill -TERM "$FIRST" 2>/dev/null || true
for i in $(seq 1 15); do
    pid_alive "$FIRST" || break
    sleep 1
done
if pid_alive "$FIRST"; then
    kill -9 "$FIRST" 2>/dev/null || true
    sleep 1
fi

# Close any gameoverlayui that Steam started for the first instance's processes
# (its cmdline carries the game PID it is attached to). Do not touch the second
# instance's overlay - its overlay UI references the second instance's PIDs.
for opid in $(COLUMNS=2000 ps -ef | awk '/gameoverlayui/ && !/awk/ {print $2}'); do
    cmd="$(tr '\0' ' ' < "/proc/$opid/cmdline" 2>/dev/null)"
    for p in "${FIRSTTREE[@]}"; do
        if [[ " $cmd " == *" $p "* ]]; then
            kill -TERM "$opid" 2>/dev/null || true
            echo "  closed first instance's overlay UI (PID $opid)"
            break
        fi
    done
done
sleep 2

if pid_alive "$FIRST"; then
    echo "WARNING: could not close the first instance - close it manually."
else
    echo "First instance closed."
fi

# Let Steam re-map the app session onto the second instance alone. Joining a
# friend from the overlay only works reliably once this settles.
sleep 5

echo
echo "DONE. The remaining game window (PID $SECOND) has the anti-cheat session."
echo "Play that one. Wait for the \"First instance closed\" message plus 5s "
echo "before clicking \"Join Game\" in the Steam overlay."
