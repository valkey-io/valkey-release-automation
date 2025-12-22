#!/usr/bin/env python3
"""
Extract Valkey release hash information from the valkey-hashes repository.

Inputs:
    - version (str): The Valkey version to look up (e.g., "8.0.0", "7.2.5")
    - repo_path (str): Path to the local clone of the valkey-hashes repository

Outputs:
    - Prints to stdout: "<sha256_hash> <download_url>"
    - Exit code 0 on success, 1 on failure

Usage:
    python extract_hashes_info.py <version> <repo_path>

Example:
    python extract_hashes_info.py 8.0.0 /path/to/valkey-hashes
    # Output: abc123def456... https://github.com/valkey-io/valkey/archive/refs/tags/8.0.0.tar.gz
    
"""
import logging
import sys
import os

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s")

def extract_valkey_info(version, repo_path):
    readme_path = os.path.join(repo_path, "README")
    
    if not os.path.isfile(readme_path):
        raise FileNotFoundError(f"README file not found at: {readme_path}")
    
    # Search for the line containing the specific version
    hash_line = ""
    with open(readme_path, "r") as f:
        for line in f:
            if f"valkey-{version}.tar.gz" in line:
                hash_line = line.strip()
                break
    
    if not hash_line:
        logging.error(f"Hash not found for version {version} in valkey-hashes repository")
        raise ValueError(f"Hash not found for version {version}")

    # Parse the line: hash valkey-X.Y.Z.tar.gz sha256 HASH_VALUE URL
    parts = hash_line.split()
    download_sha = parts[3]
    download_url = parts[4]
    
    return download_sha, download_url

def main():
    if len(sys.argv) != 3:
        logging.error("Usage: extract_hashes_info.py <version> <repo_path>")
        sys.exit(1)
    sha, url = extract_valkey_info(sys.argv[1], sys.argv[2])
    print(f"{sha} {url}")

if __name__ == "__main__":
    main()
