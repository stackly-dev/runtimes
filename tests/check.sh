#!/bin/bash
# Passing and failing fixtures for every check in lib/common.sh (spec 0003,
# Critical test scenarios, Build maintainer). Runs under a clean environment
# with only the system PATH, so no Homebrew tool stands in for a system one.
#
#   tests/check.sh
set -euo pipefail

if [ "${1:-}" != --clean-env ]; then
	exec /usr/bin/env -i \
		PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		LANG=C \
		TMPDIR="${TMPDIR:-/tmp}" \
		DEVELOPER_DIR="$(/usr/bin/xcode-select -p)" \
		/bin/bash "$0" --clean-env
fi

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"

WORK=$(cd "$(mktemp -d "$TMPDIR/stackly-runtimes-check.XXXXXX")" && pwd -P)
trap '/bin/chmod -R u+w "$WORK"; /bin/rm -rf "$WORK"' EXIT
export HOME=$WORK/home GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

PASSED=0
FAILED=0

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok - %s\n' "$1"
}

not_ok() {
	FAILED=$((FAILED + 1))
	printf 'not ok - %s\n' "$1"
	if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/    /'; fi
}

# expect_pass <name> <command...>
expect_pass() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then ok "$name"; else not_ok "$name" "$out"; fi
}

# expect_fail <name> <text the output must contain> <command...>
expect_fail() {
	local name=$1 text=$2 out
	shift 2
	if out=$("$@" 2>&1); then
		not_ok "$name (it passed)" "$out"
	elif [[ $out == *"$text"* ]]; then
		ok "$name"
	else
		not_ok "$name (no \"$text\" in the output)" "$out"
	fi
}

# expect_equal <name> <expected> <actual>
expect_equal() {
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$2], found [$3]"; fi
}

# ---------------------------------------------------------------------------
# require_clean_tree

git_repo=$WORK/git
mkdir -p "$git_repo"
git -C "$git_repo" init -q
printf 'out/\n' >"$git_repo/.gitignore"
printf 'a\n' >"$git_repo/file"
git -C "$git_repo" add .gitignore file
git -C "$git_repo" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false commit -q -m init
expect_pass "clean tree: a committed checkout passes" require_clean_tree "$git_repo"
mkdir -p "$git_repo/out"
printf 'x\n' >"$git_repo/out/artifact"
expect_pass "clean tree: ignored files pass" require_clean_tree "$git_repo"
printf 'b\n' >>"$git_repo/file"
expect_fail "clean tree: a modified file fails" "stackly-runtimes has uncommitted changes" require_clean_tree "$git_repo"
git -C "$git_repo" checkout -q -- file
printf 'new\n' >"$git_repo/untracked"
expect_fail "clean tree: an untracked file fails" "stackly-runtimes has uncommitted changes" require_clean_tree "$git_repo"

# ---------------------------------------------------------------------------
# preflight_usr_local

usr=$WORK/usr-node
mkdir -p "$usr/include/node" "$usr/lib/node_modules"
expect_pass "preflight: only include/node/ and lib/node_modules/ pass" preflight_usr_local "$usr"
expect_pass "preflight: a missing folder passes" preflight_usr_local "$WORK/usr-missing"
usr=$WORK/usr-iconv
mkdir -p "$usr/include/node"
touch "$usr/include/iconv.h"
expect_fail "preflight: include/iconv.h fails" "$usr/include/iconv.h" preflight_usr_local "$usr"
usr=$WORK/usr-openssl
mkdir -p "$usr/include/openssl"
expect_fail "preflight: include/openssl/ fails" "$usr/include/openssl/" preflight_usr_local "$usr"
usr=$WORK/usr-libz
mkdir -p "$usr/lib/node_modules"
touch "$usr/lib/libz.dylib"
expect_fail "preflight: lib/libz.dylib fails" "$usr/lib/libz.dylib" preflight_usr_local "$usr"
usr=$WORK/usr-static
mkdir -p "$usr/lib"
touch "$usr/lib/libssl.a" "$usr/lib/libedit.tbd"
expect_fail "preflight: lib/libssl.a fails" "$usr/lib/libssl.a" preflight_usr_local "$usr"
expect_fail "preflight: lib/libedit.tbd fails" "$usr/lib/libedit.tbd" preflight_usr_local "$usr"

# ---------------------------------------------------------------------------
# check_build_env

env_args=()
for name in $STACKLY_BUILD_ENV_NAMES; do
	case $name in
	PATH) env_args+=("PATH=$WORK/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin") ;;
	*) env_args+=("$name=value") ;;
	esac
