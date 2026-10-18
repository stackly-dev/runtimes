#!/bin/bash
# Builds one maintainer runtime artifact for Stackly on this Mac (spec 0003,
# AC-12, AC-17):
#
#   ./build.sh <provider> <version> <build>   writes out/<id>.tar.gz, .sha256, .log
#   ./build.sh --clean                        removes this user's build roots
#
# The script refuses a dirty checkout and a polluted /usr/local, snapshots the
# committed recipes into a fresh build root under /private/tmp/stackly-build/,
# and runs again from that snapshot under `/usr/bin/env -i`, so the build sees
# only the variables of the Environment build table in spec 0003.
set -euo pipefail
umask 022

usage() {
	printf 'usage: ./build.sh <provider> <version> <build>\n       ./build.sh --clean\n' >&2
	exit 2
}

# ---------------------------------------------------------------------------
# Outside env -i

outer_main() {
	local repo provider version build id head recipe sdk developer hex root
	repo=$(cd "$(/usr/bin/dirname "$0")" && pwd -P)
	# shellcheck source=lib/common.sh
	. "$repo/lib/common.sh"
	[ $# -eq 3 ] || usage
	provider=$1 version=$2 build=$3
	[[ $provider =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -f "$repo/recipes/$provider.sh" ] ||
		die "no recipe for provider '$provider' in recipes/"
	[[ $build =~ ^[1-9][0-9]*$ ]] || die "build must be a positive integer, found '$build'"

	# 1. A clean tree, before anything is downloaded.
	require_clean_tree "$repo" || exit 1
	head=$(/usr/bin/git -C "$repo" rev-parse HEAD)
	recipe=$STACKLY_RECIPE_REPO@$head:recipes/$provider.sh

	# 2. Nothing in /usr/local that clang or ld would pick up first.
	preflight_usr_local /usr/local || exit 1

	(
		# shellcheck disable=SC1090
		. "$repo/recipes/$provider.sh"
		recipe_source "$version"
	) || die "version $version is not pinned in recipes/$provider.sh"
	id=$provider-$version-r$build-macos-aarch64
	[ ! -e "$repo/out/$id.tar.gz" ] ||
		die "out/$id.tar.gz already exists; a new build of the same version takes the next build number"

	# 3. A fresh build root with a random name: PostgreSQL switches to a flat
	# layout when its prefix contains "postgres" or "pgsql".
	sdk=$(/usr/bin/xcrun --show-sdk-path)
	developer=$(/usr/bin/xcode-select -p)
	/bin/mkdir -p "$STACKLY_BUILD_PARENT"
	hex=$(/usr/bin/od -An -tx1 -N4 /dev/urandom | /usr/bin/tr -d ' \n')
	root=$STACKLY_BUILD_PARENT/$hex
	/bin/mkdir -m 0700 "$root"
	/bin/mkdir "$root/repo" "$root/home" "$root/tmp"
	/usr/bin/git -C "$repo" archive --format=tar "$head" | /usr/bin/tar -xf - -C "$root/repo"
	printf 'build root %s, recipe %s\n' "$root" "$recipe"

	exec /usr/bin/env -i \
		PATH="$root/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		HOME="$root/home" \
		TMPDIR="$root/tmp" \
		LANG=C \
		SDKROOT="$sdk" \
		DEVELOPER_DIR="$developer" \
		STACKLY_ORIGINAL_HOME="${HOME:?}" \
		STACKLY_RECIPE="$recipe" \
		STACKLY_BUILD_ROOT="$root" \
		STACKLY_BUILD_ARGS="$provider $version $build" \
		MACOSX_DEPLOYMENT_TARGET="$STACKLY_DEPLOYMENT_TARGET" \
		PKG_CONFIG_LIBDIR="$root/deps/lib/pkgconfig:$root/sdk-pkgconfig" \
		LDFLAGS="-Wl,-headerpad_max_install_names" \
		/bin/bash "$root/repo/build.sh" --inner "$repo"
}

clean_main() {
	# shellcheck source=lib/common.sh
	. "$(cd "$(/usr/bin/dirname "$0")" && pwd -P)/lib/common.sh"
	local dir
	[ -d "$STACKLY_BUILD_PARENT" ] || exit 0
	/usr/bin/find "$STACKLY_BUILD_PARENT" -mindepth 1 -maxdepth 1 -type d -user "$(/usr/bin/id -u)" |
		while IFS= read -r dir; do
			/bin/chmod -R u+w "$dir"
			/bin/rm -rf "$dir"
			printf 'removed %s\n' "$dir"
		done
}

# ---------------------------------------------------------------------------
# Inside env -i, running from the snapshot in the build root

step() {
	STEP=$*
	printf '\n==> %s [%s]\n' "$*" "$(/bin/date -u +%H:%M:%S)"
	printf '==> %s\n' "$*" >&3
}

on_exit() {
	local status=$1
	[ "$status" -eq 0 ] && return 0
	{
		printf '\nbuild failed during "%s" (exit %s); last lines of %s:\n' "$STEP" "$status" "$LOG"
		/usr/bin/tail -n 40 "$LOG"
		printf '\nThe build root %s is kept for inspection; ./build.sh --clean removes it.\n' "$ROOT"
	} >&4
}

# Loads recipes/deps/<name>.sh into the DEP_* variables and dep_build.
load_dependency() {
	unset DEP_NAME DEP_VERSION DEP_URL DEP_SHA256 DEP_LICENSE DEP_LICENSE_FILE DEP_SOURCE_DIR
	unset -f dep_build
	# shellcheck disable=SC1090
	. "$HERE/recipes/deps/$1.sh"
	[ "${DEP_NAME:-}" = "$1" ] || die "recipes/deps/$1.sh does not set DEP_NAME=$1"
}

dylib_names() {
	[ -d "$1" ] || return 0
	/usr/bin/find "$1" -maxdepth 1 -name '*.dylib' \( -type f -o -type l \) | /usr/bin/sed 's,.*/,,' | /usr/bin/sort
}

build_dependency() {
	local name=$1 file before
	load_dependency "$name"
	step "dependency $DEP_NAME $DEP_VERSION"
	file=$(fetch_source "$DEP_URL" "$DEP_SHA256" "$OUT/sources")
	extract_verified "$file" "$DEP_SHA256" "$ROOT/src" || die "cannot extract $DEP_NAME"
	before=$(dylib_names "$ROOT/deps/lib")
	(
		cd "$ROOT/src/$DEP_SOURCE_DIR"
		dep_build "$ROOT/deps"
	)
	# The dylib names (files and symlinks) this dependency installed.
	/usr/bin/comm -13 <(printf '%s\n' "$before") <(dylib_names "$ROOT/deps/lib") | /usr/bin/sed '/^$/d' >"$ROOT/deps-files/$DEP_NAME"
	[ -s "$ROOT/deps-files/$DEP_NAME" ] || die "$DEP_NAME installed no dylib"
	printf '%s installed: %s\n' "$DEP_NAME" "$(/usr/bin/tr '\n' ' ' <"$ROOT/deps-files/$DEP_NAME")"
}

# The manifest dependencies: one object per recipe dependency, with the dylibs
# it contributed to lib/. A dependency that contributed none fails the build.
dependencies_json() {
	local json='[]' name libs
	for name in $RECIPE_DEPS; do
		load_dependency "$name"
		libs=$(while IFS= read -r lib; do
			if [ -f "$PKG/lib/$lib" ]; then printf '%s\n' "$lib"; fi
		done <"$ROOT/deps-files/$name")
		[ -n "$libs" ] || die "no dylib of $name is loaded by the package"
		json=$(printf '%s\n' "$libs" | /usr/bin/jq -R . | /usr/bin/jq -s \
			--argjson acc "$json" --arg name "$DEP_NAME" --arg version "$DEP_VERSION" \
			--arg license "$DEP_LICENSE" --arg url "$DEP_URL" --arg sha256 "$DEP_SHA256" \
			'$acc + [{name: $name, version: $version, license: $license, sourceUrl: $url, sourceSha256: $sha256, libraries: .}]')
	done
	printf '%s\n' "$json"
}

vendored_json() {
	recipe_vendored | /usr/bin/jq -R -s \
		'split("\n") | map(select(length > 0) | split("|") | {name: .[0], license: .[1]})'
}

write_manifest() {
	local file=$1
	/usr/bin/jq -n \
		--arg provider "$PROVIDER" \
		--arg version "$VERSION" \
		--argjson build "$BUILD" \
		--arg url "$SOURCE_URL" \
		--arg sha256 "$SOURCE_SHA256" \
		--arg recipe "$STACKLY_RECIPE" \
		--arg xcode "$TC_XCODE" \
		--arg sdk "$TC_SDK" \
		--arg clang "$TC_CLANG" \
		--arg python "$TC_PYTHON" \
		--arg meson "$TC_MESON" \
		--arg ninja "$TC_NINJA" \
		--arg pkgconf "$TC_PKGCONF" \
		--arg bison "$TC_BISON" \
		--arg flex "$TC_FLEX" \
		--arg perl "$TC_PERL" \
		--arg make "$TC_MAKE" \
		--arg target "$STACKLY_DEPLOYMENT_TARGET" \
		--argjson dependencies "$(dependencies_json)" \
		--argjson vendored "$(vendored_json)" \
		--arg builtAt "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
			schema: "stackly.runtime-artifact/v1",
			provider: $provider,
			version: $version,
			build: $build,
			source: {url: $url, sha256: $sha256},
			recipe: $recipe,
			toolchain: {xcode: $xcode, sdk: $sdk, clang: $clang, python: $python, meson: $meson, ninja: $ninja, pkgconf: $pkgconf, bison: $bison, flex: $flex, perl: $perl, make: $make},
			deploymentTarget: $target,
			dependencies: $dependencies,
			vendored: $vendored,
			builtAt: $builtAt
		}' >"$file"
}

inner_main() {
	local repo=$1 file name license_dir copy
	HERE=$(cd "$(/usr/bin/dirname "$0")" && pwd -P)
	# shellcheck source=lib/common.sh
	. "$HERE/lib/common.sh"
	# bash exports these on its own; the build sees only the table.
	export -n PWD OLDPWD SHLVL
	check_build_env || exit 1
	ROOT=$STACKLY_BUILD_ROOT
	[ "$HERE" = "$ROOT/repo" ] || die "the inner build runs only from the snapshot in the build root"
	# shellcheck disable=SC2086
	set -- $STACKLY_BUILD_ARGS
	PROVIDER=$1 VERSION=$2 BUILD=$3
	ID=$PROVIDER-$VERSION-r$BUILD-macos-aarch64
	OUT=$repo/out
	LOG=$ROOT/build.log
	STEP=start
	JOBS=$(/usr/sbin/sysctl -n hw.ncpu)
	exec 3>&1 4>&2
	exec >>"$LOG" 2>&1
	trap 'on_exit $?' EXIT
	printf '==> building %s from %s\n' "$ID" "$STACKLY_RECIPE" >&3
	printf '==> log %s\n' "$LOG" >&3

	# 4. Environment, tools, and system .pc files.
	step "environment (exactly the Environment build table; bash adds _ per command)"
	/usr/bin/env | /usr/bin/grep -v '^_=' | /usr/bin/sort
	/bin/mkdir -p "$ROOT/src" "$ROOT/stage" "$ROOT/deps" "$ROOT/deps-files" "$ROOT/pkg"

	step "tools: venv of /usr/bin/python3 with the hashed requirements.txt"
	/usr/bin/python3 -m venv "$ROOT/venv"
	"$ROOT/venv/bin/python3" -m pip install --disable-pip-version-check --no-cache-dir \
		--require-hashes --only-binary :all: --no-deps -r "$HERE/requirements.txt"
	# Each tool must run and report the pinned version.
	TC_MESON=$(requirement_version meson "$HERE/requirements.txt")
	TC_NINJA=$(requirement_version ninja "$HERE/requirements.txt")
	TC_PKGCONF=$(requirement_version pkgconf "$HERE/requirements.txt")
	name=$(meson --version)
	[ "$name" = "$TC_MESON" ] || die "meson reports $name, not $TC_MESON"
	# The PyPI ninja reports 1.13.2.git.kitware.jobserver-pipe-1.
	name=$(ninja --version)
	case $name in
	"$TC_NINJA" | "$TC_NINJA".*) ;;
	*) die "ninja reports $name, not $TC_NINJA" ;;
	esac
	name=$(pkg-config --version)
	[ "$name" = "${TC_PKGCONF%%.post*}" ] || die "pkg-config reports $name, not ${TC_PKGCONF%%.post*}"
	name=$(pkgconf --version)
	[ "$name" = "${TC_PKGCONF%%.post*}" ] || die "pkgconf reports $name, not ${TC_PKGCONF%%.post*}"
	printf 'meson %s, ninja %s, pkgconf %s\n' "$TC_MESON" "$TC_NINJA" "$TC_PKGCONF"
	write_sdk_pc "$ROOT/sdk-pkgconfig" "$SDKROOT" || die "cannot write the SDK .pc files"
	/usr/bin/head -n 50 "$ROOT"/sdk-pkgconfig/*.pc

	step "toolchain"
	TC_XCODE=$(first_line /usr/bin/xcodebuild -version)
	TC_SDK=$(first_line /usr/bin/xcrun --show-sdk-version)
	TC_CLANG=$(first_line /usr/bin/clang --version)
	TC_PYTHON=$(first_line /usr/bin/python3 --version)
	TC_BISON=$(first_line /usr/bin/bison --version)
	TC_FLEX=$(first_line /usr/bin/flex --version)
	TC_PERL=$(/usr/bin/perl -e 'print $^V')
	TC_MAKE=$(first_line /usr/bin/make --version)
	printf '%s\n' "$TC_XCODE" "SDK $TC_SDK" "$TC_CLANG" "$TC_PYTHON" "meson $TC_MESON" "ninja $TC_NINJA" \
		"pkgconf $TC_PKGCONF" "$TC_BISON" "$TC_FLEX" "perl $TC_PERL" "$TC_MAKE"

	# shellcheck disable=SC1090
	. "$HERE/recipes/$PROVIDER.sh"
	recipe_source "$VERSION" || die "version $VERSION is not pinned in recipes/$PROVIDER.sh"

	# 5 and 6. Sources (sha256 checked before extraction), dependencies, and
	# the provider into the staging prefix.
	for name in $RECIPE_DEPS; do
		build_dependency "$name"
	done

	step "source $PROVIDER $VERSION"
	file=$(fetch_source "$SOURCE_URL" "$SOURCE_SHA256" "$OUT/sources")
	extract_verified "$file" "$SOURCE_SHA256" "$ROOT/src" || die "cannot extract the $PROVIDER source"

	step "build $PROVIDER $VERSION"
	(
		cd "$ROOT/src/$SOURCE_DIR"
		recipe_build "$ROOT/stage" "$VERSION"
	)

	# The step title must not contain the path it scans for: it is in the log.
	step "scan the configure logs and the build log for Homebrew paths"
	scan_config_logs "$ROOT/src" "$LOG" || die "the build saw /opt/homebrew"

	# 7 and 8. Package folder, relocation, signing, audit, manifest, scans.
	step "package folder"
	PKG=$ROOT/pkg/$ID
	/bin/mkdir -p "$PKG"
	(
		recipe_package "$ROOT/stage" "$PKG"
	)
	if [ -n "$RECIPE_DEPS" ]; then
		bundle_dependencies "$PKG" "$ROOT/deps" || die "cannot bundle the dependencies"
	fi
	license_dir=$PKG/LICENSES
	/bin/mkdir -p "$license_dir"
	/bin/cp "$ROOT/src/$SOURCE_DIR/$RECIPE_LICENSE_FILE" "$license_dir/$PROVIDER.txt"
	for name in $RECIPE_DEPS; do
		load_dependency "$name"
		/bin/cp "$ROOT/src/$DEP_SOURCE_DIR/$DEP_LICENSE_FILE" "$license_dir/$DEP_NAME.txt"
	done
	recipe_vendored_licenses "$ROOT/src/$SOURCE_DIR" "$license_dir"
	for name in $(recipe_vendored | /usr/bin/sed 's/|.*//'); do
		[ -s "$license_dir/$name.txt" ] || die "LICENSES/$name.txt is missing or empty"
	done
	/bin/chmod -R u+w,go-w "$PKG"

	step "relocate and sign"
	relocate "$PKG" "$ROOT" || die "relocation failed"

	step "audit"
	audit_macho "$PKG" || die "the audit failed"
	check_tree "$PKG" || die "the package is not only regular files and folders"
	list_macho "$PKG" | while IFS= read -r file; do
		printf '%s\n' "${file#"$PKG"/}"
		macho_deps "$file" | /usr/bin/sed 's/^/    /'
		macho_rpaths "$file" | /usr/bin/sed 's/^/    rpath /'
	done

	step "manifest"
	write_manifest "$PKG/STACKLY-ARTIFACT.json"
	/bin/cat "$PKG/STACKLY-ARTIFACT.json"

	step "scan the package for the home path"
	scan_home "$PKG" "$STACKLY_ORIGINAL_HOME" || die "the package contains the home path"

	step "pack"
	pack "$ROOT/pkg" "$ID" "$ROOT/$ID.tar.gz"
	write_sha256_file "$ROOT/$ID.tar.gz"
	/bin/cat "$ROOT/$ID.tar.gz.sha256"

	# 9. Version check from a copy in a path with a space and a non ASCII
	# character.
	step "version check from a copy of the package"
	copy="$ROOT/check Stackly Ü"
	/bin/mkdir "$copy"
	/usr/bin/tar -xzf "$ROOT/$ID.tar.gz" -C "$copy"
	# shellcheck disable=SC2086
	check_versions "$copy/$ID" "$VERSION" $RECIPE_EXECUTABLES || die "the version check failed"
	if declare -F recipe_check_copy >/dev/null; then
		recipe_check_copy "$copy/$ID" || die "the copy check failed"
	fi

	# 10. Results to out/, then the build root goes away.
	step "results"
	/bin/mkdir -p "$OUT"
	/bin/cp "$ROOT/$ID.tar.gz" "$ROOT/$ID.tar.gz.sha256" "$OUT/"
	(cd "$OUT" && /usr/bin/shasum -a 256 -c "$ID.tar.gz.sha256")
	printf 'built %s (%s bytes) from %s\n' "$ID" "$(/usr/bin/stat -f %z "$OUT/$ID.tar.gz")" "$STACKLY_RECIPE"
	/bin/cp "$LOG" "$OUT/$ID.log"
	exec >&3 2>&4
	/bin/chmod -R u+w "$ROOT"
	/bin/rm -rf "$ROOT"
	printf '==> out/%s.tar.gz\n' "$ID"
	/bin/cat "$OUT/$ID.tar.gz.sha256"
}

case ${1:-} in
--inner)
	[ $# -eq 2 ] || usage
	inner_main "$2"
	;;
--clean)
	[ $# -eq 1 ] || usage
	clean_main
	;;
-* | "") usage ;;
*) outer_main "$@" ;;
esac
