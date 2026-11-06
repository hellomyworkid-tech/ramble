#!/bin/bash
# Retakes the App Store screenshots in docs/screenshots: sample data, 9:41, both languages, both sizes.
# Needs the Debug build: run scripts/build.sh sim first. Replaces what's in those folders.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/DerivedData/Build/Products/Debug-iphonesimulator/Ramble.app
bundle=com.zengji.suikouji
[ -d "$app" ] || { echo "No Debug build yet: run scripts/build.sh sim" >&2; exit 1; }

encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# The app opens with the page ready, with no permission alert over it (-startTab sees to that).
shoot() { # file, then launch arguments
    local file=$1
    shift
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle" -AppleLanguages "($language)" -AppleLocale "$locale" \
        -sampleData -mockAI "$@" >/dev/null
    sleep 5
    xcrun simctl io "$udid" screenshot --type=png "$folder/$file.png" >/dev/null 2>&1
    echo "  $folder/$file.png"
}

take_set() { # simulator name, folder size, language, locale, what to say, what to ask
    local name=$1 size=$2
    language=$3
    locale=$4
    local said=$5 asked=$6
    udid=$(xcrun simctl list devices available | grep -F "$name (" | head -1 | grep -oE '[0-9A-F-]{36}')
    folder=docs/screenshots/$size-$language
    mkdir -p "$folder"
    rm -f "$folder"/*.png

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    # A fresh install, so the currency follows the language's region.
    xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl install "$udid" "$app"

    shoot 1-today -startTab today
    shoot 2-capture -startTab today -openLink "ramble://capture?text=$(encode "$said")"
    shoot 3-ledger -startTab ledger -ledger.grouping category
    shoot 4-ask -startTab today -openLink "ramble://ask?q=$(encode "$asked")"
    shoot 5-reminders -startTab reminders
    shoot 6-notes -startTab notes -openNote "$note"
    shoot 7-tasks -startTab tasks

    xcrun simctl status_bar "$udid" clear
    # Nothing left behind: tests running here next would find the last set's currency.
    xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
}

zh_said="装修那边，师傅说水泥要养护 7 天，下周三可以铺砖，然后今天买瓷砖花了 3200"
zh_asked="这个月钱主要花在哪"
en_said="Renovation: the cement needs 7 days to cure, so tiling can start next Wednesday. Spent 3200 on tiles today."
en_asked="Where did my money go this month?"

for device in "iPhone 18 Pro Max:6.9" "iPhone 18 Pro:6.3"; do
    name=${device%%:*}
    size=${device##*:}
    note="装修记录"
    take_set "$name" "$size" zh-Hans zh_CN "$zh_said" "$zh_asked"
    note="Renovation Log"
    take_set "$name" "$size" en en_US "$en_said" "$en_asked"
done
