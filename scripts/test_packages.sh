#!/usr/bin/env bash
# test_packages.sh — Automated test suite for Valkey packages
#
# Usage: bash scripts/test_packages.sh --pkg-dir=/path/to/debs_or_rpms [--version=X.Y.Z]
#
# Supports both upstream (valkey-*) and Percona (percona-valkey-*) packages.
# Auto-detects OS (Debian vs RHEL), installs all packages from a directory,
# runs validation tests, removes packages, and verifies clean removal.

set -euo pipefail

###############################################################################
# Constants & globals
###############################################################################
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
PKG_DIR=""
OS_FAMILY=""  # "deb" or "rpm"
EXPECTED_VERSION=""
START_TIME=""
FAILED_TESTS=()
SKIPPED_TESTS=()
INSTALLED_PKGS=()
PKG_PREFIX=""  # "valkey" or "percona-valkey", auto-detected

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

###############################################################################
# Utility functions
###############################################################################
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$1")
    printf "  ${RED}FAIL${RESET} %s\n" "$1"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$1")
    printf "  ${YELLOW}SKIP${RESET} %s\n" "$1"
}

section_header() {
    printf "\n${CYAN}${BOLD}=== %s ===${RESET}\n" "$1"
}

###############################################################################
# Assertion helpers
###############################################################################
assert_file_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_file_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -e "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_dir_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_dir_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -d "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_executable() {
    local path="$1" label="${2:-$1}"
    if [[ -x "$path" ]]; then
        pass "$label is executable"
    else
        fail "$label is executable (not executable or missing: $path)"
    fi
}

assert_symlink() {
    local path="$1" label="${2:-$1}"
    if [[ -L "$path" ]]; then
        pass "$label is a symlink"
    elif [[ -f "$path" ]]; then
        # Some packaging may install actual files instead of symlinks
        pass "$label exists (regular file, not symlink)"
    else
        fail "$label is a symlink (not found: $path)"
    fi
}

assert_owner() {
    local path="$1" expected_owner="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label owner is $expected_owner (path not found: $path)"
        return
    fi
    local actual_owner
    actual_owner="$(stat -c '%U:%G' "$path")"
    if [[ "$actual_owner" == "$expected_owner" ]]; then
        pass "$label owner is $expected_owner"
    else
        fail "$label owner is $expected_owner (got: $actual_owner)"
    fi
}

assert_perms() {
    local path="$1" expected_mode="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label mode is $expected_mode (path not found: $path)"
        return
    fi
    local actual_mode
    actual_mode="$(stat -c '%a' "$path")"
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        pass "$label mode is $expected_mode"
    else
        fail "$label mode is $expected_mode (got: $actual_mode)"
    fi
}

assert_command_succeeds() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (command failed: $*)"
    fi
}

