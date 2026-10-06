#!/bin/sh
# Prepare a plain alpine:<release> container so OpenRC services can be
# started without an init system, for test_packages.sh.
#
# The container itself must be started with `docker run --init`: without an
# init that reaps orphans, a stopped valkey-server stays a zombie and
# start-stop-daemon / supervise-daemon report "process refused to stop".
set -eu

apk add --no-cache bash openrc
# Tell OpenRC it has booted.
mkdir -p /run/openrc
touch /run/openrc/softlevel
# rc_sys="docker" skips services that need real hardware or a kernel;
# rc_cgroup_mode="none" because /sys/fs/cgroup is read-only in a container.
sed -i \
  -e 's/^#\{0,1\}rc_sys=.*/rc_sys="docker"/' \
  -e 's/^#\{0,1\}rc_cgroup_mode=.*/rc_cgroup_mode="none"/' \
  /etc/rc.conf
grep -q '^rc_sys="docker"$' /etc/rc.conf
grep -q '^rc_cgroup_mode="none"$' /etc/rc.conf
echo "OpenRC prepared for container use"
