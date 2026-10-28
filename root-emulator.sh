#!/usr/bin/env bash
#
# root-emulator.sh  --  One-shot Android Studio AVD rooter (Magisk), standalone.
#
# Reproduces the full working flow for rooting an Android emulator with Magisk,
# including the fixes needed for modern images (Android 15+ / API 35+, 16 KB
# page-size system images, and Magisk's new unified binary layout):
#
#   1. Auto-detect the running emulator and the exact system-image ramdisk it uses.
#   2. Sanity-check page size vs. the bundled Magisk (16 KB images need Magisk 28.1+).
#   3. Patch ramdisk.img with rootAVD + the bundled Magisk (backs up the original).
#   4. Cold-boot the AVD so it loads the patched ramdisk (root persists after this).
#   5. Verify Magisk is live and enable root for ADB (root_access = apps + ADB).
#
# USAGE:
#   ./root-emulator.sh [SERIAL]            Root the running emulator (auto-detects if one)
#   ./root-emulator.sh --restore [SERIAL]  Restore the stock ramdisk (un-root) + cold-boot
#   ./root-emulator.sh --no-reboot [SERIAL]  Patch only; don't cold-boot/verify
#   ./root-emulator.sh --help
#
# REQUIREMENTS:
#   - The target emulator must be RUNNING before you start (rootAVD patches it live).
#   - adb + emulator from the Android SDK (platform-tools + emulator).
#   - The AVD should NOT have Play Store enabled for the smoothest result
#     (a Google-APIs or AOSP image). Play-Store images can still work but are stricter.
#
# NOTES:
#   - This script is self-contained in this folder: it uses ./rootAVD.sh and ./Magisk.zip.
#   - The bundled Magisk.zip is v31.1 (16 KB-page safe, new unified layout). Do not
#     downgrade it below v28.1 for 16 KB images or boot will kernel-panic.
#   - rootAVD.sh here has a small patch to its busybox probe so it accepts busybox
#     builds that only act as a dispatcher when invoked as "busybox".
#
set -u

# Ensure we are running under bash (macOS default /bin/sh or zsh lack our features).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
c_b()  { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# --------------------------------------------------------------------------- #
# Magisk payload (auto-downloaded on first run; not committed to git).
# Must be >= 28.1: that's the first 16 KB-page-safe release AND the new unified
# binary layout rootAVD needs here. Bump MAGISK_VERSION to update.
# --------------------------------------------------------------------------- #
MAGISK_VERSION="v31.1"
MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"
MAGISK_MIN_CODE=28100

magisk_code_of() { unzip -p "$1" assets/util_functions.sh 2>/dev/null | awk -F= '/^MAGISK_VER_CODE=/{gsub(/[^0-9]/,"",$2);print $2;exit}'; }

ensure_magisk() {
  local zip="$SCRIPT_DIR/Magisk.zip" code=""
  [ -f "$zip" ] && code="$(magisk_code_of "$zip")"
  if [ -n "$code" ] && [ "$code" -ge "$MAGISK_MIN_CODE" ] 2>/dev/null; then
    info "Magisk payload present (code $code)."; return 0
  fi
  [ -f "$zip" ] && warn "Magisk.zip missing/too old — fetching ${MAGISK_VERSION} ..." \
                || info "Fetching Magisk ${MAGISK_VERSION} ..."
  local tmp="$zip.part"; rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$tmp" "$MAGISK_URL" || die "Download failed: $MAGISK_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$MAGISK_URL" || die "Download failed: $MAGISK_URL"
  else
    die "Need curl or wget to fetch Magisk, or drop a Magisk ${MAGISK_VERSION}+ APK at $zip"
  fi
  code="$(magisk_code_of "$tmp")"
  if [ -z "$code" ] || ! [ "$code" -ge "$MAGISK_MIN_CODE" ] 2>/dev/null; then
    rm -f "$tmp"; die "Downloaded file is not a valid Magisk >= $MAGISK_MIN_CODE."
  fi
  mv -f "$tmp" "$zip"
  ok "Magisk ready (code $code) -> Magisk.zip"
}

MODE="root"
SERIAL=""
REBOOT=1
for a in "$@"; do
  case "$a" in
    --help|-h) usage ;;
    --restore) MODE="restore" ;;
    --no-reboot) REBOOT=0 ;;
    emulator-*|*:*) SERIAL="$a" ;;
    -*) die "unknown option: $a (try --help)" ;;
    *) SERIAL="$a" ;;
  esac
done

# --------------------------------------------------------------------------- #
# locate the Android SDK + tools
# --------------------------------------------------------------------------- #
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$SDK" ]; then
  for cand in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "$HOME/AppData/Local/Android/Sdk"; do
    [ -d "$cand" ] && { SDK="$cand"; break; }
  done