done
run_env_check() {
	/usr/bin/env -i "$@" /bin/bash -c '. "$0"; export -n PWD OLDPWD SHLVL; check_build_env' "$REPO/lib/common.sh"
}
expect_pass "build env: exactly the table passes" run_env_check "${env_args[@]}"
expect_fail "build env: an extra CPATH fails" "CPATH" run_env_check "${env_args[@]}" CPATH=/opt/homebrew/include
# SIP strips DYLD_* before /bin/bash starts, so the variable is exported from
# inside the shell, as a build step could.
expect_fail "build env: an exported DYLD_ variable fails" "DYLD_LIBRARY_PATH" \
	/usr/bin/env -i "${env_args[@]}" /bin/bash -c '. "$0"; export -n PWD OLDPWD SHLVL; export DYLD_LIBRARY_PATH=/x; check_build_env' "$REPO/lib/common.sh"
homebrew_args=()
for arg in "${env_args[@]}"; do
	case $arg in
	PATH=*) homebrew_args+=("PATH=/opt/homebrew/bin:/usr/bin:/bin") ;;
	*) homebrew_args+=("$arg") ;;
	esac
done
expect_fail "build env: Homebrew in PATH fails" "PATH reaches Homebrew" run_env_check "${homebrew_args[@]}"

# ---------------------------------------------------------------------------
# verify_sha256, extract_verified, fetch_source

mkdir -p "$WORK/tarball/source-1.0"
printf 'hello\n' >"$WORK/tarball/source-1.0/README"
tar -czf "$WORK/source-1.0.tar.gz" -C "$WORK/tarball" source-1.0
good=$(sha256_of "$WORK/source-1.0.tar.gz")
bad=0000000000000000000000000000000000000000000000000000000000000000
expect_pass "sha256: the pinned digest passes" verify_sha256 "$WORK/source-1.0.tar.gz" "$good"
expect_fail "sha256: another digest fails" "sha256 mismatch" verify_sha256 "$WORK/source-1.0.tar.gz" "$bad"
expect_fail "extract: a digest mismatch fails" "sha256 mismatch" extract_verified "$WORK/source-1.0.tar.gz" "$bad" "$WORK/extract-bad"
if [ -e "$WORK/extract-bad/source-1.0" ]; then
	not_ok "extract: nothing is extracted after a digest mismatch"
else
	ok "extract: nothing is extracted after a digest mismatch"
fi
expect_pass "extract: the pinned digest extracts" extract_verified "$WORK/source-1.0.tar.gz" "$good" "$WORK/extract-good"
expect_equal "extract: the file is there" "hello" "$(cat "$WORK/extract-good/source-1.0/README" 2>/dev/null)"
expect_fail "fetch: a non https URL fails" "not https" fetch_source "http://example.invalid/x.tar.gz" "$good" "$WORK/cache"
mkdir -p "$WORK/cache"
cp "$WORK/source-1.0.tar.gz" "$WORK/cache/$good"
expect_equal "fetch: a cached file with the pinned digest is used" "$WORK/cache/$good" \
	"$(fetch_source "https://example.invalid/source-1.0.tar.gz" "$good" "$WORK/cache" 2>/dev/null)"

# ---------------------------------------------------------------------------
# scan_config_logs

logs=$WORK/logs-clean
mkdir -p "$logs/build/meson-logs" "$logs/icu"
printf 'Program python3 found: YES (%s/venv/bin/python3)\n' "$WORK" >"$logs/build/meson-logs/meson-log.txt"
printf 'configure: checking for gcc... clang\n' >"$logs/icu/config.log"
printf 'make all\n' >"$WORK/build-clean.log"
expect_pass "log scan: clean configure logs pass" scan_config_logs "$logs" "$WORK/build-clean.log"
logs=$WORK/logs-meson
mkdir -p "$logs/build/meson-logs"
printf 'Run-time dependency openssl found: YES 3.6.0 (/opt/homebrew/opt/openssl@3/lib/pkgconfig)\n' >"$logs/build/meson-logs/meson-log.txt"
expect_fail "log scan: /opt/homebrew in meson-log.txt fails" "meson-log.txt" scan_config_logs "$logs"
logs=$WORK/logs-config
mkdir -p "$logs/icu"
printf 'CPPFLAGS=-I/opt/homebrew/include\n' >"$logs/icu/config.log"
expect_fail "log scan: /opt/homebrew in config.log fails" "config.log" scan_config_logs "$logs"
printf 'cc -I/opt/homebrew/include -c x.c\n' >"$WORK/build-homebrew.log"
expect_fail "log scan: /opt/homebrew in the build log fails" "build-homebrew.log" scan_config_logs "$WORK/logs-clean" "$WORK/build-homebrew.log"

