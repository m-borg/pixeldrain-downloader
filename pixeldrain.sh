#!/usr/bin/env bash

# Destination directory (defaults to ~/Downloads/files)
f="$HOME/Downloads/files"
mkdir -p "$f"

read -r -p "Paste the pixeldrain link: " url
read -r -p "Output filename (e.g. movie.mkv): " name

# Extract Pixeldrain ID (supports both /api/file/ID and /u/ID links)
if [[ "$url" =~ /(api/file|u)/([a-zA-Z0-9_-]+) ]]; then
    id="${BASH_REMATCH[2]}"
else
    printf "\033[31mBad link\033[0m\n"
    read -r -p "Press Enter to exit..."
    exit 1
fi

log="/tmp/aria.log"
rm -f "$log"
n=0
pid=""

# Clean up aria2 process on script abort (Ctrl+C)
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
    fi
    exit 1
}
trap cleanup SIGINT SIGTERM

printf "\n\033[90mWatching progress: open another Terminal and run:\n"
printf "  tail -f \"%s\"\033[0m\n\n" "$log"

while true; do
    # Check if download is complete
    if [[ ! -f "$f/$name.aria2" && -s "$f/$name" ]]; then
        printf "\n\033[32mDONE - %s/%s\033[0m\n" "$f" "$name"
        read -r -p "Press Enter to exit..."
        exit 0
    fi

    # Cycle CDN mirror (01 to 48)
    (( n++ ))
    if (( n > 48 )); then n=1; fi
    printf -v u "https://cdn%02d.pixeldrain.eu.cc/api/file/%s" "$n" "$id"
    printf "\n\033[36m>>> cdn%02d\033[0m\n" "$n"

    # Launch aria2 in the background
    aria2c -x8 -s8 -k1M \
        --stream-piece-selector=inorder \
        --file-allocation=trunc \
        --continue=true \
        --console-log-level=error \
        --summary-interval=5 \
        -d "$f" \
        -o "$name" \
        "$u" > "$log" 2>&1 &
    pid=$!

    sleep 20

    # Speed monitor loop
    while kill -0 "$pid" 2>/dev/null; do
        sleep 8

        # Extract last reported speed from log (e.g., DL:4.5M, DL:800K)
        dl_match=$(grep -E -o 'DL:[0-9.,]+[a-zA-Z]' "$log" 2>/dev/null | tail -n 1)

        if [[ -n "$dl_match" ]]; then
            mb=$(awk -v str="$dl_match" 'BEGIN {
                sub(/^DL:/, "", str)
                unit = toupper(substr(str, length(str), 1))
                val = substr(str, 1, length(str) - 1)
                gsub(/,/, ".", val)
                num = val + 0
                if (unit == "K") { print num / 1024 }
                else if (unit == "M") { print num }
                else if (unit == "G") { print num * 1024 }
                else { print 0 }
            }')

            printf "    \033[90m%.1f MB/s\033[0m\n" "$mb"

            # Drop mirror if throughput is below 3 MB/s
            is_slow=$(awk -v m="$mb" 'BEGIN { if (m < 3.0) print 1; else print 0 }')
            if [[ "$is_slow" -eq 1 ]]; then
                printf "    \033[33mslow - switching\033[0m\n"
                kill -TERM "$pid" 2>/dev/null
                sleep 3
                break
            fi
        fi
    done
done