assert_command_output_contains() {
    local label="$1" expected="$2"
    shift 2
    local output
    output="$("$@" 2>&1)" || true
    if [[ "$output" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label (expected output containing '$expected', got: '$output')"
    fi
}

###############################################################################
# Systemd helpers
###############################################################################
has_systemd() {
    # Check if systemd is PID 1
    [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

wait_for_service() {
    local service_name="$1" timeout="${2:-15}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

###############################################################################
# OS detection
###############################################################################
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_FAMILY="deb"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || [[ -f /etc/rocky-release ]] || [[ -f /etc/almalinux-release ]]; then
        OS_FAMILY="rpm"
    elif command -v rpm &>/dev/null && command -v yum &>/dev/null; then
        OS_FAMILY="rpm"
    elif command -v dpkg &>/dev/null && command -v apt-get &>/dev/null; then
        OS_FAMILY="deb"
    else
        echo "ERROR: Cannot detect OS family (neither Debian nor RHEL based)" >&2
        exit 1
    fi
    echo "Detected OS family: $OS_FAMILY"
}

###############################################################################
# Package prefix detection
###############################################################################
detect_pkg_prefix() {
    # Check what packages exist in the directory
    local has_percona=false has_upstream=false

    for f in "$PKG_DIR"/*.deb "$PKG_DIR"/*.rpm; do
        [[ -f "$f" ]] || continue
        local base
        base="$(basename "$f")"
        if [[ "$base" == percona-valkey* ]]; then
            has_percona=true
        elif [[ "$base" == valkey-* || "$base" == valkey_* ]]; then
            has_upstream=true
        fi
    done

    if $has_percona; then
        PKG_PREFIX="percona-valkey"
    elif $has_upstream; then
        PKG_PREFIX="valkey"
    else
        echo "ERROR: No valkey packages (valkey-* or percona-valkey-*) found in $PKG_DIR" >&2
        exit 1
    fi
    echo "Detected package prefix: $PKG_PREFIX"
}

###############################################################################
# Package install/remove
###############################################################################
install_packages_deb() {
    section_header "Installing .deb packages"
    # Fix any broken deps first
    apt-get update -qq
    apt-get install -f -y -qq

    local debs=()
    for f in "$PKG_DIR"/${PKG_PREFIX}*.deb; do
        [[ -f "$f" ]] || continue
        debs+=("$f")
    done

    if [[ ${#debs[@]} -eq 0 ]]; then
        echo "ERROR: No ${PKG_PREFIX}*.deb files found in $PKG_DIR" >&2
        exit 1
    fi

    echo "Installing ${#debs[@]} package(s)..."
    apt-get install -y "${debs[@]}" 2>&1 || {
        echo "Install failed, attempting with --fix-broken..."
        apt-get install -y --fix-broken "${debs[@]}" 2>&1
    }
    # Capture installed package names and versions
    while IFS= read -r line; do
        INSTALLED_PKGS+=("$line")
    done < <(dpkg -l "${PKG_PREFIX}*" 2>/dev/null | awk '/^ii/ {printf "%s %s %s\n", $2, $3, $4}')
    echo "Installation complete."
}

install_packages_rpm() {
    section_header "Installing .rpm packages"

    local rpms=()
    for f in "$PKG_DIR"/${PKG_PREFIX}*.rpm; do
        [[ -f "$f" ]] || continue
        # Skip source RPMs and debuginfo
        [[ "$f" == *.src.rpm ]] && continue
        [[ "$f" == *debuginfo* ]] && continue
        [[ "$f" == *debugsource* ]] && continue
        rpms+=("$f")
    done

    if [[ ${#rpms[@]} -eq 0 ]]; then
        echo "ERROR: No ${PKG_PREFIX}*.rpm files found in $PKG_DIR" >&2
        exit 1
    fi

    echo "Installing ${#rpms[@]} package(s)..."
    yum localinstall -y "${rpms[@]}" 2>&1
    # Capture installed package names and versions
    while IFS= read -r line; do
        [[ -n "$line" ]] && INSTALLED_PKGS+=("$line")
    done < <(rpm -qa "${PKG_PREFIX}*" --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' 2>/dev/null)
    echo "Installation complete."
}

remove_packages_deb() {
    section_header "Removing .deb packages"
    local pkgs
    pkgs="$(dpkg -l "${PKG_PREFIX}*" 2>/dev/null | awk '/^ii/ {print $2}' || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Purging: $pkgs"
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs 2>&1
        apt-get autoremove -y 2>&1
    else
        echo "No ${PKG_PREFIX} packages found to remove."
    fi
    echo "Removal complete."
}

remove_packages_rpm() {
    section_header "Removing .rpm packages"
    local pkgs
    pkgs="$(rpm -qa "${PKG_PREFIX}*" 2>/dev/null || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Removing: $pkgs"
        # shellcheck disable=SC2086
        yum remove -y $pkgs 2>&1
    else
        echo "No ${PKG_PREFIX} packages found to remove."
    fi
    echo "Removal complete."
}

###############################################################################
# Tests
###############################################################################
test_binaries() {
    section_header "Test: Binaries"
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_executable "/usr/bin/$bin" "$bin"
    done
    assert_command_succeeds "valkey-server --version" valkey-server --version
    assert_command_succeeds "valkey-cli --version" valkey-cli --version

    # Version checks
    if [[ -n "$EXPECTED_VERSION" ]]; then
        local ver_bins=(valkey-server valkey-cli)
        for bin in "${ver_bins[@]}"; do
            local ver_output
            ver_output="$("$bin" --version 2>&1)" || true
            if [[ "$ver_output" == *"$EXPECTED_VERSION"* ]]; then
                pass "$bin version contains $EXPECTED_VERSION"
            else
                fail "$bin version contains $EXPECTED_VERSION (got: $ver_output)"
            fi
        done
    fi
}

test_user_group() {
    section_header "Test: User & Group"
    if id valkey &>/dev/null; then
        pass "valkey user exists"
    else
        fail "valkey user exists"
    fi

    if getent group valkey &>/dev/null; then
        pass "valkey group exists"
    else
        fail "valkey group exists"
    fi

    local home_dir
    home_dir="$(getent passwd valkey | cut -d: -f6)" || true
    if [[ "$home_dir" == "/var/lib/valkey" ]]; then
        pass "valkey home dir is /var/lib/valkey"
    else
        fail "valkey home dir is /var/lib/valkey (got: $home_dir)"
    fi
}

test_directories() {
    section_header "Test: Directories & Permissions"

    assert_dir_exists /var/lib/valkey
    assert_owner /var/lib/valkey "valkey:valkey"
    assert_perms /var/lib/valkey 750

    assert_dir_exists /var/log/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /var/log/valkey "valkey:adm"
        assert_perms /var/log/valkey 2750
    else
        assert_owner /var/log/valkey "valkey:valkey"
        assert_perms /var/log/valkey 750
    fi

    assert_dir_exists /etc/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /etc/valkey "valkey:valkey"
        assert_perms /etc/valkey 2770
    else
        assert_owner /etc/valkey "root:root"
        assert_perms /etc/valkey 755
    fi
}

test_config_files() {
    section_header "Test: Config Files"

    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_exists /etc/valkey/valkey.conf "valkey.conf"
        assert_owner /etc/valkey/valkey.conf "valkey:valkey" "valkey.conf"
        assert_perms /etc/valkey/valkey.conf 640 "valkey.conf"

        assert_file_exists /etc/valkey/sentinel.conf "sentinel.conf"
        assert_owner /etc/valkey/sentinel.conf "valkey:valkey" "sentinel.conf"
        assert_perms /etc/valkey/sentinel.conf 640 "sentinel.conf"
    else
        assert_file_exists /etc/valkey/default.conf "default.conf"
        assert_owner /etc/valkey/default.conf "root:valkey" "default.conf"
        assert_perms /etc/valkey/default.conf 640 "default.conf"

        assert_file_exists /etc/valkey/sentinel-default.conf "sentinel-default.conf"
        assert_owner /etc/valkey/sentinel-default.conf "root:valkey" "sentinel-default.conf"
        assert_perms /etc/valkey/sentinel-default.conf 660 "sentinel-default.conf"
    fi
}

test_valkey_server_service() {
    section_header "Test: Valkey Server Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-server"
    else
        service_name="valkey@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        echo "--- journalctl output ---"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        echo "---"
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING/PONG test
    local ping_result
    ping_result="$(valkey-cli PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli PING → PONG"
    else
        fail "valkey-cli PING → PONG (got: $ping_result)"
    fi

    # SET/GET functional test
    valkey-cli SET __test_key__ "hello_valkey" >/dev/null 2>&1 || true
    local get_result
    get_result="$(valkey-cli GET __test_key__ 2>&1)" || true
    if [[ "$get_result" == "hello_valkey" ]]; then
        pass "valkey-cli SET/GET functional"
    else
        fail "valkey-cli SET/GET functional (got: $get_result)"
    fi
    valkey-cli DEL __test_key__ >/dev/null 2>&1 || true

    # Process runs as valkey user
    local proc_user
    proc_user="$(ps -o user= -C valkey-server 2>/dev/null | head -1 | tr -d ' ')" || true
    if [[ "$proc_user" == "valkey" ]]; then
        pass "valkey-server runs as valkey user"
    else
        fail "valkey-server runs as valkey user (got: '$proc_user')"
    fi

    # Stop service
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_valkey_sentinel_service() {
    section_header "Test: Valkey Sentinel Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping sentinel service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-sentinel"
    else
        service_name="valkey-sentinel@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING sentinel on port 26379
    local ping_result
    ping_result="$(valkey-cli -p 26379 PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli -p 26379 PING → PONG"
    else
        fail "valkey-cli -p 26379 PING → PONG (got: $ping_result)"
    fi

    # Stop sentinel
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_compat_redis() {
    section_header "Test: Redis Compatibility"

    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_symlink "/usr/bin/$bin" "$bin"
    done

    assert_command_succeeds "redis-cli --version" redis-cli --version

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/libexec/migrate_redis_to_valkey.bash "migrate_redis_to_valkey.bash"
    fi
}

test_dev_headers() {
    section_header "Test: Dev Headers"

    assert_file_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_exists /usr/include/redismodule.h "redismodule.h"

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/lib/rpm/macros.d/macros.valkey "macros.valkey"
    fi
}

test_logrotate() {
    section_header "Test: Logrotate"

    local found=0
    for f in /etc/logrotate.d/*valkey*; do
        if [[ -f "$f" ]]; then
            found=1
            pass "logrotate config exists: $f"
        fi
    done
    if [[ $found -eq 0 ]]; then
        fail "logrotate config exists in /etc/logrotate.d/"
    fi
}

test_clean_removal() {
    section_header "Test: Clean Removal"

    # Binaries should be gone
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Redis compat symlinks should be gone
    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Headers should be gone
    assert_file_not_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_not_exists /usr/include/redismodule.h "redismodule.h"

    # Systemd units should be gone
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_not_exists /lib/systemd/system/valkey-server.service "valkey-server.service"
        assert_file_not_exists /lib/systemd/system/valkey-sentinel.service "valkey-sentinel.service"
    else
        assert_file_not_exists /usr/lib/systemd/system/valkey@.service "valkey@.service"
        assert_file_not_exists /usr/lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service"
    fi

    # Deb purge should remove data/config/log dirs
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_dir_not_exists /var/lib/valkey "/var/lib/valkey"
        assert_dir_not_exists /var/log/valkey "/var/log/valkey"
        assert_dir_not_exists /etc/valkey "/etc/valkey"
    fi
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    local pass_pct=0
    if [[ $total -gt 0 ]]; then
        pass_pct=$(( (PASS_COUNT * 100) / total ))
    fi

    # Build pass-rate bar (20 chars wide)
    local bar_len=20
    local filled=$(( (PASS_COUNT * bar_len) / (total > 0 ? total : 1) ))
    local empty=$((bar_len - filled))
    local bar_fill="" bar_rest=""
    for ((i=0; i<filled; i++)); do bar_fill+="#"; done
    for ((i=0; i<empty;  i++)); do bar_rest+="-"; done

    printf "\n${BOLD}================================================================${RESET}\n"
    if [[ -n "$EXPECTED_VERSION" ]]; then
        printf "${BOLD}  Test Summary — %s %s (%s)${RESET}\n" "$PKG_PREFIX" "$EXPECTED_VERSION" "$OS_FAMILY"
    else
        printf "${BOLD}  Test Summary — %s (%s)${RESET}\n" "$PKG_PREFIX" "$OS_FAMILY"
    fi
    printf "${BOLD}================================================================${RESET}\n"

    # Packages tested
    printf "\n  ${CYAN}Packages tested:${RESET}\n"
    if [[ ${#INSTALLED_PKGS[@]} -gt 0 ]]; then
        for pkg in "${INSTALLED_PKGS[@]}"; do
            printf "    %-45s\n" "$pkg"
        done
    else
        printf "    (none captured)\n"
    fi

    # Results
    printf "\n  ${CYAN}Results:${RESET}\n"
    printf "    ${GREEN}PASS : %3d${RESET}\n" "$PASS_COUNT"
    printf "    ${RED}FAIL : %3d${RESET}\n" "$FAIL_COUNT"
    printf "    ${YELLOW}SKIP : %3d${RESET}\n" "$SKIP_COUNT"
    printf "    ─────────\n"
    printf "    Total: %3d\n" "$total"

    # Pass rate bar
    printf "\n  ${CYAN}Pass rate:${RESET} [${GREEN}%s${RESET}${RED}%s${RESET}] %d%%\n" \
        "$bar_fill" "$bar_rest" "$pass_pct"

    # Duration
    printf "  ${CYAN}Duration:${RESET}  %dm %02ds\n" "$mins" "$secs"

    # Failed tests detail
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${RED}Failed tests:${RESET}\n"
        for t in "${FAILED_TESTS[@]}"; do
            printf "    ${RED}x${RESET} %s\n" "$t"
        done
    fi

    # Skipped tests detail
    if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}Skipped tests:${RESET}\n"
        for t in "${SKIPPED_TESTS[@]}"; do
            printf "    ${YELLOW}-${RESET} %s\n" "$t"
        done
    fi

    printf "\n${BOLD}================================================================${RESET}\n"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        printf "${RED}${BOLD}  RESULT: FAILED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 1
    else
        printf "${GREEN}${BOLD}  RESULT: PASSED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 0
    fi
}

###############################################################################
# Main
###############################################################################
main() {
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --pkg-dir=*)
                PKG_DIR="${arg#*=}"
                ;;
            --version=*)
                EXPECTED_VERSION="${arg#*=}"
                ;;
            --help|-h)
                echo "Usage: $0 --pkg-dir=/path/to/packages [--version=X.Y.Z]"
                echo ""
                echo "Auto-detects OS, installs Valkey packages, runs tests,"
                echo "removes packages, and verifies clean removal."
                echo ""
                echo "Options:"
                echo "  --pkg-dir=DIR       Directory containing .deb or .rpm packages"
                echo "  --version=X.Y.Z    Expected Valkey version (auto-detected if omitted)"
                exit 0
                ;;
            *)
                echo "Unknown argument: $arg" >&2
                echo "Usage: $0 --pkg-dir=/path/to/packages [--version=X.Y.Z]" >&2
                exit 1
                ;;
        esac
    done

    START_TIME=$(date +%s)

    if [[ -z "$PKG_DIR" ]]; then
        echo "ERROR: --pkg-dir is required" >&2
        echo "Usage: $0 --pkg-dir=/path/to/packages" >&2
        exit 1
    fi

    if [[ ! -d "$PKG_DIR" ]]; then
        echo "ERROR: Package directory does not exist: $PKG_DIR" >&2
        exit 1
    fi

    # Resolve to absolute path
    PKG_DIR="$(cd "$PKG_DIR" && pwd)"

    echo "Package directory: $PKG_DIR"
    detect_os
    detect_pkg_prefix

    # Auto-detect version from package filenames if not provided
    if [[ -z "$EXPECTED_VERSION" ]]; then
        local pkg_file
        pkg_file="$(find "$PKG_DIR" -maxdepth 1 \( -name "${PKG_PREFIX}-server*" -o -name "${PKG_PREFIX}-server_*" \) \( -name '*.deb' -o -name '*.rpm' \) 2>/dev/null | head -1)"
        if [[ -n "$pkg_file" ]]; then
            EXPECTED_VERSION="$(basename "$pkg_file" | grep -oP '[\._-]\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        fi
    fi

    if [[ -n "$EXPECTED_VERSION" ]]; then
        echo "Expected version: $EXPECTED_VERSION"
    fi

    # Install
    if [[ "$OS_FAMILY" == "deb" ]]; then
        install_packages_deb
    else
        install_packages_rpm
    fi

    # Run tests — use set +e so individual failures don't abort
    set +e

    test_binaries
    test_user_group
    test_directories
    test_config_files
    test_valkey_server_service
    test_valkey_sentinel_service
    test_compat_redis
    test_dev_headers
    test_logrotate

    # Stop any lingering services before removal
    if has_systemd; then
        if [[ "$OS_FAMILY" == "deb" ]]; then
            systemctl stop valkey-server valkey-sentinel 2>/dev/null || true
        else
            systemctl stop valkey@default valkey-sentinel@default 2>/dev/null || true
        fi
        sleep 1
    fi

    set -e

    # Remove
    if [[ "$OS_FAMILY" == "deb" ]]; then
        remove_packages_deb
    else
        remove_packages_rpm
    fi

    # Verify clean removal
    set +e
    test_clean_removal
    set -e

    # Summary
    print_summary
}

main "$@"