# ---------------------------------------------------------------------------
# scan_home

fake_home=/Users/stackly-check-user
pkg=$WORK/home-clean
mkdir -p "$pkg/share"
printf 'prefix=/private/tmp/stackly-build/0123abcd/stage\n' >"$pkg/share/a.txt"
expect_pass "home scan: a package without the home path passes" scan_home "$pkg" "$fake_home"
pkg=$WORK/home-text
mkdir -p "$pkg/share"
printf 'source %s/src/x.c\n' "$fake_home" >"$pkg/share/a.txt"
expect_fail "home scan: a text file with the home path fails" "share/a.txt" scan_home "$pkg" "$fake_home"
pkg=$WORK/home-binary
mkdir -p "$pkg/lib"
printf '\000\001%s/build\000' "$fake_home" >"$pkg/lib/libx.dylib"
expect_fail "home scan: a binary file with the home path fails" "lib/libx.dylib" scan_home "$pkg" "$fake_home"
expect_fail "home scan: an empty home path is refused" "not absolute" scan_home "$WORK/home-clean" ""

# ---------------------------------------------------------------------------
# check_tree

pkg=$WORK/tree-clean
mkdir -p "$pkg/bin"
printf '#!/bin/sh\n' >"$pkg/bin/tool"
chmod 0755 "$pkg/bin/tool"
expect_pass "tree: regular files and folders pass" check_tree "$pkg"
pkg=$WORK/tree-link
mkdir -p "$pkg/lib"
touch "$pkg/lib/libx.1.dylib"
ln -s libx.1.dylib "$pkg/lib/libx.dylib"
expect_fail "tree: a symlink fails" "lib/libx.dylib" check_tree "$pkg"
pkg=$WORK/tree-setuid
mkdir -p "$pkg/bin"
touch "$pkg/bin/tool"
chmod 4755 "$pkg/bin/tool"
expect_fail "tree: a setuid file fails" "bin/tool" check_tree "$pkg"

# ---------------------------------------------------------------------------
# Mach-O fixtures: audit_macho, loader_rpath, relocate, check_versions

src=$WORK/c
mkdir -p "$src"
printf 'int foo(void) { return 7; }\n' >"$src/foo.c"
cat >"$src/main.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(void);
int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		printf("fixture (Stackly) 1.2.3\n");
		return 0;
	}
	printf("fixture %d\n", foo());
	return 0;
}
EOF

pkg=$WORK/audit-good
mkdir -p "$pkg/bin" "$pkg/lib"
clang -dynamiclib -o "$pkg/lib/libfoo.dylib" -install_name @rpath/libfoo.dylib -Wl,-headerpad_max_install_names "$src/foo.c"
clang -o "$pkg/bin/main" "$src/main.c" -L"$pkg/lib" -lfoo -Wl,-rpath,@loader_path/../lib -Wl,-headerpad_max_install_names
expect_pass "audit: @rpath libraries inside the package pass" audit_macho "$pkg"
expect_equal "audit: the fixture runs" "fixture 7" "$("$pkg/bin/main")"

cp -R "$pkg" "$WORK/audit-homebrew"
install_name_tool -change @rpath/libfoo.dylib /opt/homebrew/lib/libfoo.dylib "$WORK/audit-homebrew/bin/main" 2>/dev/null
expect_fail "audit: a reference to /opt/homebrew/lib/libfoo.dylib fails" "bin/main: references /opt/homebrew/lib/libfoo.dylib" audit_macho "$WORK/audit-homebrew"

cp -R "$pkg" "$WORK/audit-rpath"
install_name_tool -add_rpath /opt/homebrew/lib "$WORK/audit-rpath/bin/main" 2>/dev/null
expect_fail "audit: an absolute LC_RPATH fails" "bin/main: LC_RPATH /opt/homebrew/lib is absolute" audit_macho "$WORK/audit-rpath"

cp -R "$pkg" "$WORK/audit-missing"
rm "$WORK/audit-missing/lib/libfoo.dylib"
expect_fail "audit: an @rpath library missing from the package fails" "@rpath/libfoo.dylib does not resolve" audit_macho "$WORK/audit-missing"

expect_equal "rpath: bin/ points to ../lib" "@loader_path/../lib" "$(loader_rpath /p /p/bin/x)"
expect_equal "rpath: lib/ points to itself" "@loader_path" "$(loader_rpath /p /p/lib/libx.dylib)"
expect_equal "rpath: lib/postgresql/ points to .." "@loader_path/.." "$(loader_rpath /p /p/lib/postgresql/x.dylib)"
expect_equal "rpath: a nested folder climbs to lib/" "@loader_path/../../lib" "$(loader_rpath /p /p/libexec/a/x)"

