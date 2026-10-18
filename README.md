# stackly-runtimes

Build recipes for the runtime artifacts that [Stackly](https://github.com/ojiepermana/stackly)
cannot download from upstream: PostgreSQL 17 and 18 (with OpenSSL, ICU, lz4,
and zstd bundled) and Valkey. The decisions behind them are in spec 0003 of the
Stackly repository (`docs/specs/0003-sumber-packaging-runtime/`).

This repository holds recipes only. Artifacts are built by hand on the
maintainer's Mac and published on the GitHub Releases of `ojiepermana/stackly`
under the tag `runtime/<id>`, after a local spike passes and the release owner
approves the upload. Each artifact names the commit of the recipe it was built
from in `STACKLY-ARTIFACT.json`.

## Requirements

- macOS 27 on Apple silicon with Xcode 27 selected (`xcode-select -p`).
- `/usr/bin/python3` (Python 3.9.6 from Xcode); meson, ninja, and pkgconf
  (with importlib-metadata and zipp, which its wrapper needs on Python 3.9)
  are installed from `requirements.txt` into a venv of it, pinned by hash.
- bison, flex, perl, make, curl, tar, and jq from `/usr/bin`.
- Network access to the source sites and PyPI.
- Nothing in `/usr/local/include` or `/usr/local/lib` that clang or ld would
  pick up first (the build refuses to start otherwise). Homebrew may be
  installed: the build never sees it.

## Usage

```bash
./build.sh valkey 9.1.2 1
./build.sh postgresql 18.6 1
./build.sh postgresql 17.11 1
```

`./build.sh <provider> <version> <build>` writes `out/<id>.tar.gz`,
`out/<id>.tar.gz.sha256`, and `out/<id>.log`, where `<id>` is
`<provider>-<version>-r<build>-macos-aarch64`. A rebuild of a published
version takes the next build number; the script refuses to overwrite an
existing `out/<id>.tar.gz`. `./build.sh --clean` removes this user's build
roots under `/private/tmp/stackly-build/`, which a failed build leaves behind
for inspection.

`tests/check.sh` runs passing and failing fixtures for every check in
`lib/common.sh`.

## What a build does

1. Refuses a checkout with uncommitted changes (`stackly-runtimes has
   uncommitted changes`) and a `/usr/local` that holds top level headers,
   build header folders (`openssl`, `unicode`, `libxml`, `libxml2`,
   `editline`, `readline`, `uuid`), or `lib*.dylib`, `lib*.a`, or `lib*.tbd`.
2. Creates `/private/tmp/stackly-build/<8 random hex>/`, extracts the committed
   tree there with `git archive`, and runs that copy again under
   `/usr/bin/env -i` with only `PATH` (venv, `/usr/bin`, `/bin`, `/usr/sbin`,
   `/sbin`), `HOME`, `TMPDIR`, `LANG=C`, `SDKROOT`, `DEVELOPER_DIR`,
   `MACOSX_DEPLOYMENT_TARGET=27.0`, `PKG_CONFIG_LIBDIR`, `LDFLAGS`, and the
   `STACKLY_*` variables. The environment is logged and checked.
3. Downloads each source over https into `out/sources/<sha256>` and checks
   it against the sha256 pinned in the recipe before extracting it.
4. Builds the dependencies (PostgreSQL only) and the provider, then fails if
   `/opt/homebrew` appears in a configure log or the build log.
5. Assembles the package, relocates every Mach-O to `@rpath` and
   `@loader_path`, signs it ad hoc, and audits it: only `@rpath/`,
   `@loader_path/`, `@executable_path/`, `/usr/lib/`, and `/System/Library/`,
   no absolute `LC_RPATH`, only regular files and folders.
6. Writes `STACKLY-ARTIFACT.json`, fails if the builder's home path appears in
   any file of the package, packs the tarball, and runs every executable with
   `--version` from a copy in a path with a space and `Ü`.

## Layout

```text
build.sh                 ./build.sh <provider> <version> <build>, ./build.sh --clean
lib/common.sh            environment, sources, SDK .pc files, relocation, signing, audit, scans, package
recipes/<provider>.sh    pinned sources and build steps of a provider
recipes/deps/<name>.sh   pinned sources and build steps of a bundled dependency
requirements.txt         meson, ninja, pkgconf, and the wheels pkgconf needs, with hashes
tests/check.sh           fixtures for the checks in lib/common.sh
```

Build logs stay in `out/` and are never published: they contain the path of
this checkout.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option. The software these recipes build
keeps its own license; each artifact carries the texts in `LICENSES/`.
