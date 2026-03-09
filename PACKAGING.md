# Valkey Packaging Build System

Comprehensive documentation for the Valkey release automation and packaging infrastructure.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Release Orchestration](#release-orchestration)
- [Package Build Pipeline (packages.yml)](#package-build-pipeline)
- [RPM Packaging](#rpm-packaging)
- [DEB Packaging](#deb-packaging)
- [Version Management](#version-management)
  - [Template System (8.1/9.0+)](#template-system-8190)
- [Cross-Version Upgrade Relationships](#cross-version-upgrade-relationships)
- [Patch System](#patch-system)
- [Documentation Handling](#documentation-handling)
- [Platform Support Matrix](#platform-support-matrix)
- [Package Hosting Architecture](#package-hosting-architecture)
- [Build Validation](#build-validation)
- [Scripts Reference](#scripts-reference)

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
├── scripts/
│   ├── build-rpm.sh                         # RPM build script (runs in Docker)
│   ├── build-deb.sh                         # DEB build script (runs in Docker)
│   ├── generate-from-templates.sh           # Template processor (8.1/9.0+)
│   ├── publish-to-s3.sh                     # Sign packages + build repos, upload to S3
│   ├── publish-repos.sh                     # Generate GH Pages site (install instructions)
│   ├── setup-github-pages.sh                # One-time GPG + GH Pages + S3 setup
│   ├── test_packages.sh                     # Package install/removal test suite
│   ├── test_in_docker.sh                    # Run test_packages.sh in Docker locally
│   ├── build-packages.sh                    # Legacy standalone build script
│   ├── automate_alias_update.py             # Update valkey-hashes aliases
│   ├── automate_website_description.py      # Update website descriptions
│   ├── extract_hashes_info.py               # Extract hash info for releases
│   └── pages/
│       └── index.html                       # GH Pages template with install instructions
└── packaging/
    ├── common/                              # Shared files across all versions
    │   ├── rpm/                             # Shared RPM sources
    │   └── debian/                          # Shared DEB files
    │       ├── valkey-doc.install
    │       ├── valkey-doc.manpages
    │       ├── valkey-sentinel.manpages
    │       ├── valkey-server.manpages
    │       ├── valkey-tools.manpages
    │       └── ...
    ├── templates/                           # Templates for 8.1/9.0+ (see below)
    │   ├── debian/
    │   │   ├── control.template             # @@MAJOR_VERSION@@ placeholder
    │   │   └── rules.template               # @@DOC_VERSION@@ placeholder
    │   └── rpm/
    │       ├── valkey.spec.template          # Multiple placeholders
    │       ├── changelog-8.1                # RPM changelog for 8.1
    │       └── changelog-9.0                # RPM changelog for 9.0
    ├── 7.2/                                 # Valkey 7.2.x packaging (no templates)
    │   ├── rpm/
    │   │   ├── valkey.spec
    │   │   └── valkey-conf.patch
    │   └── debian/
    │       ├── control, rules, changelog
    │       ├── patches/
    │       └── ...
    ├── 8.1/                                 # Valkey 8.1.x overrides only
    │   ├── rpm/
    │   │   └── valkey-conf.patch            # (spec generated from template)
    │   └── debian/
    │       ├── changelog                    # (control/rules generated from template)
    │       └── patches/
    └── 9.0/                                 # Valkey 9.0.x overrides only
        ├── rpm/
        │   └── valkey-conf.patch            # (spec generated from template)
        └── debian/
            ├── changelog                    # (control/rules generated from template)
            └── patches/
```

### High-Level Flow

```
    ┌──────────────────────────┐          ┌──────────────────────────┐
    │   GitHub Event Trigger    │          │   Manual / workflow_call  │
    │  (dispatch / manual /     │          │                          │
    │   repository_dispatch)    │          │                          │
    └────────────┬─────────────┘          └────────────┬─────────────┘
                 │                                      │
                 ▼                                      ▼
    ┌──────────────────────────┐          ┌──────────────────────────┐
    │    build-release.yml      │          │      packages.yml         │
    │  (Master Orchestrator)    │          │  (RPM + DEB Packages)     │
    └────────────┬─────────────┘          └────────────┬─────────────┘
                 │                                      │
      ┌──────────┼──────────┐               ┌──────────┴────────┐
      │          │          │               │                   │
      ▼          ▼          ▼               ▼                   ▼
  ┌────────┐ ┌────────┐ ┌───────────┐  ┌───────────┐     ┌──────────┐
  │Tarball │ │Post-   │ │ trigger   │  │ RPM Builds│     │DEB Builds│
  │Builds  │ │Release │ │ bundle    │  │ (15 plat× │     │(5 plat×  │
  │(x86+   │ │(prod)  │ │(>= 8.1.0)│  │  2 arch)  │     │ 2 arch)  │
  │ ARM)   │ │        │ │           │  └─────┬─────┘     └────┬─────┘
  └────────┘ │- hashes│ └───────────┘        │                │
             │- docs  │                      ▼                ▼
             │- site  │                ┌──────────┐     ┌──────────┐
             │- cont. │                │ Test RPM │     │ Test DEB │
             └────────┘                └──────────┘     └──────────┘
                                             │                │
                                             ▼                ▼
                                       ┌──────────────────────────┐
                                       │  publish-to-s3 → S3      │
                                       └────────────┬─────────────┘
                                                    │
                                                    ▼
                                       ┌──────────────────────────┐
                                       │  deploy-pages → GH Pages │
                                       └──────────────────────────┘
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
       ├──► generate-build-matrix ──► release-build-linux-x86-packages  (tarballs → S3)
       │                          └──► release-build-linux-arm-packages  (tarballs → S3)
       │
       └──► trigger-valkey-bundle (>= 8.1.0 only)
```

### packages.yml (RPM + DEB Builds)

`packages.yml` is a **separate workflow** that builds RPM and DEB distribution packages. It runs independently from `build-release.yml` and can be triggered via:
- `workflow_call` — invoked by other workflows
- `workflow_dispatch` — manual trigger with a `version` input

```
packages.yml
       │
       ├──► process-inputs ──► derive packaging_dir (e.g., 9.0)
       │
       ├──► build-rpm (15 platforms × 2 arches)
       │       ├── merge common/ + N.M/ packaging
       │       ├── generate spec from template (8.1/9.0+)
       │       ├── build RPMs in Docker
       │       └── upload artifacts
       │
       ├──► build-deb (5 platforms × 2 arches)
       │       ├── merge common/ + N.M/ packaging
       │       ├── generate control/rules from template (8.1/9.0+)
       │       ├── build DEBs in Docker
       │       └── upload artifacts
       │
       ├──► test-rpm ──► install + systemd test on each platform
       ├──► test-deb ──► install + systemd test on each platform
       │
       ├──► publish-to-s3 ──► sign packages + create APT/YUM repos → upload to S3
       ├──► deploy-pages ──► generate install instructions → deploy to GitHub Pages
       │
       └──► build-summary ──► aggregate results
```

---

## Package Build Pipeline

### packages.yml

The primary workflow for building distribution packages. Accepts a single `version` input and builds packages for that version only.

**Triggers:**
- `workflow_call` — called by `build-release.yml`
- `workflow_dispatch` — manual trigger for standalone builds

### Process Inputs Job

Derives the packaging directory from the version's **major.minor** number. Each major.minor version has its own packaging directory:

```
Input version    Packaging dir     Doc version    Notes
─────────────    ──────────────    ───────────    ─────
7.2.12       →   packaging/7.2/    7.2.0          No templates (files maintained directly)
8.1.6        →   packaging/8.1/    8.1.0          Templates with hiredis bundled dep
9.0.3        →   packaging/9.0/    9.0.0          Templates with libvalkey bundled dep
9.1.0        →   packaging/9.1/    9.1.0          Templates with libvalkey bundled dep (*)
10.0.1       →   packaging/10.0/   10.0.0         Templates with libvalkey bundled dep (*)
```

Each major.minor version has its own packaging directory and S3 repository. For example, `9.0.x` uses `packaging/9.0/` and publishes to `valkey-9.0/`, while `9.1.x` uses `packaging/9.1/` and publishes to `valkey-9.1/`.

> (*) **New versions require setup:** create `packaging/N.M/` with version-specific files and `packaging/templates/rpm/changelog-N.M`. See [Adding a new version](#template-system-8190) for details.

```yaml
MAJOR="${VERSION%%.*}"
MINOR_PART="${VERSION#*.}"
MINOR="${MINOR_PART%%.*}"
packaging_dir="${MAJOR}.${MINOR}"
```

### Build Pipeline Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                        packages.yml                               │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐                                                 │
│  │process-inputs│  version=9.0.3 → packaging_dir=9.0             │
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
│    │  │  2. Merge common/ + N.M/ packaging files    │              │
│    │  │  3. Generate files from templates (8.1/9.0+)│              │
│    │  │  4. Override version via sed               │              │
│    │  │  5. Download source tarball                │              │
│    │  │  6. Build (rpmbuild / dpkg-buildpackage)   │              │
│    │  │  7. Validate output packages               │              │
│    │  │  8. Upload artifacts                       │              │
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

For **7.2**, the spec file lives at `packaging/7.2/rpm/valkey.spec` (maintained manually).

For **8.1, 9.0, and later**, the spec file is **generated from a template** at build time by `scripts/generate-from-templates.sh` using `packaging/templates/rpm/valkey.spec.template`. This avoids maintaining near-identical spec files across versions.

```
valkey.spec.template structure:
├── Conditionals         (%is_suse, %is_rhel, %is_amazon)
├── Macros               (build_flags, install_flags, doc_version)
├── Package metadata     (Name, Version, Release, License, Sources)
│   └── @@BUNDLED_DEP_NAME@@, @@BUNDLED_DEP_PROVIDES@@  (hiredis vs libvalkey)
├── Build requirements   (per-platform conditional)
├── Main package         (valkey)
│   └── Obsoletes: valkey < @@MAJOR_VERSION@@.0
├── Subpackages          (each with Obsoletes: < @@MAJOR_VERSION@@.0)
│   ├── valkey-devel
│   ├── valkey-compat-redis
│   ├── valkey-compat-redis-devel
│   └── valkey-doc (conditional)
├── %prep                (source extraction, patches, license moves)
│   └── deps/@@BUNDLED_DEP_DIR@@/COPYING → COPYING-@@BUNDLED_DEP_NAME@@-BSD-3-Clause
├── %build               (make with build_flags)
├── %install             (binaries, configs, systemd units, symlinks)
├── %pre / %post         (user creation, systemd integration)
├── %files               (per-package file lists)
└── %changelog           (@@CHANGELOG@@ → from changelog-N.M file)
```

**Template placeholders:**

| Placeholder | 8.1 Value | 9.0 / 10.0 Value |
|-------------|-----------|-------------------|
| `@@MAJOR_VERSION@@` | `8` | `9` / `10` |
| `@@MINOR@@` | `1` | `0` / `0` |
| `@@SPEC_VERSION@@` | `8.1.6` (from input) | `9.0.3` / `10.0.1` (from input) |
| `@@BUNDLED_DEP_NAME@@` | `hiredis` | `libvalkey` |
| `@@BUNDLED_DEP_PROVIDES@@` | `Provides: bundled(hiredis)` | `Provides: bundled(libvalkey) = 1.0.0` |
| `@@BUNDLED_DEP_DIR@@` | `hiredis` | `libvalkey` |
| `@@CHANGELOG@@` | Contents of `changelog-8.1` | Contents of `changelog-9.0` / `changelog-10.0` |

> **Note:** The bundled dependency switches from `hiredis` to `libvalkey` at major version 9. All versions >= 9 (including future 10.x, 11.x, etc.) use `libvalkey` unless the logic in `generate-from-templates.sh` is updated.

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
│  3. Merge common/ + N.M/ packaging files into /packaging │
│                                                          │
│  4. ┌─ Generate spec from template (8.1/9.0+) ──────┐   │
│     │ generate-from-templates.sh --type rpm            │   │
│     │   Substitutes: @@MAJOR_VERSION@@,                │   │
│     │   @@BUNDLED_DEP_NAME/PROVIDES/DIR@@,             │   │
│     │   @@CHANGELOG@@ from changelog-N.M              │   │
│     │ (7.2: uses spec directly, no template)           │   │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  5. Copy spec + supporting files to ~/rpmbuild/SPECS/    │
│                                                          │
│  6. ┌─ Override version fields via sed ──────────────┐   │
│     │ sed "s/^Version:.*/Version: 9.0.3/"            │   │
│     │ sed "s/^%global doc_version.*/%global doc_      │   │
│     │      version 9.0.0/"                           │   │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  7. Download source tarball to ~/rpmbuild/SOURCES/       │
│     valkey-9.0.3.tar.gz                                  │
│     valkey-doc-9.0.0.tar.gz (if docs enabled)            │
│                                                          │
│  8. rpmbuild -ba valkey.spec [--without docs]            │
│     ├── %prep: extract, apply valkey-conf.patch          │
│     ├── %build: make with BUILD_TLS, SYSTEMD, JEMALLOC  │
│     ├── %install: install binaries, configs, symlinks    │
│     └── Package: create RPMs in ~/rpmbuild/RPMS/         │
│                                                          │
│  9. Validate output (query, files, arch, size > 500KB)   │
│                                                          │
│ 10. Upload RPMs as GitHub Actions artifacts               │
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

For **8.1, 9.0, and later**, `control` and `rules` are **generated from templates** at build time. The version-specific directories only contain files that truly differ per version (changelog, patches, conf patch). Files identical across versions (manpages, install lists) live in `packaging/common/debian/`.

```
packaging/common/debian/         # Shared across all versions
├── valkey-doc.install
├── valkey-doc.manpages
├── valkey-sentinel.manpages
├── valkey-server.manpages
├── valkey-tools.manpages
├── bin/
│   └── generate-systemd-service-files
├── ...                          # Other shared files

packaging/templates/debian/      # Templates for 8.1/9.0+
├── control.template             # @@MAJOR_VERSION@@ → Replaces/Breaks
└── rules.template               # @@DOC_VERSION@@ → VALKEY_DOC_VERSION

packaging/N.M/debian/            # Version-specific overrides only
├── changelog                    # Package changelog (version-specific)
├── patches/                     # Patches (differ per version)
│   ├── series
│   ├── debian-packaging/
│   │   └── 0001-Set-Debian-configuration-defaults.patch
│   ├── 0001-Fix-FTBFS-on-kFreeBSD.patch
│   ├── 0002-Add-CPPFLAGS-to-upstream-makefiles.patch
│   ├── 0003-Use-get_current_dir_name-over-PATHMAX.patch
│   └── 0004-Add-support-for-USE_SYSTEM_JEMALLOC-flag.patch
└── valkey-conf.patch            # (if present)

Note: 7.2 retains the traditional layout with control, rules, and all
files directly in packaging/7.2/debian/ (no templates used).
```

**Template placeholders (DEB):**

| Placeholder | Example 8.1 | Example 9.1 |
|-------------|-------------|-------------|
| `@@MAJOR_VERSION@@` (control) | `8` | `9` |
| `@@MINOR@@` (control) | `1` → `Breaks: valkey-server (<< 8.1~)` | `1` → `Breaks: valkey-server (<< 9.1~)` |
| `@@DOC_VERSION@@` (rules) | `8.1.0` | `9.1.0` |

### DEB Build Process

```
┌──────────────────────────────────────────────────────────┐
│                    DEB Build Steps                        │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. Launch platform Docker container                     │
│     (e.g., debian:bookworm, ubuntu:noble)                │
│                                                          │
│  2. Merge common/ + N.M/ packaging files into /packaging │
│                                                          │
│  3. ┌─ Generate control/rules from template (8.1/9.0+)─┐ │
│     │ generate-from-templates.sh --type deb             │ │
│     │   control: @@MAJOR_VERSION@@ → 9                  │ │
│     │   rules:   @@DOC_VERSION@@ → 9.0.0               │ │
│     │ (7.2: uses files directly, no template)           │ │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  4. Extract source tarball, copy debian/ directory into   │
│     source tree                                          │
│                                                          │
│  5. ┌─ Override doc version via sed ─────────────────┐   │
│     │ sed "s/^VALKEY_DOC_VERSION = .*/VALKEY_DOC_     │   │
│     │      VERSION = 9.0.0/" debian/rules            │   │
│     └────────────────────────────────────────────────┘   │
│                                                          │
│  6. Update debian/changelog:                             │
│     dch -v "9.0.3-1.bookworm" -D bookworm               │
│     "Automated build for bookworm"                       │
│                                                          │
│  7. Install build dependencies:                          │
│     mk-build-deps --install debian/control               │
│                                                          │
│  8. dpkg-buildpackage -b -us -uc -a${ARCH}              │
│     ├── Apply patches (series file, --fuzz=0)            │
│     ├── dh_auto_build (make with flags)                  │
│     ├── Download + build valkey-doc (if available)       │
│     ├── dh_auto_install (manual binary/config install)   │
│     ├── Generate systemd service files                   │
│     └── Package .deb files                               │
│                                                          │
│  9. Validate output (architecture, metadata)             │
│                                                          │
│ 10. Upload .deb, .ddeb, .buildinfo, .changes as          │
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
│                         │ (not available for 7.2)                  │
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

Version management uses a two-layer approach:

1. **Template generation** (8.1/9.0+): `generate-from-templates.sh` creates version-specific `control`, `rules`, and `valkey.spec` from templates, substituting major-version-dependent values (Obsoletes thresholds, bundled dependency names, changelogs).

2. **Sed overrides** (all versions): Build scripts dynamically set the exact patch version via `sed` at build time.

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
  1. Template:                     1. Template:
     spec.template → valkey.spec      control.template → control
     @@MAJOR_VERSION@@ = 9            @@MAJOR_VERSION@@ = 9
     @@BUNDLED_DEP_*@@ = libvalkey    rules.template → rules
     @@CHANGELOG@@ = changelog-9.0   @@DOC_VERSION@@ = 9.0.0
                  │                         │
  2. sed on valkey.spec:           2. sed on debian/rules:
     Version: 9.0.3                   VALKEY_DOC_VERSION = 9.0.0
     %global doc_version 9.0.0
                                      dch -v "9.0.3-1.bookworm"
                                      (updates debian/changelog)
```

> **Note:** For 7.2, templates are not used; the spec/control/rules files are maintained directly in `packaging/7.2/`.

### Doc Version Derivation

The doc version zeroes out the patch component:

```
version      → doc_version
─────────      ───────────
10.0.1       → 10.0.0
9.1.0        → 9.1.0
9.0.3        → 9.0.0
8.1.6        → 8.1.0
8.0.2        → 8.0.0
7.2.12       → 7.2.0
```

Calculated via:
```bash
DOC_VERSION=$(echo "${VERSION}" | sed "s/\.[0-9]*$/.0/")
```

### Packaging Directory Selection

```
version=10.0.1 →  MAJOR=10, MINOR=0  →  packaging/10.0/  (requires setup — see below)
version=9.1.0  →  MAJOR=9,  MINOR=1  →  packaging/9.1/   (requires setup — see below)
version=9.0.3  →  MAJOR=9,  MINOR=0  →  packaging/9.0/
version=8.1.6  →  MAJOR=8,  MINOR=1  →  packaging/8.1/
version=7.2.12 →  MAJOR=7,  MINOR=2  →  packaging/7.2/
```

### Template System (8.1/9.0+)

The `packaging/templates/` directory contains parameterized versions of files that differ only in version-dependent values between versions. This eliminates near-duplicate maintenance.

**When to update templates vs version-specific files:**

| Change needed | Where to edit |
|---------------|---------------|
| New Obsoletes threshold, Replaces/Breaks version | `templates/debian/control.template` or `templates/rpm/valkey.spec.template` |
| New RPM changelog entry | `templates/rpm/changelog-N.M` |
| New patch for a specific version | `packaging/N.x/rpm/valkey-conf.patch` or `packaging/N.x/debian/patches/` |
| New DEB changelog entry | `packaging/N.M/debian/changelog` |
| Change to bundled dep logic | `scripts/generate-from-templates.sh` |

**Adding a new version (e.g., 9.1 or 10.0):**

1. Create `packaging/N.M/rpm/` with:
   - `valkey-conf.patch` — regenerated against the new source tree
2. Create `packaging/N.M/debian/` with:
   - `changelog` — initial DEB changelog entry
   - `patches/` — regenerated DEB patches against the new source tree
3. Create `packaging/templates/rpm/changelog-N.M` with the initial RPM changelog entry
4. If the bundled dependency changes (e.g., libvalkey → something new), update the logic in `generate-from-templates.sh`
5. The template system handles `control`, `rules`, and `valkey.spec` automatically — no need to create these files

**The generate script** (`scripts/generate-from-templates.sh`) accepts:
```
--type rpm|deb --version <VALKEY_VERSION> --templates-dir <path> --output-dir <path>
```

It derives `MAJOR_VERSION` and `DOC_VERSION` from the version string, selects the appropriate bundled dependency (hiredis for <9, libvalkey for >=9), and performs sed substitutions.

---

## Cross-Version Upgrade Relationships

Packages declare upgrade relationships so newer major versions cleanly replace older ones.

### Upgrade Path Diagram

```
    ┌───────────┐      ┌───────────┐      ┌───────────┐      ┌───────────┐
    │  Valkey    │      │  Valkey    │      │  Valkey    │      │  Valkey    │
    │  7.2      │─────►│  8.1      │─────►│  9.0      │─────►│  10.0     │
    │           │      │           │      │           │      │           │
    │ (base)    │      │ Obsoletes │      │ Obsoletes │      │ Obsoletes │
    │           │      │ valkey<8.0│      │ valkey<9.0│      │valkey<10.0│
    └───────────┘      └───────────┘      └───────────┘      └───────────┘
         │                                                         ▲
         └─────────────────────────────────────────────────────────┘
                          (also upgrades directly)
```

### RPM Relationships

Uses `Obsoletes:` to indicate that this package supersedes older versions:

| Version | Directive | Effect |
|---------|-----------|--------|
| 7.2 | *(none)* | Base version, no predecessors |
| 8.1 | `Obsoletes: valkey < 8.1` | Replaces 7.2 and 8.0 on upgrade |
| 9.0 | `Obsoletes: valkey < 9.0` | Replaces all earlier versions on upgrade |
| 9.1 | `Obsoletes: valkey < 9.1` | Replaces 9.0 and all earlier versions on upgrade |

Applied to all subpackages: `valkey`, `valkey-devel`, `valkey-compat-redis`, `valkey-compat-redis-devel`, `valkey-doc`.

### DEB Relationships

Uses `Replaces:` + `Breaks:` pair (the Debian standard for upgrade replacement):

| Version | Directives | Effect |
|---------|------------|--------|
| 7.2 | *(none)* | Base version |
| 8.1 | `Replaces: valkey-server (<< 8.1~)` | Can overwrite 7.2/8.0 files |
|     | `Breaks: valkey-server (<< 8.1~)` | Forces removal of 7.2/8.0 |
| 9.0 | `Replaces: valkey-server (<< 9.0~)` | Can overwrite all earlier files |
|     | `Breaks: valkey-server (<< 9.0~)` | Forces removal of all earlier |
| 9.1 | `Replaces: valkey-server (<< 9.1~)` | Can overwrite 9.0 and earlier files |
|     | `Breaks: valkey-server (<< 9.1~)` | Forces removal of 9.0 and earlier |

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
│ Difference       │ 7.2            │ 8.1            │ 9.0            │
├──────────────────┼────────────────┼────────────────┼────────────────┤
│ CC variable      │ REDIS_CC       │ SERVER_CC      │ SERVER_CC -I.  │
│ LD variable      │ REDIS_LD       │ SERVER_LD      │ SERVER_LD      │
│ Bundled lib      │ hiredis        │ hiredis        │ libvalkey      │
│                  │                │ (via template) │ (via template) │
│ dir ./ line      │ 507            │ ~631           │ ~706           │
│ debug.c params   │ (eip, uplevel) │ (eip, uplevel, │ (eip, uplevel, │
│                  │                │  process_id)   │  process_id)   │
│ valkey-doc avail │ No (none)      │ Yes (8.1.0+)  │ Yes (9.0.0+)  │
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
│ 7.2     │ No           │ No valkey-doc release exists for 7.2│
│         │              │ (earliest tag is 8.0.0). Build      │
│         │              │ skips docs gracefully. No valkey-doc │
│         │              │ DEB package produced.                │
├─────────┼──────────────┼─────────────────────────────────────┤
│ 8.1     │ Yes          │ Downloads valkey-doc-8.1.0.tar.gz   │
├─────────┼──────────────┼─────────────────────────────────────┤
│ 9.0     │ Yes          │ Downloads valkey-doc-9.0.0.tar.gz   │
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
Default (no profile)   →  attempts download; 7.2 handles failure gracefully
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
RPM:  15 platforms × 2 architectures = 30 builds
DEB:   5 platforms × 2 architectures = 10 builds
                                       ─────────
                              Total:   40 builds per version
```

---

## Package Hosting Architecture

Signed packages are hosted on **AWS S3** (public read), while install instructions and the GPG public key are served from **GitHub Pages**.

```
                    packages.yml
                         │
           ┌─────────────┴─────────────┐
           │                           │
    publish-to-s3                deploy-pages
           │                           │
           ▼                           ▼
    ┌─────────────┐             ┌──────────────┐
    │  S3 Bucket  │             │ GitHub Pages │
    │             │             │              │
    │ valkey-9.0/ │             │ index.html   │
    │  rpm/el9/   │             │ GPG-KEY.asc  │
    │  deb/...    │             └──────────────┘
    │ GPG-KEY.asc │
    └─────────────┘
         ▲
    dnf/apt/zypper
```

**GitHub Secrets required:**
- `GPG_PRIVATE_KEY` — GPG signing key
- `S3_BUCKET` — S3 bucket name
- `S3_REGION` — S3 bucket region
- `AWS_ACCESS_KEY_ID` — AWS access key for S3 uploads
- `AWS_SECRET_ACCESS_KEY` — AWS secret key for S3 uploads

**S3 bucket policy** (minimal public read):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::BUCKET_NAME/*"
  }]
}
```

No static website hosting is needed — S3 direct URLs work for `dnf`/`apt`/`zypper`.

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

## Scripts Reference

All scripts live in the `scripts/` directory. The core build and publishing scripts are described below.

### build-rpm.sh

**Purpose:** Builds RPM packages inside a Docker container for a single platform/architecture combination.

**Invoked by:** `packages.yml` → Docker container (`bash /scripts/build-rpm.sh`)

**Environment variables (required):**

| Variable | Example | Description |
|----------|---------|-------------|
| `VALKEY_VERSION` | `9.0.3` | Version to build |
| `PLATFORM_FAMILY` | `suse` or `rhel` | Determines package manager and build flags |
| `PLATFORM_ID` | `rocky9`, `fedora41` | Identifies the specific distro |
| `EPEL_PACKAGE` | `epel-release` or `none` | EPEL package to install (RHEL-based only) |
| `EXPECTED_ARCH` | `x86_64` | Architecture for validation |

**Docker volume mounts:**

| Mount | Container path | Description |
|-------|---------------|-------------|
| `scripts/` | `/scripts:ro` | Build scripts |
| `packaging/common/rpm/` | `/packaging-common:ro` | Shared RPM sources |
| `packaging/N.M/rpm/` | `/packaging-override:ro` | Version-specific overrides |
| `packaging/templates/rpm/` | `/packaging-templates:ro` | Templates (8.1/9.0+) |
| `output/` | `/output` | Built RPMs written here |

**Execution flow:**

```
1. Install build tools (rpm-build, gcc, make, jemalloc-devel, openssl-devel, etc.)
   └── SUSE: zypper    RHEL/Fedora: dnf/yum
2. Merge packaging layers: common/ → override/ → templates
3. Generate spec from template (8.1/9.0+, via generate-from-templates.sh)
4. Copy spec + source files to ~/rpmbuild/{SPECS,SOURCES}/
5. Override Version: and %global doc_version via sed
6. Download valkey-${VERSION}.tar.gz and valkey-doc-${DOC_VERSION}.tar.gz
7. rpmbuild -ba valkey.spec [--without docs if pandoc unavailable]
8. Copy RPMs to /output/
9. Sanity checks: rpm query, required binaries, architecture, size > 500KB
```

---

### build-deb.sh

**Purpose:** Builds DEB packages inside a Docker container for a single platform/architecture combination.

**Invoked by:** `packages.yml` → Docker container (`bash /scripts/build-deb.sh`)

**Environment variables (required):**

| Variable | Example | Description |
|----------|---------|-------------|
| `VALKEY_VERSION` | `9.0.3` | Version to build |
| `PLATFORM_ID` | `debian12`, `ubuntu2404` | Distro identifier |
| `PLATFORM_CODENAME` | `bookworm`, `noble` | Used in changelog and Release file |
| `EXPECTED_ARCH` | `amd64` | Architecture for validation |

**Docker volume mounts:**

| Mount | Container path | Description |
|-------|---------------|-------------|
| `scripts/` | `/scripts:ro` | Build scripts |
| `packaging/common/debian/` | `/packaging-common:ro` | Shared DEB files |
| `packaging/N.M/debian/` | `/packaging-override:ro` | Version-specific overrides |
| `packaging/templates/debian/` | `/packaging-templates:ro` | Templates (8.1/9.0+) |
| `output/` | `/output` | Built DEBs written here |

**Execution flow:**

```
1. Install build tools (build-essential, debhelper, devscripts, libssl-dev, etc.)
2. Merge packaging layers: common/ → override/ → templates
3. Generate control/rules from template (8.1/9.0+, via generate-from-templates.sh)
4. Download and extract valkey source tarball
5. Copy debian/ directory into source tree
6. Override VALKEY_DOC_VERSION via sed
7. Fix debhelper compat conflicts (remove debian/compat if debhelper-compat used)
8. Fix jemalloc on Ubuntu 22.04 (Jammy) if headers missing
9. Install build-deps with mk-build-deps
10. Update changelog: dch -v "${VERSION}-1.${CODENAME}" -D ${CODENAME}
11. dpkg-buildpackage -b -us -uc -a${ARCH}
12. Copy .deb, .ddeb, .buildinfo, .changes to /output/
13. Sanity checks: package discovery, architecture match
```

---

### generate-from-templates.sh

**Purpose:** Generates version-specific packaging files (`control`, `rules`, `valkey.spec`) from parameterized templates. Replaces `@@PLACEHOLDER@@` variables with values derived from the version string.

**Invoked by:** `build-rpm.sh` and `build-deb.sh` (inside Docker containers)

**Usage:**
```bash
generate-from-templates.sh --type rpm|deb --version <VERSION> \
  --templates-dir <path> --output-dir <path>
```

**Version derivation:**
```
Input: 9.0.3
  MAJOR_VERSION = 9
  MINOR = 0
  DOC_VERSION = 9.0.0
```

**Behavior by version:**

| Major version | Action |
|---------------|--------|
| < 8 (7.2) | Skips entirely — 7.2 uses files directly |
| >= 8, < 9 | Generates with `hiredis` as bundled dep |
| >= 9 | Generates with `libvalkey` as bundled dep |

**DEB processing:** Substitutes `@@MAJOR_VERSION@@` in `control.template` and `@@DOC_VERSION@@` in `rules.template`.

**RPM processing:** Substitutes all placeholders in `valkey.spec.template`, then uses `awk` to replace `@@CHANGELOG@@` with the contents of `changelog-N.M` (multi-line replacement).

---

### publish-to-s3.sh

**Purpose:** Signs packages, builds APT and YUM repositories, and uploads everything to an S3 bucket with public read access.

**Invoked by:** `packages.yml` → `publish-to-s3` job (runs on `ubuntu-latest`, not in Docker)

**Usage:**
```bash
publish-to-s3.sh <version> <gpg_fingerprint> <artifacts_dir> <s3_bucket> <s3_region>
```

**Arguments:**

| Argument | Example | Description |
|----------|---------|-------------|
| `version` | `9.0.3` | Valkey version (determines repo name `valkey-9`) |
| `gpg_fingerprint` | `ABC123...` | GPG key fingerprint for signing |
| `artifacts_dir` | `artifacts` | Directory with downloaded build artifacts |
| `s3_bucket` | `valkey-packages` | S3 bucket name |
| `s3_region` | `us-east-1` | S3 bucket region |

**Environment variables:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (from GitHub secrets)

**Execution flow:**

```
RPM Repositories:
  1. Import GPG key into RPM database (rpm --import)
  2. For each platform/arch artifact directory:
     a. Stage .rpm files to staging/valkey-N/rpm/<platform>/<arch>/
     b. Sign each .rpm with rpmsign (SHA-256 digest, required for gpgcheck=1)
     c. Create repo metadata with createrepo_c
     d. Sign repomd.xml with GPG detached signature

DEB Repositories:
  1. For each platform/arch artifact directory:
     a. Stage .deb files to staging/valkey-N/deb/<platform>/<arch>/
     b. Sign each .deb with debsigs (origin signature)
     c. Generate Packages index with dpkg-scanpackages
     d. Generate Release file with MD5, SHA1, SHA256 checksums
     e. Sign Release → Release.gpg (detached) + InRelease (clearsigned)

Upload:
  1. Export public GPG key as staging/GPG-KEY-valkey.asc
  2. aws s3 sync staging/ s3://<bucket>/ --acl public-read
```

**S3 bucket structure:**
```
s3://bucket/
├── GPG-KEY-valkey.asc
├── valkey-9.0/
│   ├── rpm/
│   │   ├── el9/x86_64/*.rpm + repodata/
│   │   └── ...
│   └── deb/
│       ├── debian12/amd64/*.deb + Packages + Release + InRelease
│       └── ...
└── valkey-8.1/
    └── ...
```

**Signing summary:**

| Package type | What is signed | Tool | Verification |
|-------------|----------------|------|-------------|
| RPM packages | Individual `.rpm` files | `rpmsign --addsign` | `rpm -K <package>.rpm` |
| RPM repo | `repomd.xml` | `gpg --detach-sign` | Automatic by `dnf`/`zypper` |
| DEB packages | Individual `.deb` files | `debsigs --sign=origin` | `debsigs --verify <package>.deb` |
| DEB repo | `Release` file | `gpg --detach-sign` + `gpg --clearsign` | Automatic by `apt` |

**Required tools (installed in packages.yml):** `createrepo-c`, `dpkg-dev`, `debsigs`, `gpg`, `rpm`, `awscli`

---

### publish-repos.sh

**Purpose:** Generates the GitHub Pages site with install instructions and GPG public key. Packages are hosted on S3; this script only builds the static site.

**Invoked by:** `packages.yml` → `deploy-pages` job (runs on `ubuntu-latest`)

**Usage:**
```bash
publish-repos.sh <version> <gpg_fingerprint> <repo_url> <pages_url> <site_dir> <template_dir>
```

**Arguments:**

| Argument | Example | Description |
|----------|---------|-------------|
| `version` | `9.0.3` | Valkey version (determines version list) |
| `gpg_fingerprint` | `ABC123...` | GPG key fingerprint for exporting public key |
| `repo_url` | `https://bucket.s3.region.amazonaws.com` | S3 base URL for package repos |
| `pages_url` | `https://owner.github.io/repo` | GitHub Pages URL |
| `site_dir` | `site` | Output directory for the Pages site |
| `template_dir` | `scripts/pages` | Directory containing `index.html` template |

**Execution flow:**

```
Site Generation:
  1. Scan site/ for available version directories (valkey-7, valkey-9, etc.)
  2. Copy index.html template, substitute %%PAGES_URL%%, %%REPO_URL%%, and %%VERSIONS%%
  3. Export public GPG key as GPG-KEY-valkey.asc
  4. Create .nojekyll marker
```

**Required tools:** `gpg`

---

### test_packages.sh

**Purpose:** Automated test suite that installs built packages, validates installation, tests systemd services, and verifies clean removal. Runs inside Docker containers with systemd as PID 1.

**Invoked by:** `packages.yml` → `test-rpm` and `test-deb` jobs (Docker exec)

**Usage:**
```bash
test_packages.sh --pkg-dir=/path/to/packages [--version=X.Y.Z]
```

**Features:**
- Auto-detects OS family (DEB vs RPM) and package prefix (`valkey-*` or `percona-valkey-*`)
- Colored output with PASS/FAIL/SKIP indicators
- Reports summary with pass/fail/skip counts

**Test categories:**

| Test | What it validates |
|------|-------------------|
| `test_binaries` | All expected binaries exist and are executable (`valkey-server`, `valkey-cli`, etc.) |
| `test_user_group` | `valkey` user and group created correctly |
| `test_directories` | Data, log, and runtime directories exist with correct permissions |
| `test_config_files` | Configuration files installed at expected paths |
| `test_systemd_unit_files` | Service and target unit files installed |
| `test_systemd_service_hardening` | Security directives (ProtectSystem, NoNewPrivileges, etc.) |
| `test_systemd_enable_disable` | `systemctl enable/disable` works correctly |
| `test_systemd_start_stop_restart` | Service starts, stops, and restarts; PID file created |
| `test_systemd_runtime_environment` | Server responds to `PING`, correct version, TLS enabled |
| `test_systemd_restart_on_failure` | Service recovers after process kill |
| `test_systemd_targets` | `valkey.target` and `valkey-sentinel.target` work |
| `test_systemd_tmpfiles_sysctl` | tmpfiles.d and sysctl configurations applied |
| `test_valkey_server_service` | Full server lifecycle test |
| `test_valkey_sentinel_service` | Sentinel service lifecycle test |
| `test_compat_redis` | Redis compatibility symlinks (`redis-server` → `valkey-server`, etc.) |
| `test_dev_headers` | `valkeymodule.h` installed for module development |
| `test_logrotate` | Logrotate configuration installed |
| `test_clean_removal` | Package removal leaves no orphan files or broken services |

---

### setup-github-pages.sh

**Purpose:** One-time setup script that configures everything needed for GitHub Pages + S3 package repository deployment.

**Usage:**
```bash
./setup-github-pages.sh [--key-name "Name"] [--key-email "email@example.com"] \
  [--s3-bucket BUCKET] [--s3-region REGION] [--aws-key-id KEY_ID] [--aws-secret SECRET]
```

**Prerequisites:** `gh` CLI authenticated, `gpg` installed, run from inside the git repository.

**What it does (6 steps):**

```
Step 1: Generate GPG signing key
  └── RSA 4096-bit, 3-year expiry, no passphrase
      Default: "Valkey Package Signing Key" <packages@valkey.io>

Step 2: Store GPG private key as GitHub Actions secret
  └── gpg --export-secret-keys | gh secret set GPG_PRIVATE_KEY

Step 2b: Store S3 credentials as GitHub Actions secrets
  └── S3_BUCKET, S3_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
      (interactive prompts or --s3-bucket/--s3-region/--aws-key-id/--aws-secret flags)

Step 3: Enable workflow read/write permissions
  └── gh api repos/.../actions/permissions/workflow (default_workflow_permissions=write)

Step 4: Create gh-pages branch
  └── Orphan branch with .nojekyll marker, pushed to origin

Step 5: Configure GitHub Pages
  └── gh api repos/.../pages (source: gh-pages branch, legacy build)
```

**Idempotent:** Each step checks if already done (key exists, branch exists, Pages enabled) and skips if so.

---

### pages/index.html

**Purpose:** HTML template for the GitHub Pages landing page that provides package installation instructions for all supported platforms.

**Used by:** `publish-repos.sh` (copies to site directory, substitutes `%%PAGES_URL%%`, `%%REPO_URL%%`, and `%%VERSIONS%%`)

**Features:**
- Version selector dropdown (populated from `%%VERSIONS%%`)
- Platform auto-detection with manual override
- Tab-based instructions for RPM (RHEL/Fedora), SUSE, and DEB (Debian/Ubuntu)
- GPG key import and repository configuration commands
- Dynamically generates correct `baseurl`/`deb` lines based on selected version and platform

---

### test_in_docker.sh

**Purpose:** Convenience script for running `test_packages.sh` locally in Docker containers. Useful for testing packages without CI.

### build-packages.sh

**Purpose:** Legacy standalone build script (predates the `packages.yml` workflow). Builds RPM and DEB packages locally without GitHub Actions.

### Python Utility Scripts

| Script | Purpose |
|--------|---------|
| `automate_alias_update.py` | Updates version aliases in the valkey-hashes repository |
| `automate_website_description.py` | Updates release descriptions on the Valkey website |
| `extract_hashes_info.py` | Extracts SHA256 hash information for release artifacts |

---

