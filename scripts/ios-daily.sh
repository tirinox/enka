#!/bin/zsh
# Daily install on the iPhone: a free Personal Team build stops opening after 7 days.
# launchd runs this every hour (and on wake); the first try of the day that finds the
# phone installs the app, later tries that day do nothing. The app is not launched.
#
#   scripts/ios-daily.sh on | off | status    (no argument = one try)

label=ru.tirinox.enka.daily-install
plist=~/Library/LaunchAgents/$label.plist
# The main checkout, even when called from a worktree that may be gone tomorrow
repo=${$(git -C "${0:A:h}" rev-parse --path-format=absolute --git-common-dir):h}
# ios/build-device is where `make ios-device` builds, and git ignores it
log=$repo/ios/build-device/daily-install.log
stamp=$repo/ios/build-device/daily-install.stamp

case $1 in
on)
	mkdir -p $repo/ios/build-device
	cat > $plist <<-EOF
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>Label</key><string>$label</string>
		<key>ProgramArguments</key>
		<array><string>/bin/zsh</string><string>$repo/scripts/ios-daily.sh</string></array>
		<key>StartInterval</key><integer>3600</integer>
		<key>RunAtLoad</key><true/>
		<key>StandardOutPath</key><string>$log</string>
		<key>StandardErrorPath</key><string>$log</string>
	</dict>
	</plist>
	EOF
	launchctl bootout gui/$UID/$label 2>/dev/null
	launchctl bootstrap gui/$UID $plist && echo "On: hourly tries, one install a day. Log: $log"
	;;
off)
	launchctl bootout gui/$UID/$label 2>/dev/null
	rm -f $plist && echo "Off"
	;;
status)
	launchctl print gui/$UID/$label >/dev/null 2>&1 && echo "On" || echo "Off"
	echo "Last install: $(cat $stamp 2>/dev/null || echo never)"
	;;
*)
	today=$(date +%F)
	[[ "$(cat $stamp 2>/dev/null)" == $today ]] && exit 0
	echo "== $(date '+%F %T')"
	make -C $repo --no-print-directory ios-device IOS_LAUNCH=0 && echo $today > $stamp
	;;
esac