fi
[ -n "$SDK" ] && [ -d "$SDK" ] || die "Android SDK not found. Set ANDROID_SDK_ROOT and retry."
export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

ADB="$SDK/platform-tools/adb"; command -v adb >/dev/null 2>&1 && ADB="$(command -v adb)"
[ -x "$ADB" ] || ADB="$(command -v adb 2>/dev/null)"
[ -n "$ADB" ] && [ -x "$ADB" ] || die "adb not found (install platform-tools)."
EMULATOR="$SDK/emulator/emulator"
[ -x "$EMULATOR" ] || EMULATOR="$(command -v emulator 2>/dev/null)"

AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

c_b "=== Android Emulator Rooter (Magisk) ==="
info "SDK:      $SDK"
info "adb:      $ADB"
"$ADB" start-server >/dev/null 2>&1

# --------------------------------------------------------------------------- #
# pick the target emulator
# --------------------------------------------------------------------------- #
if [ -z "$SERIAL" ]; then
  RUN=()
  while IFS= read -r line; do
    [ -n "$line" ] && RUN+=("$line")
  done < <("$ADB" devices | awk '$1 ~ /^emulator-/ && $2=="device"{print $1}')
  [ "${#RUN[@]}" -eq 0 ] && die "No running emulator found. Start your AVD first, then re-run."
  [ "${#RUN[@]}" -gt 1 ] && { printf 'Multiple emulators:\n'; printf '  %s\n' "${RUN[@]}"; die "Pass one as an argument, e.g. $0 ${RUN[0]}"; }
  SERIAL="${RUN[0]}"
fi
"$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 || die "Emulator '$SERIAL' is not online."
info "Target:   $SERIAL"

AVD_NAME="$("$ADB" -s "$SERIAL" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
[ -n "$AVD_NAME" ] || die "Could not read AVD name from $SERIAL."
info "AVD:      $AVD_NAME"

# --------------------------------------------------------------------------- #
# find the system-image ramdisk this AVD boots from
# --------------------------------------------------------------------------- #
CONF="$AVD_HOME/$AVD_NAME.avd/config.ini"
[ -f "$CONF" ] || die "AVD config not found: $CONF"
SYSDIR="$(grep -E '^image\.sysdir\.1=' "$CONF" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's#/*$#/#')"
[ -n "$SYSDIR" ] || die "image.sysdir.1 missing in $CONF"
REL_RAMDISK="${SYSDIR}ramdisk.img"
ABS_RAMDISK="$SDK/$REL_RAMDISK"
[ -f "$ABS_RAMDISK" ] || die "ramdisk.img not found: $ABS_RAMDISK"
info "Image:    $SYSDIR"
info "Ramdisk:  $ABS_RAMDISK"

