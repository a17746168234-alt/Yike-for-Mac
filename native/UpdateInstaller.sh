#!/bin/zsh
set -u

old_pid="$1"
dmg="$2"
current_app="$3"
expected_id="$4"
failure_marker="${5:-$HOME/Library/Application Support/$expected_id/yike-update-failed}"
relaunch="${6:-1}"
mount_dir=""
backup_root=""
backup_app=""
preserve_backup=false

log_dir="$HOME/Library/Logs/Yike"
/bin/mkdir -p "$log_dir"
exec >>"$log_dir/updater.log" 2>&1
print "$(/bin/date '+%Y-%m-%d %H:%M:%S') update started; old pid=$old_pid"

cleanup() {
    if [[ -n "$mount_dir" ]]; then
        /usr/bin/hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
        /bin/rmdir "$mount_dir" 2>/dev/null || true
    fi
    if [[ -n "$backup_root" && "$preserve_backup" == false ]]; then /bin/rm -rf "$backup_root"; fi
    /bin/rm -rf "$(/usr/bin/dirname "$dmg")"
}
trap cleanup EXIT

fail() {
    print "update failed: $1"
    /bin/mkdir -p "$(/usr/bin/dirname "$failure_marker")"
    /usr/bin/touch "$failure_marker"
    if [[ -d "$backup_app" && ! -d "$current_app" ]]; then
        /usr/bin/ditto "$backup_app" "$current_app" || preserve_backup=true
    fi
    if [[ "$relaunch" == 1 && -d "$current_app" ]]; then /usr/bin/open -n "$current_app" || true; fi
    [[ "$relaunch" == 1 ]] || exit 1
    /usr/bin/osascript -e 'display dialog "Yike 自动更新没有完成。请查看 ~/Library/Logs/Yike/updater.log；如果原版无法打开，请保留日志及临时备份。" buttons {"知道了"} with title "Yike 更新"' >/dev/null 2>&1 || true
    exit 1
}

# A SwiftUI sheet can delay normal app termination. Only signal the exact PID
# passed by the app after giving it time to quit gracefully.
for _ in {1..50}; do
    /bin/kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then
    print "old app did not quit; sending TERM"
    /bin/kill -TERM "$old_pid" 2>/dev/null || true
fi
for _ in {1..50}; do
    /bin/kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then
    print "old app did not respond; sending KILL"
    /bin/kill -KILL "$old_pid" 2>/dev/null || true
fi
for _ in {1..30}; do
    /bin/kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
/bin/kill -0 "$old_pid" 2>/dev/null && fail "old app still running"

mount_dir="$(/usr/bin/mktemp -d /tmp/yike-update-mount.XXXXXX)" || fail "cannot create mount directory"
backup_root="$(/usr/bin/mktemp -d /tmp/yike-update-backup.XXXXXX)" || fail "cannot create backup directory"
backup_app="$backup_root/Yike.app"
/usr/bin/hdiutil verify "$dmg" || fail "disk image verification"
/usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" || fail "disk image mount"
new_app="$mount_dir/Yike.app"
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist" 2>/dev/null)"
[[ "$actual_id" == "$expected_id" ]] || fail "bundle identifier mismatch"
/usr/bin/codesign --verify --deep --strict "$new_app" || fail "new app signature"
/usr/bin/ditto "$current_app" "$backup_app" || fail "backup current app"
/bin/rm -rf "$current_app" || fail "remove current app"
if ! /usr/bin/ditto "$new_app" "$current_app" || ! /usr/bin/codesign --verify --deep --strict "$current_app"; then
    /bin/rm -rf "$current_app"
    if ! /usr/bin/ditto "$backup_app" "$current_app"; then preserve_backup=true; fi
    fail "install or installed signature"
fi
/bin/rm -f "$failure_marker"
if [[ "$relaunch" != 1 ]]; then
    print "update completed; app left closed"
    exit 0
fi
print "new app installed; opening"
if ! /usr/bin/open -n "$current_app"; then
    print "new app installed but Launch Services could not open it"
    /usr/bin/osascript -e 'display dialog "Yike 新版已安装，但未能自动打开。请从“应用程序”手动打开 Yike。" buttons {"知道了"} with title "Yike 更新"' >/dev/null 2>&1 || true
    exit 1
fi
print "update completed"
