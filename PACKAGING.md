# Valkey Packaging Build System

Comprehensive documentation for the Valkey release automation and packaging infrastructure.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Release Orchestration](#release-orchestration)
- [Package Build Pipeline (packages.yml)](#package-build-pipeline)
- [RPM Packaging](#rpm-packaging)
- [DEB Packaging](#deb-packaging)
- [Version Management](#version-management)
- [Cross-Version Upgrade Relationships](#cross-version-upgrade-relationships)
- [Patch System](#patch-system)
- [Documentation Handling](#documentation-handling)
- [Platform Support Matrix](#platform-support-matrix)
- [Build Validation](#build-validation)

---

## Architecture Overview

The build system is structured around GitHub Actions workflows that produce RPM and DEB packages for multiple Linux distributions and architectures.

```
valkey-release-automation/
├── .github/
│   ├── actions/
│   │   └── generate-package-build-matrix/   # Matrix generation action
│   │       ├── action.yml
│   │       └── build-config.json            # Platform/arch definitions
│   └── workflows/
│       ├── build-release.yml                # Master release orchestrator
│       ├── packages.yml                     # RPM + DEB package builder
│       ├── call-build-linux-x86-packages.yml
│       ├── call-build-linux-arm-packages.yml
│       ├── update-valkey-hashes.yml
│       ├── update-valkey-container.yml
│       ├── update-valkey-doc.yml
│       ├── update-valkey-website.yml
│       └── update-try-valkey.yml
└── packaging/
    ├── 7.x/                                 # Valkey 7.2.x packaging
    │   ├── rpm/
    │   │   ├── valkey.spec
    │   │   └── valkey-conf.patch
    │   └── debian/
    │       ├── control, rules, changelog
    │       ├── patches/
    │       └── ...
    ├── 8.x/                                 # Valkey 8.x packaging
    │   ├── rpm/
    │   └── debian/
    └── 9.x/                                 # Valkey 9.x packaging
        ├── rpm/
        └── debian/
```

### High-Level Flow

```
                    ┌──────────────────────────┐
                    │   GitHub Event Trigger    │
                    │  (dispatch / manual /     │
                    │   repository_dispatch)    │
                    └────────────┬─────────────┘
                                 │
                                 ▼
                    ┌──────────────────────────┐
                    │    build-release.yml      │
                    │  (Master Orchestrator)    │
                    └────────────┬─────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                   │
              ▼                  ▼                   ▼
     ┌─────────────┐   ┌──────────────┐   ┌──────────────────┐
     │  Tarball     │   │ packages.yml │   │  Post-Release    │
     │  Builds      │   │ (RPM + DEB)  │   │  (prod only)     │
     │  (x86+ARM)   │   │              │   │                  │
     └─────────────┘   └──────┬───────┘   │ - update hashes  │
                               │           │ - update docs     │
                    ┌──────────┴────────┐  │ - update website  │
                    │                   │  │ - update container│
                    ▼                   ▼  │ - try-valkey      │
             ┌───────────┐     ┌──────────┐│ - trigger bundle │
             │ RPM Builds│     │DEB Builds ││   (>= 8.1.0)    │
             │ (20 plat× │     │(5 plat×  ││                  │
             │  2 arch)  │     │ 2 arch)  │└──────────────────┘
             └───────────┘     └──────────┘
```

---

## Release Orchestration

### build-release.yml

The master workflow that orchestrates the entire release process.

**Triggers:**
- `repository_dispatch` — automated trigger from external systems
- `workflow_dispatch` — manual trigger with `version` and `environment` inputs
- `push` — on workflow file changes (runs as `unstable`/`dev`)

**Version validation:** Accepts `x.y.z`, `x.y.z-rcN`, or `unstable`.

**Environment modes:**
- `dev` — builds packages only (no external updates)
- `prod` — full release: packages + hashes + docs + website + containers

### Execution Flow (prod)

```
process-inputs ──► validate version, detect bundle eligibility (>= 8.1.0)
       │
       ├──► update-valkey-hashes ──► commit source SHA256 to valkey-hashes repo
       │           │
       │           ├──► update-valkey-container ──► update Docker definitions
       │           │           │
       │           │           └──► update-valkey-website ◄── update-try-valkey
       │           │
       │           └──► update-valkey-doc (only for X.Y.0 releases)
       │
       ├──► generate-build-matrix ──► release-build-linux-x86-packages
       │                          └──► release-build-linux-arm-packages
       │
       └──► trigger-valkey-bundle (>= 8.1.0 only)
```

---

## Package Build Pipeline

### packages.yml

The primary workflow for building distribution packages. Accepts a single `version` input and builds packages for that version only.

**Triggers:**
- `workflow_call` — called by `build-release.yml`
- `workflow_dispatch` — manual trigger for standalone builds

### Process Inputs Job

Derives the packaging directory from the version's major number:

```
Input version    Packaging dir
─────────────    ─────────────
7.2.12       →   packaging/7.x/
8.1.6        →   packaging/8.x/
9.0.3        →   packaging/9.x/
```

```yaml
MAJOR="${VERSION%%.*}"
packaging_dir="${MAJOR}.x"
```

### Build Pipeline Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                        packages.yml                               │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐                                                 │
│  │process-inputs│  version=9.0.3 → packaging_dir=9.x             │
│  └──────┬───────┘                                                 │
│         │                                                         │
│    ┌────┴────┐                                                    │
│    │         │                                                    │
│    ▼         ▼                                                    │
│ ┌──────┐ ┌──────┐                                                 │
│ │build-│ │build-│                                                 │
│ │ rpm  │ │ deb  │                                                 │
│ └──┬───┘ └──┬───┘                                                 │
│    │        │                                                     │
│    │  ┌─────┴──────────────────────────────────────┐              │
│    │  │  For each (platform × arch):               │              │
│    │  │  1. Launch Docker container                │              │
│    │  │  2. Copy packaging files from X.x/         │              │
│    │  │  3. Override version via sed               │              │
│    │  │  4. Download source tarball                │              │
│    │  │  5. Build (rpmbuild / dpkg-buildpackage)   │              │
│    │  │  6. Validate output packages               │              │
│    │  │  7. Upload artifacts                       │              │
│    │  └────────────────────────────────────────────┘              │
│    │                                                              │
│    ▼                                                              │
│ ┌──────────────┐                                                  │
│ │build-summary │  Aggregate results from all matrix builds        │
│ └──────────────┘                                                  │
└───────────────────────────────────────────────────────────────────┘
```

---

## RPM Packaging

### Spec File Structure

Each version branch has its own spec file at `packaging/X.x/rpm/valkey.spec`.

```
valkey.spec structure:
├── Conditionals         (%is_suse, %is_rhel, %is_amazon)
├── Macros               (build_flags, install_flags, doc_version)
├── Package metadata     (Name, Version, Release, License, Sources)
├── Build requirements   (per-platform conditional)
├── Main package         (valkey)
├── Subpackages
│   ├── valkey-devel
│   ├── valkey-compat-redis
│   ├── valkey-compat-redis-devel
│   └── valkey-doc (conditional)
├── %prep                (source extraction, patches, license moves)
├── %build               (make with build_flags)
├── %install             (binaries, configs, systemd units, symlinks)
├── %pre / %post         (user creation, systemd integration)
├── %files               (per-package file lists)
└── %changelog
```

### RPM Build Process

```
┌──────────────────────────────────────────────────────────┐
│                    RPM Build Steps                        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. Launch platform Docker container                     │
│     (e.g., rockylinux:9, opensuse/leap:15.6)            │
│                                                          │
│  2. Install build tools (rpm-build, gcc, make, etc.)     │
│                                                          │
│  3. Copy spec + supporting files to ~/rpmbuild/SPECS/    │
│                                                          │
│  4. ┌─ Override version fields via sed ──────────────┐   │
│     │ sed "s/^Version:.*/Version: 9.0.3/"            │   │
│     │ sed "s/^%global doc_version.*/%global doc_      │   │
│     │      version 9.0.0/"                           │   │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  5. Download source tarball to ~/rpmbuild/SOURCES/       │
│     valkey-9.0.3.tar.gz                                  │
│     valkey-doc-9.0.0.tar.gz (if docs enabled)            │
│                                                          │
│  6. rpmbuild -ba valkey.spec [--without docs]            │
│     ├── %prep: extract, apply valkey-conf.patch          │
│     ├── %build: make with BUILD_TLS, SYSTEMD, JEMALLOC  │
│     ├── %install: install binaries, configs, symlinks    │
│     └── Package: create RPMs in ~/rpmbuild/RPMS/         │
│                                                          │
│  7. Validate output (query, files, arch, size > 500KB)   │
│                                                          │
│  8. Upload RPMs as GitHub Actions artifacts               │
└──────────────────────────────────────────────────────────┘
```

### Build Flags

| Flag | Value | Purpose |
|------|-------|---------|
| `BUILD_WITH_SYSTEMD` | yes | Enable systemd notify support |
| `BUILD_TLS` | yes | Enable TLS/SSL support |
| `USE_SYSTEM_JEMALLOC` | yes | Link against system jemalloc |
| `DEBUG` | "" | Disable debug symbols in build |
| `V` | 1 | Verbose build output |

### Platform-Specific Conditionals

The spec file adapts to different platforms using RPM conditionals:

```
┌───────────────┬─────────────────────────────────────────────────┐
│ Platform      │ Behavior                                        │
├───────────────┼─────────────────────────────────────────────────┤
│ SUSE/openSUSE │ %is_suse=1: sysusers, docs ON by default,     │
│               │ Recommends logrotate, libopenssl-devel          │
├───────────────┼─────────────────────────────────────────────────┤
│ RHEL/Rocky/   │ %is_rhel=1: shadow-utils for user creation,    │
│ Alma/Oracle   │ docs OFF by default, Requires logrotate,        │
│               │ systemd-rpm-macros (EL8+), openssl-devel 3.0+   │
│               │ (EL9+)                                          │
├───────────────┼─────────────────────────────────────────────────┤
│ Amazon Linux  │ %is_amazon=1: similar to RHEL, systemd macros  │
├───────────────┼─────────────────────────────────────────────────┤
│ Fedora        │ Treated as RHEL; docs build deps removed at     │
│               │ workflow level (pandoc unavailable)              │
└───────────────┴─────────────────────────────────────────────────┘
```

### RPM Subpackages

```
┌─────────────────────────┬──────────────────────────────────────────┐
│ Package                 │ Contents                                 │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey                  │ Server, sentinel, config, systemd units, │
│                         │ logrotate, sysctl, tmpfiles, user setup  │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-devel            │ valkeymodule.h, RPM macros for modules   │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-compat-redis     │ redis-* symlinks, migration script,      │
│                         │ redis systemd unit symlinks              │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-compat-redis-    │ redismodule.h (legacy Redis API header)  │
│ devel                   │                                          │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-doc              │ Man pages (sections 1,3,5,7), HTML docs  │
│ (conditional)           │ Built only when pandoc is available      │
└─────────────────────────┴──────────────────────────────────────────┘
```

### Installed File Layout

```
/usr/bin/
├── valkey-server
├── valkey-cli
├── valkey-benchmark
├── valkey-check-aof     → valkey-server (symlink)
├── valkey-check-rdb     → valkey-server (symlink)
└── valkey-sentinel      → valkey-server (symlink)

/etc/valkey/
├── includes/
│   ├── valkey.defaults.conf     (shipped defaults)
│   └── sentinel.defaults.conf
├── default.conf                 (instance config)
└── sentinel-default.conf

/var/lib/valkey/default/         (data directory, 0750, valkey:valkey)
/var/log/valkey/default/         (log directory, 0750, valkey:valkey)
/run/valkey/                     (runtime PID files, tmpfiles.d)

/usr/lib/systemd/system/
├── valkey.target
├── valkey@.service              (template for multiple instances)
├── valkey-sentinel.target
└── valkey-sentinel@.service
```

---

## DEB Packaging

### Debian Directory Structure

```
packaging/X.x/debian/
├── control                      # Source + binary package definitions
├── rules                        # Build rules (Makefile)
├── changelog                    # Package changelog
├── compat                       # Debhelper compat level
├── copyright                    # License information
├── source/
│   └── format                   # Source format (3.0 quilt)
├── patches/
│   ├── series                   # Patch application order
│   ├── debian-packaging/
│   │   └── 0001-Set-Debian-configuration-defaults.patch
│   ├── 0001-Fix-FTBFS-on-kFreeBSD.patch
│   ├── 0002-Add-CPPFLAGS-to-upstream-makefiles.patch
│   ├── 0003-Use-get_current_dir_name-over-PATHMAX.patch
│   └── 0004-Add-support-for-USE_SYSTEM_JEMALLOC-flag.patch
├── bin/
│   └── generate-systemd-service-files
├── tests/
│   └── control                  # Autopkgtest definitions
├── upstream/
│   └── metadata
├── valkey-server.install        # File lists per package
├── valkey-server.dirs
├── valkey-sentinel.install
├── valkey-tools.install
├── valkey-dev.install
├── valkey-compat-redis.install
├── valkey-compat-redis-dev.install
├── valkey-doc.install           # (not in 7.x — no docs available)
├── valkey-server.manpages       # (not in 7.x)
├── valkey-tools.manpages        # (not in 7.x)
└── valkey-sentinel.manpages     # (not in 7.x)
```

### DEB Build Process

```
┌──────────────────────────────────────────────────────────┐
│                    DEB Build Steps                        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. Launch platform Docker container                     │
│     (e.g., debian:bookworm, ubuntu:noble)                │
│                                                          │
│  2. Extract source tarball, copy debian/ directory into   │
│     source tree                                          │
│                                                          │
│  3. ┌─ Override doc version via sed ─────────────────┐   │
│     │ sed "s/^VALKEY_DOC_VERSION = .*/VALKEY_DOC_     │   │
│     │      VERSION = 9.0.0/" debian/rules            │   │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  4. Update debian/changelog:                             │
│     dch -v "9.0.3-1.bookworm" -D bookworm               │
│     "Automated build for bookworm"                       │
│                                                          │
│  5. Install build dependencies:                          │
│     mk-build-deps --install debian/control               │
│                                                          │
│  6. dpkg-buildpackage -b -us -uc -a${ARCH}              │
│     ├── Apply patches (series file, --fuzz=0)            │
│     ├── dh_auto_build (make with flags)                  │
│     ├── Download + build valkey-doc (if available)       │
│     ├── dh_auto_install (manual binary/config install)   │
│     ├── Generate systemd service files                   │
│     └── Package .deb files                               │
│                                                          │
│  7. Validate output (architecture, metadata)             │
│                                                          │
│  8. Upload .deb, .ddeb, .buildinfo, .changes as          │
│     GitHub Actions artifacts                             │
└──────────────────────────────────────────────────────────┘
```

### DEB Build Flags

Set in `debian/rules`:

| Variable | Value | Purpose |
|----------|-------|---------|
| `BUILD_TLS` | yes | TLS support |
| `USE_SYSTEM_JEMALLOC` | yes | System jemalloc (not bundled) |
| `USE_SYSTEMD` | yes | Systemd notify support |
| `DEB_BUILD_MAINT_OPTIONS` | hardening=+all optimize=+lto | Full hardening + LTO |
| `DEB_CFLAGS_MAINT_APPEND` | -I/usr/include/liblzf | LZF compression headers |
| `DEB_LDFLAGS_MAINT_APPEND` | -Wl,-no-as-needed -ldl -latomic -llzf | Required linker flags |

### DEB Binary Packages

```
┌─────────────────────────┬──────────────────────────────────────────┐
│ Package                 │ Contents                                 │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-server           │ Server binary, configs, systemd units    │
│                         │ Provides: valkey                         │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-sentinel         │ Sentinel service (symlink to server)     │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-tools            │ valkey-cli, valkey-benchmark              │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-dev              │ valkeymodule.h for module development    │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-compat-redis     │ redis-* symlinks                        │
│                         │ Provides: redis-server, redis-tools      │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-compat-redis-dev │ redismodule.h                            │
│                         │ Provides: redis-dev                      │
├─────────────────────────┼──────────────────────────────────────────┤
│ valkey-doc              │ Man pages + HTML documentation           │
│                         │ (not available for 7.x)                  │
└─────────────────────────┴──────────────────────────────────────────┘
```

### Special DEB Build Overrides

The `debian/rules` file overrides several `dh_*` targets:

- **`override_dh_auto_build`** — builds Valkey with flags; downloads and builds valkey-doc
- **`override_dh_auto_install`** — manual binary installation with precise symlink control
- **`override_dh_auto_test`** — currently disabled (commented out)
- **`override_dh_installsystemd`** — installs both regular and template (`@`) service units
- **`override_dh_fixperms`** — restricts config file permissions to valkey group
- **`override_dh_builddeb`** — uses xz compression (`-Zxz`)

---

## Version Management

### Version Override at Build Time

Neither RPM specs nor DEB packaging files need manual version updates. The workflow overrides versions dynamically using `sed` at build time:

```
Input: version = 9.0.3

                        ┌─────────────────┐
                        │  packages.yml    │
                        └────────┬────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
           ┌──────────────┐          ┌──────────────┐
           │   RPM Build  │          │   DEB Build  │
           └──────┬───────┘          └──────┬───────┘
                  │                         │
    sed on valkey.spec:              sed on debian/rules:
    Version: 9.0.3                   VALKEY_DOC_VERSION = 9.0.0
    %global doc_version 9.0.0
                                     dch -v "9.0.3-1.bookworm"
                                     (updates debian/changelog)
```

### Doc Version Derivation

The doc version zeroes out the patch component:

```
version      → doc_version
─────────      ───────────
9.0.3        → 9.0.0
8.1.6        → 8.1.0
7.2.12       → 7.2.0
```

Calculated via:
```bash
DOC_VERSION=$(echo "${VERSION}" | sed "s/\.[0-9]*$/.0/")
```

### Packaging Directory Selection

```
version=9.0.3  →  MAJOR=9  →  packaging/9.x/
version=8.1.6  →  MAJOR=8  →  packaging/8.x/
version=7.2.12 →  MAJOR=7  →  packaging/7.x/
```

---

## Cross-Version Upgrade Relationships

Packages declare upgrade relationships so newer major versions cleanly replace older ones.

### Upgrade Path Diagram

```
    ┌───────────┐      ┌───────────┐      ┌───────────┐
    │  Valkey    │      │  Valkey    │      │  Valkey    │
    │  7.x      │─────►│  8.x      │─────►│  9.x      │
    │           │      │           │      │           │
    │ (base)    │      │ Obsoletes │      │ Obsoletes │
    │           │      │ valkey<8.0│      │ valkey<9.0│
    └───────────┘      └───────────┘      └───────────┘
         │                                      ▲
         └──────────────────────────────────────┘
                   (also upgrades directly)
```

### RPM Relationships

Uses `Obsoletes:` to indicate that this package supersedes older versions:

| Version | Directive | Effect |
|---------|-----------|--------|
| 7.x | *(none)* | Base version, no predecessors |
| 8.x | `Obsoletes: valkey < 8.0` | Replaces 7.x on upgrade |
| 9.x | `Obsoletes: valkey < 9.0` | Replaces 7.x and 8.x on upgrade |

Applied to all subpackages: `valkey`, `valkey-devel`, `valkey-compat-redis`, `valkey-compat-redis-devel`, `valkey-doc`.

### DEB Relationships

Uses `Replaces:` + `Breaks:` pair (the Debian standard for upgrade replacement):

| Version | Directives | Effect |
|---------|------------|--------|
| 7.x | *(none)* | Base version |
| 8.x | `Replaces: valkey-server (<< 8.0~)` | Can overwrite 7.x files |
|     | `Breaks: valkey-server (<< 8.0~)` | Forces removal of 7.x |
| 9.x | `Replaces: valkey-server (<< 9.0~)` | Can overwrite 7.x/8.x files |
|     | `Breaks: valkey-server (<< 9.0~)` | Forces removal of 7.x/8.x |

Applied to all binary packages: `valkey-server`, `valkey-sentinel`, `valkey-tools`, `valkey-dev`, `valkey-compat-redis`, `valkey-compat-redis-dev`, `valkey-doc`.

> **Note:** The `~` suffix in `(<< 8.0~)` sorts before any pre-release versions, ensuring `8.0~rc1` is also covered.

### Redis Compatibility Relationships

In addition to cross-version Valkey upgrades, the `compat-redis` packages handle Redis migration:

```
RPM (Fedora > 40 / RHEL > 9):
  Obsoletes: redis < 7.4
  Provides:  redis = %{version}-%{release}

RPM (older platforms):
  Conflicts: redis < 7.4

DEB:
  Conflicts: redis-server (<< 7.4~), redis-tools (<< 7.4~)
  Provides:  redis-server, redis-tools
  Replaces:  redis-server (<< 7.4~), redis-tools (<< 7.4~)
```

---

## Patch System

### RPM Patches

Each version has a single RPM patch applied during `%prep`:

```
packaging/X.x/rpm/valkey-conf.patch
```

This patch modifies `valkey.conf` and `sentinel.conf` for production defaults:

| Setting | Upstream Default | Patched Value |
|---------|-----------------|---------------|
| `supervised` | `# supervised auto` | `supervised systemd` |
| `pidfile` | `/var/run/valkey_6379.pid` | `/run/valkey/default.pid` |
| `logfile` | `""` | `/var/log/valkey/default.log` |
| `dir` | `./` | `/var/lib/valkey/default/` |

It also creates two new files: `valkey.default.conf` and `sentinel.default.conf` (instance configs that include the defaults).

### DEB Patches

Applied via `dpkg-source` with `--fuzz=0` (strict matching). The patch series is:

```
┌─── debian/patches/series (application order) ─────────────────────┐
│                                                                    │
│  1. debian-packaging/0001-Set-Debian-configuration-defaults.patch  │
│     └─ Modifies valkey.conf + sentinel.conf for Debian paths       │
│        (daemonize, pidfile, logfile, dir settings)                  │
│                                                                    │
│  2. 0001-Fix-FTBFS-on-kFreeBSD.patch                              │
│     └─ Fixes __GLIBC__ / _XOPEN_SOURCE for BSD builds             │
│                                                                    │
│  3. 0002-Add-CPPFLAGS-to-upstream-makefiles.patch                 │
│     └─ Propagates CPPFLAGS through src/Makefile and deps/Makefile  │
│                                                                    │
│  4. 0003-Use-get_current_dir_name-over-PATHMAX.patch              │
│     └─ Removes PATH_MAX dependency (portability fix)               │
│                                                                    │
│  5. 0004-Add-support-for-USE_SYSTEM_JEMALLOC-flag.patch           │
│     └─ Enables building against system jemalloc instead of bundled │
│        (critical for Debian policy compliance)                     │
└────────────────────────────────────────────────────────────────────┘
```

### Version-Specific Patch Differences

Patches differ across version branches because the source code differs:

```
┌──────────────────┬────────────────┬────────────────┬────────────────┐
│ Difference       │ 7.x            │ 8.x            │ 9.x            │
├──────────────────┼────────────────┼────────────────┼────────────────┤
│ CC variable      │ REDIS_CC       │ SERVER_CC      │ SERVER_CC -I.  │
│ LD variable      │ REDIS_LD       │ SERVER_LD      │ SERVER_LD      │
│ Bundled lib      │ hiredis        │ hiredis        │ libvalkey      │
│ dir ./ line      │ 507            │ ~631           │ ~706           │
│ debug.c params   │ (eip, uplevel) │ (eip, uplevel, │ (eip, uplevel, │
│                  │                │  process_id)   │  process_id)   │
│ valkey-doc avail │ No (none)      │ Yes (8.x.0+)  │ Yes (9.x.0+)  │
│ fast_float       │ No             │ No             │ Yes            │
└──────────────────┴────────────────┴────────────────┴────────────────┘
```

> **Important:** Patches must be regenerated from actual source diffs when updating. The `--fuzz=0` flag means context lines must match exactly.

---

## Documentation Handling

### Availability by Version

```
┌─────────┬──────────────┬─────────────────────────────────────┐
│ Version │ Doc Available │ Notes                               │
├─────────┼──────────────┼─────────────────────────────────────┤
│ 7.x     │ No           │ No valkey-doc release exists for 7.x│
│         │              │ (earliest tag is 8.0.0). Build      │
│         │              │ skips docs gracefully. No valkey-doc │
│         │              │ DEB package produced.                │
├─────────┼──────────────┼─────────────────────────────────────┤
│ 8.x     │ Yes          │ Downloads valkey-doc-8.x.0.tar.gz   │
├─────────┼──────────────┼─────────────────────────────────────┤
│ 9.x     │ Yes          │ Downloads valkey-doc-9.x.0.tar.gz   │
└─────────┴──────────────┴─────────────────────────────────────┘
```

### RPM Doc Build Behavior

```
SUSE:       %bcond_without docs  →  docs ON by default
RHEL:       %bcond_with docs     →  docs OFF by default
Fedora:     pandoc removed from BuildRequires → no docs
Workflow:   --without docs passed when pandoc unavailable
```

### DEB Doc Build Behavior

```
Build profile "nodoc"  →  skips doc download + build
Default (no profile)   →  attempts download; 7.x handles failure gracefully
```

---

## Platform Support Matrix

### RPM Platforms

| Distribution | Versions | Architectures |
|-------------|----------|---------------|
| openSUSE Leap | 15.5, 15.6 | x86_64, aarch64 |
| Oracle Linux | 8, 9, 10 | x86_64, aarch64 |
| Rocky Linux | 8, 9, 10 | x86_64, aarch64 |
| AlmaLinux | 8, 9, 10 | x86_64, aarch64 |
| Amazon Linux | 2023 | x86_64, aarch64 |
| Fedora | 39, 40, 41 | x86_64, aarch64 |

### DEB Platforms

| Distribution | Codename | Architectures |
|-------------|----------|---------------|
| Debian 11 | Bullseye | amd64, arm64 |
| Debian 12 | Bookworm | amd64, arm64 |
| Debian 13 | Trixie | amd64, arm64 |
| Ubuntu 22.04 | Jammy | amd64, arm64 |
| Ubuntu 24.04 | Noble | amd64, arm64 |

### Total Build Matrix

```
RPM:  16 platforms × 2 architectures = 32 builds
DEB:   5 platforms × 2 architectures = 10 builds
                                       ─────────
                              Total:   42 builds per version
```

---

## Build Validation

### RPM Validation Checks

After each RPM build, the workflow performs:

1. **Package query** — `rpm -qip $MAIN_RPM` succeeds
2. **Required binaries** — `/usr/bin/valkey-server` and `/usr/bin/valkey-cli` exist in the package
3. **Architecture check** — RPM architecture field matches expected arch (or `noarch`)
4. **Size check** — Main RPM is > 500KB (catches empty/broken builds)

### DEB Validation Checks

After each DEB build, the workflow performs:

1. **Package discovery** — finds `valkey-server_${VERSION}*.deb` in output
2. **Architecture field** — `dpkg-deb --field Architecture` matches expected arch
3. **Metadata dump** — `dpkg-deb --info` for inspection

---

