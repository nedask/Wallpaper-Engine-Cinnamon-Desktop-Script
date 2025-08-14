#!/usr/bin/env bash
# Usage:
#   1. Launch Wallpaper Engine pop-out(s) from Steam.
#   2. Run this script (as your user): ./we-background-clean.sh
#   3. Ctrl+C to stop (restores previous background setting).
#
# Configuration below — edit as needed.

set -euo pipefail

# --- Configuration ---
CHECK_INTERVAL=9000                      # how often to re-check/apply (seconds)
WINDOW_NAME="Wallpaper Pop-out"      # change to match your pop-out window title if different
DEBUG=0                               # set to 1 to enable debug prints

# Optional: Manual resolution override (empty = use detected workarea)
MANUAL_WIDTH="1920"                       # e.g. "1920" or leave empty
MANUAL_HEIGHT="979"                      # e.g. "1090" or leave empty

# Optional: offset from the top of the usable workarea (pixels)
TOP_OFFSET=100                          # e.g. 1 => 1px below the top of the workarea

# Optional: restart nemo-desktop when the script exits (restores icons if needed)
RESTART_NEMO_ON_EXIT=0                # 1 = restart nemo-desktop on exit, 0 = do nothing


dbg() { if [ "$DEBUG" -eq 1 ]; then echo "[DBG]" "$@"; fi }


ORIG_PIC_OPTION=$(gsettings get org.cinnamon.desktop.background picture-options 2>/dev/null || echo "''")

cleanup_and_exit() {
    echo
    echo "⏹ Stopping. Restoring Cinnamon wallpaper setting..."
    # restore original setting (if we could read it)
    if [ -n "$ORIG_PIC_OPTION" ]; then
        gsettings set org.cinnamon.desktop.background picture-options "$ORIG_PIC_OPTION" 2>/dev/null || true
    fi

    if [ "$RESTART_NEMO_ON_EXIT" -eq 1 ]; then
        echo "▶ Restarting nemo-desktop so icons are restored..."
        pkill nemo-desktop 2>/dev/null || true
        nohup nemo-desktop >/dev/null 2>&1 &
        nemo-desktop &
    fi

    exit 0
}
trap cleanup_and_exit INT TERM


echo "▶ Saving current wallpaper option and disabling Cinnamon static wallpaper..."
dbg "Original picture-options: $ORIG_PIC_OPTION"
gsettings set org.cinnamon.desktop.background picture-options 'none' 2>/dev/null || true

echo "▶ Watching for Wallpaper Engine pop-out windows named: \"$WINDOW_NAME\""
echo "   Press Ctrl+C to stop."
dbg "Configuration: CHECK_INTERVAL=${CHECK_INTERVAL}, MANUAL_WIDTH='${MANUAL_WIDTH}', MANUAL_HEIGHT='${MANUAL_HEIGHT}', TOP_OFFSET=${TOP_OFFSET}, RESTART_NEMO_ON_EXIT=${RESTART_NEMO_ON_EXIT}"