# --------------------------------------------------------------------------- #
# RESTORE mode
# --------------------------------------------------------------------------- #
cold_boot() {
  local avd="$1" serial="$2"
  info "Stopping emulator for cold boot ..."
  "$ADB" -s "$serial" emu kill >/dev/null 2>&1
  for _ in $(seq 1 15); do pgrep -f "qemu-system.*-avd $avd" >/dev/null 2>&1 && sleep 2 || break; done
  pgrep -f "qemu-system.*-avd $avd" >/dev/null 2>&1 && { pkill -f "qemu-system.*-avd $avd"; sleep 3; }
  [ -x "$EMULATOR" ] || die "emulator binary not found; start '$avd' manually (it will load the patched ramdisk)."
  local log="$SCRIPT_DIR/.emulator-$avd.log"
  info "Cold-booting '$avd' (loads the new ramdisk) ..."
  nohup "$EMULATOR" -avd "$avd" -no-snapshot-load -netdelay none -netspeed full >"$log" 2>&1 &
  disown 2>/dev/null || true
  info "Waiting for boot (cold boot can take 1-2 min) ..."
  "$ADB" -s "$serial" wait-for-device
  for _ in $(seq 1 90); do
    [ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { ok "Boot complete."; return 0; }
    sleep 3
  done
  warn "Boot did not report complete in time; check the emulator window / $log"
  return 1
}

if [ "$MODE" = "restore" ]; then
  c_b "--- RESTORE (un-root) ---"
  ( cd "$SCRIPT_DIR" && echo "" | bash ./rootAVD.sh "$REL_RAMDISK" restore )
  [ "$REBOOT" = "1" ] && cold_boot "$AVD_NAME" "$SERIAL"
  ok "Stock ramdisk restored."
  exit 0
fi

# --------------------------------------------------------------------------- #
# ensure the Magisk payload exists (download pinned version if needed)
# --------------------------------------------------------------------------- #
ensure_magisk

# --------------------------------------------------------------------------- #
# page-size / Magisk compatibility guard
# --------------------------------------------------------------------------- #
PAGESIZE="$("$ADB" -s "$SERIAL" shell getconf PAGE_SIZE 2>/dev/null | tr -d '\r')"
API="$("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
MVER="$(unzip -p "$SCRIPT_DIR/Magisk.zip" assets/util_functions.sh 2>/dev/null | grep -E "^MAGISK_VER=" | head -1 | sed "s/.*='//;s/'.*//")"
MCODE="$(unzip -p "$SCRIPT_DIR/Magisk.zip" assets/util_functions.sh 2>/dev/null | grep -E "^MAGISK_VER_CODE=" | head -1 | cut -d= -f2 | tr -d '\r')"
info "Device:   API $API, page size ${PAGESIZE:-?} bytes"
info "Magisk:   v$MVER ($MCODE)  [bundled]"
if [ "${PAGESIZE:-0}" = "16384" ]; then
  if [ -z "${MCODE:-}" ] || [ "${MCODE:-0}" -lt 28100 ]; then
    die "16 KB-page image needs Magisk 28.1+ (bundled is $MVER). Replace Magisk.zip with a newer Magisk APK."
  fi
  ok "16 KB page image + Magisk $MVER is compatible."
fi

# --------------------------------------------------------------------------- #
# PATCH
# --------------------------------------------------------------------------- #
c_b "--- PATCHING ramdisk with Magisk v$MVER ---"
PATCH_LOG="$SCRIPT_DIR/.patch-$AVD_NAME.log"
( cd "$SCRIPT_DIR" && echo "" | bash ./rootAVD.sh "$REL_RAMDISK" ) 2>&1 | tee "$PATCH_LOG" | sed 's/\x1b\[[0-9;]*m//g'
if ! grep -q 'patching the ramdisk with Magisk Init' "$PATCH_LOG" 2>/dev/null; then
  die "Patch did not reach the ramdisk-patch step. See $PATCH_LOG"
fi
[ -f "${ABS_RAMDISK}.backup" ] || warn "No ramdisk.img.backup was created (unexpected)."
ok "Ramdisk patched (original saved as ${ABS_RAMDISK}.backup)."

if [ "$REBOOT" = "0" ]; then
  ok "Patch only (--no-reboot). Cold-boot '$AVD_NAME' yourself to load the patched ramdisk."
  exit 0
fi

# --------------------------------------------------------------------------- #
# COLD BOOT + VERIFY
# --------------------------------------------------------------------------- #
cold_boot "$AVD_NAME" "$SERIAL" || true

c_b "--- VERIFYING root ---"
# Reliable interactive root on an emulator is `adb root` (userdebug).
"$ADB" -s "$SERIAL" root >/dev/null 2>&1; sleep 3; "$ADB" -s "$SERIAL" wait-for-device
MAGISK_TMP="$("$ADB" -s "$SERIAL" shell 'ls /debug_ramdisk/magisk 2>/dev/null || ls /sbin/magisk 2>/dev/null' 2>/dev/null | head -1 | tr -d '\r')"
MVER_DEV="$("$ADB" -s "$SERIAL" shell "${MAGISK_TMP:-/debug_ramdisk/magisk} -c" 2>/dev/null | tr -d '\r')"
ID_ROOT="$("$ADB" -s "$SERIAL" shell id 2>/dev/null | tr -d '\r')"

if printf '%s' "$ID_ROOT" | grep -q 'uid=0' && printf '%s' "$MVER_DEV" | grep -qi 'MAGISK'; then
  ok "Root OK  -> $ID_ROOT"
  ok "Magisk   -> $MVER_DEV"
  # enable ADB + apps root in Magisk's policy db
  "$ADB" -s "$SERIAL" shell "magisk --sqlite \"REPLACE INTO settings (key,value) VALUES('root_access',3)\"" >/dev/null 2>&1 \
    && ok "Magisk root access set to: apps + ADB."
else
  warn "Could not confirm root automatically."
  warn "  id:     ${ID_ROOT:-<none>}"
  warn "  magisk: ${MVER_DEV:-<none>}"
  warn "Open the Magisk app in the emulator; it may need to finish setup."
fi
# leave adbd as a normal shell again
"$ADB" -s "$SERIAL" unroot >/dev/null 2>&1; sleep 2; "$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1

c_b "=== DONE ==="
echo "Your emulator '$AVD_NAME' is rooted with Magisk v$MVER."
echo "  - Root persists across reboots (ramdisk.img is patched)."
echo "  - Interactive adb root:  adb -s $SERIAL root   (then 'adb shell' is uid 0)"
echo "  - App root:              granted via the Magisk app inside the emulator"
echo "  - Un-root:               $0 --restore $SERIAL"