# A staging prefix like the real build: absolute install names into the build
# root, a versioned dylib behind two symlinks, and an absolute rpath.
build=$WORK/reloc
stage=$build/stage
mkdir -p "$stage/lib" "$stage/bin"
clang -dynamiclib -o "$stage/lib/libfoo.1.0.dylib" -install_name "$stage/lib/libfoo.1.dylib" -Wl,-headerpad_max_install_names "$src/foo.c"
ln -s libfoo.1.0.dylib "$stage/lib/libfoo.1.dylib"
ln -s libfoo.1.0.dylib "$stage/lib/libfoo.dylib"
clang -o "$stage/bin/main" "$src/main.c" -L"$stage/lib" -lfoo -Wl,-rpath,"$stage/lib" -Wl,-headerpad_max_install_names
pkg=$build/pkg/fixture
mkdir -p "$pkg"
cp -R "$stage/bin" "$stage/lib" "$pkg/"
expect_fail "audit: the unrelocated package fails" "references $stage/lib/libfoo.1.dylib" audit_macho "$pkg"
expect_pass "relocate: the staging package relocates" relocate "$pkg" "$build"
expect_equal "relocate: no symlink is left" "" "$(find "$pkg" -type l)"
expect_equal "relocate: the dylib keeps the name in its install name" "libfoo.1.dylib" "$(ls "$pkg/lib")"
expect_equal "relocate: the install name is @rpath" "@rpath/libfoo.1.dylib" "$(macho_id "$pkg/lib/libfoo.1.dylib")"
expect_equal "relocate: the executable loads @rpath" "@rpath/libfoo.1.dylib" "$(macho_deps "$pkg/bin/main" | grep libfoo)"
expect_equal "relocate: one @loader_path rpath" "@loader_path/../lib" "$(macho_rpaths "$pkg/bin/main")"
expect_pass "relocate: the signature verifies" codesign --verify --strict "$pkg/bin/main"
expect_pass "audit: the relocated package passes" audit_macho "$pkg"
copy="$WORK/copy Stackly Ü"
mkdir -p "$copy"
cp -R "$pkg" "$copy/"
rm -rf "$stage"
expect_equal "relocate: the copy runs from a path with a space and Ü" "fixture 7" "$("$copy/fixture/bin/main")"
expect_pass "versions: the copy prints its version" check_versions "$copy/fixture" 1.2.3 bin/main
expect_fail "versions: another version fails" "does not print 9.9.9" check_versions "$copy/fixture" 9.9.9 bin/main
expect_fail "versions: a missing executable fails" "bin/missing --version failed" check_versions "$copy/fixture" 1.2.3 bin/missing

# bundle_dependencies copies the real file under the name it is loaded by.
deps=$WORK/bundle/deps
mkdir -p "$deps/lib"
clang -dynamiclib -o "$deps/lib/libfoo.2.5.dylib" -install_name "$deps/lib/libfoo.2.dylib" "$src/foo.c"
ln -s libfoo.2.5.dylib "$deps/lib/libfoo.2.dylib"
ln -s libfoo.2.5.dylib "$deps/lib/libfoo.dylib"
pkg=$WORK/bundle/pkg
mkdir -p "$pkg/bin"
clang -o "$pkg/bin/main" "$src/main.c" -L"$deps/lib" -lfoo -Wl,-headerpad_max_install_names
expect_pass "bundle: a loaded dependency is copied" bundle_dependencies "$pkg" "$deps"
if [ -f "$pkg/lib/libfoo.2.dylib" ] && [ ! -L "$pkg/lib/libfoo.2.dylib" ]; then
	ok "bundle: the copy is a regular file under the loaded name"
else
	not_ok "bundle: the copy is a regular file under the loaded name" "$(ls -l "$pkg/lib" 2>&1)"
fi

# ---------------------------------------------------------------------------
# check_notices, write_provider_license

notice=$WORK/notice-src
mkdir -p "$notice/src/sub"
printf 'Example License\n\nCopyright (c) 2026, Example contributors.\n' >"$notice/COPYING"
cat >"$notice/src/adler.c" <<'EOF'
/* crcspeed.c -- incremental CRC
 *
 * Copyright (C) 2013 Mark Adler
 *
 * This software is provided 'as-is', without any express or implied warranty.
 */