while true; do

    mapfile -t WIN_IDS < <(xdotool search --onlyvisible --name "$WINDOW_NAME" 2>/dev/null || true)

    if [ "${#WIN_IDS[@]}" -gt 0 ]; then
        for WIN_ID in "${WIN_IDS[@]}"; do
            # sanity check window exists
            if ! xwininfo -id "$WIN_ID" >/dev/null 2>&1; then
                dbg "Window $WIN_ID vanished, skipping."
                continue
            fi

            echo "✅ Found pop-out window id: $WIN_ID"

            WORKAREA_RAW=$(xprop -root _NET_WORKAREA 2>/dev/null || true)
            if [ -n "$MANUAL_WIDTH" ] && [ -n "$MANUAL_HEIGHT" ]; then
                # Use manual override if both set
                WORK_X=1920
                WORK_Y=1078
                USABLE_W=$MANUAL_WIDTH
                USABLE_H=$MANUAL_HEIGHT
                dbg "Using manual resolution: ${USABLE_W}x${USABLE_H}"
            elif [ -n "$WORKAREA_RAW" ]; then
                # Parse first four numbers after '='
                nums=$(echo "$WORKAREA_RAW" | sed -n 's/.*= *//p' | tr -d ',' | awk '{print $1, $2, $3, $4}')
                read WORK_X WORK_Y USABLE_W USABLE_H <<< "$nums" || true

                # Validate fallback to screen size if parsing failed
                if [[ -z "${USABLE_W:-}" || -z "${USABLE_H:-}" || "$USABLE_W" -le 0 || "$USABLE_H" -le 0 ]]; then
                    DIM=$(xdpyinfo | awk '/dimensions/{print $2}')
                    USABLE_W=${DIM%x*}
                    USABLE_H=${DIM#*x}
                    WORK_X=0; WORK_Y=0
                    dbg "Workarea parsing failed; fallback to full screen ${USABLE_W}x${USABLE_H}"
                fi
            else
                # fallback to full screen
                DIM=$(xdpyinfo | awk '/dimensions/{print $2}')
                USABLE_W=${DIM%x*}
                USABLE_H=${DIM#*x}
                WORK_X=0; WORK_Y=0
                dbg "No _NET_WORKAREA; using full screen ${USABLE_W}x${USABLE_H}"
            fi

            TARGET_X=$((WORK_X))
            TARGET_Y=$((WORK_Y + TOP_OFFSET))


            TARGET_H=$((USABLE_H - TOP_OFFSET))
            if [ "$TARGET_H" -le 0 ]; then
                TARGET_H=$USABLE_H
            fi
            TARGET_W=$USABLE_W

            dbg "Computed target geometry: X=${TARGET_X}, Y=${TARGET_Y}, W=${TARGET_W}, H=${TARGET_H}"

            # 1) Ask WM to treat window as desktop-type (helps remove decorations & put behind icons)
            xprop -id "$WIN_ID" -f _NET_WM_WINDOW_TYPE 32a -set _NET_WM_WINDOW_TYPE "_NET_WM_WINDOW_TYPE_DESKTOP" >/dev/null 2>&1 || dbg "xprop NET_WM_WINDOW_TYPE failed"

            # 2) Request no decorations via _MOTIF_WM_HINTS (many WMs respect this)
            xprop -id "$WIN_ID" -f _MOTIF_WM_HINTS 32c -set _MOTIF_WM_HINTS "0x2, 0x0, 0x0, 0x0, 0x0" >/dev/null 2>&1 || dbg "xprop MOTIF failed"

            # 3) Optionally clear the window title (so if decorations remain it's blank)
            xprop -id "$WIN_ID" -f _NET_WM_NAME 8u -set _NET_WM_NAME "" >/dev/null 2>&1 || dbg "clear NET_WM_NAME failed"

            # 4) Unmap -> allow WM to re-evaluate hints on map
            xdotool windowunmap "$WIN_ID" >/dev/null 2>&1 || dbg "windowunmap failed"

            # tiny pause to let WM update
            sleep 0.06

            # 5) Try reparenting to root (0). If not permitted by window, ignore the failure.
            if xdotool windowreparent "$WIN_ID" 0 >/dev/null 2>&1; then
                dbg "Reparented $WIN_ID to root."
            else
                dbg "Reparent to root not permitted / failed for $WIN_ID — continuing."
            fi

            # 6) Resize/move to the target area (wmctrl -e uses gravity,x,y,w,h)
            # Use integers; wrap in fallback to xdotool if wmctrl fails.
            if wmctrl -i -r "$WIN_ID" -e 0,"$TARGET_X","$TARGET_Y","$TARGET_W","$TARGET_H" >/dev/null 2>&1; then
                dbg "wmctrl moved/resized $WIN_ID"
            else
                dbg "wmctrl failed to set geometry, trying xdotool move/resize"
                xdotool windowmove "$WIN_ID" "$TARGET_X" "$TARGET_Y" >/dev/null 2>&1 || dbg "xdotool windowmove failed"
                xdotool windowsize "$WIN_ID" "$TARGET_W" "$TARGET_H" >/dev/null 2>&1 || dbg "xdotool windowsize failed"
            fi

            # 7) Map the window back (show it) and give WM a moment
            xdotool windowmap "$WIN_ID" >/dev/null 2>&1 || dbg "windowmap failed"
            sleep 0.06

            # 8) Hide from taskbar/pager, ensure below normal windows (so apps still cover it)
            wmctrl -i -r "$WIN_ID" -b add,skip_taskbar,skip_pager,below >/dev/null 2>&1 || dbg "wmctrl hide failed"
            wmctrl -i -r "$WIN_ID" -b remove,fullscreen,sticky >/dev/null 2>&1 || true

            # 9) Extra: mark NET_WM_STATE flags (some WMs respond to this)
            xprop -id "$WIN_ID" -f _NET_WM_STATE 32a -set _NET_WM_STATE "_NET_WM_STATE_SKIP_TASKBAR, _NET_WM_STATE_SKIP_PAGER" >/dev/null 2>&1 || true

            echo "   Applied desktop-type + no-decor + positioned at ${TARGET_X},${TARGET_Y} size ${TARGET_W}x${TARGET_H} for window $WIN_ID"
        done
    else
        dbg "No pop-out windows found."
    fi

    sleep "$CHECK_INTERVAL"
done

