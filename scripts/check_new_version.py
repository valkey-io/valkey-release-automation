#!/usr/bin/env python3
"""
Version utilities for Valkey version checking.
Provides functions to find the latest Valkey version and compare versions.
"""

import logging
import subprocess
import sys

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s")


def find_latest_version() -> str:
    """
    Find the latest Valkey version from GitHub releases using GitHub CLI.
    Uses version sorting to get the highest version number, not just the most recent release.
    
    Returns:
        str: The latest version number (e.g., "9.0.0")
    """
    # Use the GitHub CLI with version sorting to get the highest released version
    cmd = "gh release list --repo valkey-io/valkey --exclude-pre-releases --json tagName --jq '.[].tagName' | sort -V | tail -n1"
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
        
    except Exception as e:
        logging.error(f"Failed to fetch latest version: {e}")
        sys.exit(1)


def compare_version(version1: str, version2: str) -> int:
    """
    Compare two version strings.
    
    Args:
        version1 (str): First version to compare (e.g., "9.0.1")
        version2 (str): Second version to compare (e.g., "8.0.1")
        
    Returns:
        int: 1 if version1 > version2, -1 if version1 < version2, 0 if equal
    """
    # Handle special cases
    if version1 == "unstable":
        return 1
    if "-rc" in version1:
        return -1
        
    # Parse version parts (major.minor.patch)
    parts1 = [int(x) for x in version1.split('.')]
    parts2 = [int(x) for x in version2.split('.')]
    
    # Compare major, minor, patch in order
    for p1, p2 in zip(parts1, parts2):
        if p1 > p2:
            return 1
        elif p1 < p2:
            return -1
    
    return 0


def main():
    if len(sys.argv) != 2:
        logging.error("Usage: python check_new_version.py <version>")
        sys.exit(1)
    
    given_version = sys.argv[1]
    
    latest = find_latest_version()
    result = compare_version(given_version, latest)
    should_build = result >= 0
    sys.exit(0 if should_build else 1)


if __name__ == "__main__":
    main()
