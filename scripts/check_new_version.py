#!/usr/bin/env python3
"""
Version utilities for Valkey version checking.
Provides functions to find the latest Valkey version and compare versions.
"""

import urllib.request
import json
import sys


def find_latest_version() -> str:
    """
    Find the latest Valkey version from GitHub releases.
    
    Returns:
        str: The latest version number (e.g., "9.0.0")
    """
    api_url = "https://api.github.com/repos/valkey-io/valkey/releases/latest"
    
    with urllib.request.urlopen(api_url, timeout=10) as response:
        data = json.loads(response.read().decode('utf-8'))
        return data['tag_name']


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
        print("Usage: python version_utils.py <version>")
        sys.exit(1)
    
    given_version = sys.argv[1]
    
    latest = find_latest_version()
    result = compare_version(given_version, latest)
    should_build = result >= 0
    sys.exit(0 if should_build else 1)


if __name__ == "__main__":
    main()