int adler(void) { return 0; }
/* Copyright (C) 2099 A later comment that is not the first block */
EOF
cat >"$notice/src/own.c" <<'EOF'
#include <stdio.h>
/*
 * Copyright (c) 2024-present, Example contributors.
 * Copyright (c) 2009-2012, Example Ltd.
 *
 * Redistributions of source code must retain the above copyright notice.
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS".
 */
int own(void) { return 0; }
EOF
cat >"$notice/src/sub/nextline.h" <<'EOF'
/*-
 * Copyright (c) 1990, 1993
 *	Example Ltd and others.
 */
EOF
cat >"$notice/src/sub/slashes.c" <<'EOF'
// Copyright 2018 Ulf Adams
//
// Boost Software License 1.0.
int slashes;
EOF
printf 'int plain;\n' >"$notice/src/plain.c"
printf 'Copyright (C) 2013 Mark Adler in a text file\n' >"$notice/src/notes.txt"
owners="Example contributors|Example Ltd"
listed="src/adler.c
src/sub/nextline.h
src/sub/slashes.c"
expect_fail "notices: an unlisted Mark Adler header fails" \
	"src/adler.c has a third party copyright notice that the recipe does not list" \
	check_notices "$notice" "$owners" "src/sub/nextline.h
src/sub/slashes.c" src
expect_pass "notices: files naming only provider owners pass when the others are listed" \
	check_notices "$notice" "$owners" "$listed" src
expect_fail "notices: a listed file missing from the source fails" \
	"src/gone.c is listed as a notice file but is not in the source" \
	check_notices "$notice" "$owners" "$listed
src/gone.c" src
expect_fail "notices: an owner on the line after Copyright counts as third party" \
	"src/sub/nextline.h has a third party copyright notice" \
	check_notices "$notice" "$owners" "src/adler.c
src/sub/slashes.c" src
expect_fail "notices: a // comment block is scanned too" \
	"src/sub/slashes.c has a third party copyright notice" \
	check_notices "$notice" "$owners" "src/adler.c
src/sub/nextline.h" src
expect_equal "notices: the scan lists exactly the third party files" "$listed" \
	"$(third_party_files "$notice" "$owners" src)"
expect_fail "notices: a missing scan folder fails" "contrib is not in the source" \
	check_notices "$notice" "$owners" "$listed" src contrib
write_provider_license "$notice" COPYING "$listed" "$WORK/provider.txt"
expect_equal "license: the main license text comes first" "Example License" "$(head -n 1 "$WORK/provider.txt")"
after=$(sed -n '/^Third party notices$/,$p' "$WORK/provider.txt")
if [[ $after == *"src/adler.c"*"Copyright (C) 2013 Mark Adler"*"src/sub/nextline.h"*"Copyright 2018 Ulf Adams"* ]]; then
	ok "license: each listed file's block follows Third party notices"
else
	not_ok "license: each listed file's block follows Third party notices" "$(cat "$WORK/provider.txt")"
fi
if [[ $after == *"2099"* ]]; then
	not_ok "license: only the first comment block is copied" "$after"
else
	ok "license: only the first comment block is copied"
fi
write_provider_license "$notice" COPYING "" "$WORK/provider-plain.txt"
expect_equal "license: no list means the main license text alone" "$(cat "$notice/COPYING")" "$(cat "$WORK/provider-plain.txt")"

# ---------------------------------------------------------------------------
# write_sdk_pc, write_sha256_file, requirement_version

sdk=$(xcrun --show-sdk-path)
expect_pass "sdk pc: the four files are written" write_sdk_pc "$WORK/sdk-pc" "$sdk"
expect_equal "sdk pc: libxml-2.0 points into the SDK" "Cflags: -I$sdk/usr/include/libxml2" "$(grep '^Cflags' "$WORK/sdk-pc/libxml-2.0.pc" 2>/dev/null)"
expect_equal "sdk pc: uuid has no Libs" "" "$(grep '^Libs' "$WORK/sdk-pc/uuid.pc" 2>/dev/null || true)"
if grep -q '^Version: [0-9]' "$WORK/sdk-pc/zlib.pc" 2>/dev/null; then ok "sdk pc: zlib has the SDK version"; else not_ok "sdk pc: zlib has the SDK version"; fi
write_sha256_file "$WORK/source-1.0.tar.gz"
expect_equal "sha256 file: one line with the file name" "$good  source-1.0.tar.gz" "$(cat "$WORK/source-1.0.tar.gz.sha256")"
expect_equal "requirements: meson is pinned" "1.11.2" "$(requirement_version meson "$REPO/requirements.txt")"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
