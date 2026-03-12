#!/bin/sh

check_directory() {
    if [ ! -d "$1" ]; then
        echo "Error: Directory $1 does not exist. Exiting."
        exit 1
    fi
}

check_directory "/etc/redis"
check_directory "/etc/valkey"
check_directory "/var/lib/redis"
check_directory "/var/lib/valkey"

if cp -p "/etc/redis/redis.conf" "/etc/valkey/valkey.conf"; then
    echo "/etc/redis/redis.conf has been copied to /etc/valkey/valkey.conf."
else
    echo "Failed to copy /etc/redis/redis.conf to /etc/valkey/valkey.conf."
    exit 1
fi

if cp -p "/etc/redis/sentinel.conf" "/etc/valkey/sentinel.conf"; then
    echo "/etc/redis/sentinel.conf has been copied to /etc/valkey/sentinel.conf."
else
    echo "Failed to copy /etc/redis/sentinel.conf to /etc/valkey/sentinel.conf."
    exit 1
fi

if mv "/var/lib/redis/"* "/var/lib/valkey/"; then
    echo "On-disk redis dumps moved from /var/lib/redis/ to /var/lib/valkey."
else
    echo "Failed to move dumps from /var/lib/redis/ to /var/lib/valkey."
    exit 1
fi

# Output messages suggesting manual review
echo "pid, log and dir are updated by the config at /etc/sysconfig/valkey. Review of the valkey.conf is strongly recommended especially if redis.conf is updated."
echo "pid, log and dir are updated by the config at /etc/sysconfig/valkey-sentinel. Review of the sentinel.conf is recommended especially if sentinel.conf is updated."

