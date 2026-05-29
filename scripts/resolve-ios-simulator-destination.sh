#!/bin/sh

set -eu

xcrun simctl list devices available | awk '
/-- iOS / {
    current_os = $3
    next
}

/^[[:space:]]+iPhone / {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    name = line
    sub(/[[:space:]]+\(.*/, "", name)
    device_os[name] = current_os
}

END {
    count = split("iPhone 17 Pro Max,iPhone 17 Pro,iPhone 17,iPhone Air,iPhone 16 Pro Max,iPhone 16 Pro,iPhone 16 Plus,iPhone 16,iPhone 16e,iPhone 15 Pro Max,iPhone 15 Pro,iPhone 15 Plus,iPhone 15,iPhone 14 Pro Max,iPhone 14 Pro,iPhone 14 Plus,iPhone 14", preferred, ",")

    for (i = 1; i <= count; i += 1) {
        name = preferred[i]
        if (name in device_os) {
            printf "platform=iOS Simulator,name=%s,OS=%s\n", name, device_os[name]
            exit 0
        }
    }

    print "No preferred iPhone simulator runtime is available." > "/dev/stderr"
    exit 1
}
'