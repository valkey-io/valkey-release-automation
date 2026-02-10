#!/bin/bash
set -euo pipefail

# Migrate Redis configuration, data, and systemd units to Valkey.
# This script is intended to run as %post for valkey-compat-redis.
# It is safe to run on systems that never had Redis installed.

# --- Migrate config files ---
if [ -d /etc/redis ]; then
    mapfile -t configfiles < <(find /etc/redis -maxdepth 1 -name "*.conf" 2>/dev/null)

    if [ ${#configfiles[@]} -gt 0 ]; then
        for configfile in "${configfiles[@]}"; do
            configfilename=$(basename "$configfile")
            cp "$configfile" "/etc/valkey/$configfilename"
            chown root:valkey "/etc/valkey/$configfilename"
            if [[ $configfilename == sentinel-*.conf ]]; then
                # Sentinel config files need to be writable by valkey group
                chmod 660 "/etc/valkey/$configfilename"
            else
                chmod 640 "/etc/valkey/$configfilename"
            fi
            mv "$configfile" "${configfile}.bak"
        done
        sed -e 's|^dir\s.*|dir /var/lib/valkey|g' -i /etc/valkey/*.conf
        sed -e 's|^logfile\s/var/log/redis/|logfile /var/log/valkey/|g' -i /etc/valkey/*.conf
        echo "/etc/redis/*.conf has been copied to /etc/valkey.  Manual review of adjusted configs is strongly suggested."
    fi
fi

# --- Migrate systemd units ---
if test -x /usr/bin/systemctl; then
    redis_target_dir="/etc/systemd/system/redis.target.wants"

    if [ -d "$redis_target_dir" ]; then
        mapfile -t redisunits < <(find "$redis_target_dir" -maxdepth 1 -name "redis@*.service" -execdir basename {} \; 2>/dev/null)
        for redisunit in "${redisunits[@]}"; do
            systemctl disable "${redisunit}" 2>/dev/null || :
            systemctl enable "valkey@${redisunit##*@}" 2>/dev/null || :
        done

        mapfile -t sentinelunits < <(find "$redis_target_dir" -maxdepth 1 -name "redis-sentinel@*.service" -execdir basename {} \; 2>/dev/null)
        for sentinelunit in "${sentinelunits[@]}"; do
            systemctl disable "${sentinelunit}" 2>/dev/null || :
            systemctl enable "valkey-sentinel@${sentinelunit##*@}" 2>/dev/null || :
        done
    fi
fi

# --- Migrate data directory ---
if [ -d /var/lib/redis ]; then
    cp -r /var/lib/redis/* /var/lib/valkey/ 2>/dev/null || :
    chown -R valkey:valkey /var/lib/valkey
    mv /var/lib/redis /var/lib/redis.bak
    echo "On-disk redis dumps copied from /var/lib/redis/ to /var/lib/valkey"
fi
