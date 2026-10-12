#!/bin/sh
# Sign one APK repository directory with the release key: re-sign this
# run's packages, rebuild APKINDEX.tar.gz over every package, sign it.
#
# publish-to-s3.sh runs each step in its own alpine:<release> container
# (that release's apk-tools writes an index its clients read), without
# network. Only `sign` sees the private key, and it sees nothing else: a
# scratch directory of files to sign. Packages, which come from the build
# job and from S3, are parsed only in the keyless steps.
#
#   prepare <repo> <work> <arch> <version> <new.apk>...   (no key)
#       Split each new package into <work>/<pkg>/{control,data}.tar.gz
#       after checking its .PKGINFO against <arch> and <version>.
#   sign <work> <key_name> <file>...                       (private key)
#       abuild-sign each <work>/<file> with /apk-key/private.rsa.
#   assemble <repo> <work> <new.apk>...                    (no key)
#       Join the signed control and the data back into <repo>/<pkg>.
#   index <repo> <work> <arch> <key_name> <description>    (public key)
#       Verify every package in <repo> against /apk-key/<key_name>, write
#       the unsigned index to <work>/APKINDEX.tar.gz.
#   all <repo> <arch> <version> <key_name> <description> <new.apk>...
#       Every step in this container (test_apk_repo.sh, with a test key).
#
# <version> is the Alpine package version without the release, e.g.
# 9.2.0 or 9.2.0_rc1. APK_KEY_DIR overrides /apk-key.
set -eu

KEY_DIR="${APK_KEY_DIR:-/apk-key}"

# An abuild package is three gzip streams joined together: signature,
# control, data. The signature covers the control stream only, so
# replacing the build's throwaway signature leaves control and data as
# built. Output is inflated in bounded chunks: only the start of the
# signature stream and the small control stream are kept.
split_package() { # <pkg> <out_dir> <arch> <version>
  python3 - "$@" <<'PY'
import io
import re
import sys
import tarfile
import zlib

pkg, out, arch, version = sys.argv[1:5]
CHUNK = 1 << 20
CONTROL_MAX = 1 << 20


def fail(msg):
    sys.exit(f"{pkg}: {msg}")


def streams(data):
    view = memoryview(data)
    pos = 0
    while pos < len(view):
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        head = d.decompress(view[pos:], CHUNK)
        size = len(head)
        while not d.eof:
            if not d.unconsumed_tail:
                fail("truncated gzip stream")
            size += len(d.decompress(d.unconsumed_tail, CHUNK))
        end = len(view) - len(d.unused_data)
        yield bytes(view[pos:end]), head, size
        pos = end


def first_name(stream):
    # The signature stream has no end-of-archive blocks; tarfile stops at
    # the end of the data either way.
    with tarfile.open(fileobj=io.BytesIO(stream), mode="r:") as tar:
        member = tar.next()
        return member.name if member else ""


with open(pkg, "rb") as f:
    parts = []
    for part in streams(f.read()):
        parts.append(part)
        if len(parts) > 3:
            break
if len(parts) != 3:
    fail(f"expected signature, control and data streams, found {len(parts)}")
(_, sig_head, _), (control, control_head, control_size), (data, _, _) = parts
if not first_name(sig_head).startswith(".SIGN."):
    fail("first stream is not a signature")
if control_size > CONTROL_MAX or len(control_head) != control_size:
    fail("control stream is too large")
if first_name(control_head) != ".PKGINFO":
    fail("second stream is not the control stream")
with tarfile.open(fileobj=io.BytesIO(control_head), mode="r:") as tar:
    info = tar.extractfile(".PKGINFO").read().decode()

fields = dict(
    line.split(" = ", 1) for line in info.splitlines() if " = " in line and not line.startswith("#")
)
if not fields.get("pkgname", "").startswith("valkey"):
    fail(f"unexpected pkgname {fields.get('pkgname')!r}")
if fields.get("arch") not in (arch, "noarch"):
    fail(f"arch {fields.get('arch')!r} does not belong in a {arch} repository")
if not re.fullmatch(re.escape(version) + r"-r[0-9]+", fields.get("pkgver", "")):
    fail(f"pkgver {fields.get('pkgver')!r} is not version {version}")

with open(f"{out}/control.tar.gz", "wb") as f:
    f.write(control)
with open(f"{out}/data.tar.gz", "wb") as f:
    f.write(data)
PY
}

prepare() { # <repo> <work> <arch> <version> <new.apk>...
  repo="$1" work="$2" arch="$3" version="$4"
  shift 4
  [ "$#" -gt 0 ] || { echo "ERROR: no packages to sign" >&2; exit 1; }
  for pkg in "$@"; do
    echo "  Checking ${pkg}"
    mkdir "${work}/${pkg}"
    split_package "${repo}/${pkg}" "${work}/${pkg}" "$arch" "$version"
  done
}

sign() { # <work> <key_name> <file>...
  work="$1" key_name="$2"
  shift 2
  for file in "$@"; do
    # -t RSA256: the default (RSA) signs with SHA-1.
    abuild-sign -q -t RSA256 -k "${KEY_DIR}/private.rsa" -p "$key_name" "${work}/${file}"
  done
}

assemble() { # <repo> <work> <new.apk>...
  repo="$1" work="$2"
  shift 2
  for pkg in "$@"; do
    echo "  Signed ${pkg}"
    cat "${work}/${pkg}/control.tar.gz" "${work}/${pkg}/data.tar.gz" > "${repo}/${pkg}"
  done
}

index() { # <repo> <work> <arch> <key_name> <description>
  repo="$1" work="$2" arch="$3" key_name="$4" description="$5"
  # Trust only the release key, without touching /etc/apk/keys.
  mkdir "${work}/keys"
  cp "${KEY_DIR}/${key_name}" "${work}/keys/${key_name}"
  # Hydrated packages were signed at their own publication; a package that
  # is not signed by the release key must not be indexed.
  echo "  Verifying every package against ${key_name}"
  for pkg in "$repo"/*.apk; do
    apk --keys-dir "${work}/keys" verify -q "$pkg" >/dev/null ||
      { echo "ERROR: ${pkg##*/} is not signed by ${key_name}" >&2; exit 1; }
  done
  # --rewrite-arch: apk downloads a package from <repo>/<arch in the index>/,
  # so noarch subpackages (-doc, -openrc, compat-redis*) must be indexed
  # under this directory's arch.
  (cd "$repo" && apk --keys-dir "${work}/keys" index -q --rewrite-arch "$arch" \
    -d "$description" -o "${work}/APKINDEX.tar.gz" ./*.apk)
  echo "  Indexed $(find "$repo" -maxdepth 1 -name '*.apk' | wc -l) package(s)"
}

command="$1"
shift
case "$command" in
  prepare|sign|assemble|index) "$command" "$@" ;;
  all)
    repo="$1" arch="$2" version="$3" key_name="$4" description="$5"
    shift 5
    work="$(mktemp -d)"
    prepare "$repo" "$work" "$arch" "$version" "$@"
    for pkg in "$@"; do sign "$work" "$key_name" "${pkg}/control.tar.gz"; done
    assemble "$repo" "$work" "$@"
    index "$repo" "$work" "$arch" "$key_name" "$description"
    sign "$work" "$key_name" APKINDEX.tar.gz
    mv "${work}/APKINDEX.tar.gz" "${repo}/APKINDEX.tar.gz"
    rm -rf "$work"
    ;;
  *) echo "Unknown command: ${command}" >&2; exit 1 ;;
esac
