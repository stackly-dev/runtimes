# Shared functions for build.sh and tests/check.sh.
#
# Written for /bin/bash 3.2, the bash that ships with macOS: no associative
# arrays, no `mapfile`, and no "${array[@]}" on an empty array under `set -u`.
# Every check takes the paths it inspects as arguments, so tests/check.sh can
# run it against temporary folders.

STACKLY_DEPLOYMENT_TARGET=27.0
STACKLY_BUILD_PARENT=/private/tmp/stackly-build
STACKLY_RECIPE_REPO=ojiepermana/stackly-runtimes

# The variables the build may see after `env -i`, and nothing else (spec 0003,
# Environment build). bash itself adds `_` to the environment of every command.
STACKLY_BUILD_ENV_NAMES="DEVELOPER_DIR HOME LANG LDFLAGS MACOSX_DEPLOYMENT_TARGET PATH PKG_CONFIG_LIBDIR SDKROOT STACKLY_BUILD_ARGS STACKLY_BUILD_ROOT STACKLY_ORIGINAL_HOME STACKLY_RECIPE TMPDIR"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Prints an error and returns 1, for checks called in a condition.
complain() {
	printf 'error: %s\n' "$*" >&2
	return 1
}

# ---------------------------------------------------------------------------
# Checks before anything is downloaded (AC-17)

# Refuses a checkout with uncommitted changes or untracked files that are not
# ignored.
require_clean_tree() {
	local repo=$1 status
	status=$(/usr/bin/git -C "$repo" status --porcelain) ||
		complain "cannot read the git status of $repo" || return 1
	if [ -n "$status" ]; then
		printf '%s\n' "$status" >&2
		complain "stackly-runtimes has uncommitted changes"
		return 1
	fi
}

# clang always searches <root>/include and ld always searches <root>/lib
# before the SDK. Refuses any file at the top of include/ (a header such as
# iconv.h or zlib.h there overrides the SDK), the include folders the build
# uses, and any lib*.dylib, lib*.a, or lib*.tbd at the top of lib/. Other
# folders are only reachable through `#include <name/...>` and are left alone.
preflight_usr_local() {
	local root=$1 entry name found=""
	if [ -d "$root/include" ]; then
		while IFS= read -r entry; do
			[ -n "$entry" ] || continue
			name=${entry##*/}
			if [ -d "$entry" ]; then
				case $name in
				openssl | unicode | libxml | libxml2 | editline | readline | uuid)
					found="$found$entry/
"
					;;
				esac
			else
				found="$found$entry
"
			fi
		done <<EOF
$(/usr/bin/find "$root/include" -mindepth 1 -maxdepth 1 | /usr/bin/sort)
EOF
	fi
	if [ -d "$root/lib" ]; then
		while IFS= read -r entry; do
			[ -n "$entry" ] || continue
			[ -d "$entry" ] && continue
			found="$found$entry
"
		done <<EOF
$(/usr/bin/find "$root/lib" -mindepth 1 -maxdepth 1 \( -name 'lib*.dylib' -o -name 'lib*.a' -o -name 'lib*.tbd' \) | /usr/bin/sort)
EOF
	fi
	if [ -n "$found" ]; then
		printf '%s' "$found" >&2
		complain "$root holds headers or libraries that can override the build's own; move them away (the check is not loosened)"
		return 1
	fi
}

# After `env -i`: the environment holds exactly the build variables, PATH
# holds no Homebrew or /usr/local folder, and no DYLD_*, CPATH, LIBRARY_PATH,
# or PKG_CONFIG_PATH is set.
check_build_env() {
	local names expected
	# compgen -e, not /usr/bin/env: SIP hides DYLD_* from protected binaries
	# such as env, but not from the compilers and tools the build runs.
	names=$(compgen -e | /usr/bin/grep -vx '_' | /usr/bin/sort | /usr/bin/tr '\n' ' ')
	expected=$(printf '%s\n' $STACKLY_BUILD_ENV_NAMES | /usr/bin/sort | /usr/bin/tr '\n' ' ')
	if [ "$names" != "$expected" ]; then
		complain "the build environment is not clean: found [${names% }], expected [${expected% }]"
		return 1
	fi
	case ":$PATH:" in
	*/opt/homebrew* | *:/usr/local/*)
		complain "PATH reaches Homebrew or /usr/local: $PATH"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Sources

sha256_of() {
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

# Returns 0 when the file's sha256 equals the pinned value.
verify_sha256() {
	local file=$1 expected=$2 actual
	[ -f "$file" ] || complain "$file does not exist" || return 1
	actual=$(sha256_of "$file")
	if [ "$actual" != "$expected" ]; then
		complain "sha256 mismatch for $file: pinned $expected, found $actual"
		return 1
	fi
}

# Downloads <url> into <cache>/<sha256> unless a file with the pinned digest
# is already there, and checks the digest on every use. A cached file that no
# longer matches is removed and downloaded again; a download that does not
# match is removed and fails the build. Prints the cached path.
fetch_source() {
	local url=$1 sha256=$2 cache=$3 path part
	case $url in
	https://*) ;;
	*) complain "source URL is not https: $url" || return 1 ;;
	esac
	path=$cache/$sha256
	/bin/mkdir -p "$cache" || return 1
	if [ -f "$path" ]; then
		if verify_sha256 "$path" "$sha256" 2>/dev/null; then
			printf '%s\n' "$path"
			return 0
		fi
		printf 'cached %s no longer matches its digest; downloading again\n' "$path" >&2
		/bin/rm -f "$path"
	fi
	part=$cache/.$sha256.part.$$
	/bin/rm -f "$part"
	if ! /usr/bin/curl --proto '=https' --proto-redir '=https' --fail --location \
		--silent --show-error --retry 2 --max-time 1800 -o "$part" "$url"; then
		/bin/rm -f "$part"
		complain "download failed: $url"
		return 1
	fi
	if ! verify_sha256 "$part" "$sha256"; then
		/bin/rm -f "$part"
		complain "the download from $url does not match the pinned sha256"
		return 1
	fi
	/bin/mv -f "$part" "$path" || return 1
	printf '%s\n' "$path"
}

# Extracts a source tarball into <dest>, after checking its sha256 again, so
# no byte is extracted before the digest matches.
extract_verified() {
	local file=$1 sha256=$2 dest=$3
	verify_sha256 "$file" "$sha256" || return 1
	/bin/mkdir -p "$dest" || return 1
	/usr/bin/tar -xf "$file" -C "$dest"
}

# ---------------------------------------------------------------------------
# System libraries through small .pc files (meson finds libxml2, libedit,
# and uuid only through pkg-config)

write_sdk_pc() {
	local dir=$1 sdk=$2 xml2_version zlib_version
	xml2_version=$(/usr/bin/xml2-config --version) || return 1
	zlib_version=$(/usr/bin/sed -n 's/^#define ZLIB_VERSION "\([^"]*\)".*/\1/p' "$sdk/usr/include/zlib.h")
	[ -n "$xml2_version" ] && [ -n "$zlib_version" ] ||
		complain "cannot read the libxml2 or zlib version of the SDK" || return 1
	/bin/mkdir -p "$dir" || return 1
	/bin/cat >"$dir/libxml-2.0.pc" <<EOF
Name: libxml-2.0
Description: libxml2 from the macOS SDK
Version: $xml2_version
Cflags: -I$sdk/usr/include/libxml2
Libs: -lxml2
EOF
	/bin/cat >"$dir/libedit.pc" <<EOF
Name: libedit
Description: libedit from the macOS SDK
Version: 3.0
Libs: -ledit
EOF
	/bin/cat >"$dir/zlib.pc" <<EOF
Name: zlib
Description: zlib from the macOS SDK
Version: $zlib_version
Libs: -lz
EOF
	/bin/cat >"$dir/uuid.pc" <<EOF
Name: uuid
Description: uuid functions in libSystem
Version: 1.0
EOF
}

# ---------------------------------------------------------------------------
# Mach-O helpers

# True when the file starts with a Mach-O or universal magic number.
is_macho() {
	local magic
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	magic=$(/usr/bin/od -An -tx1 -N4 "$1" 2>/dev/null | /usr/bin/tr -d ' \n')
	case $magic in
	cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) return 0 ;;
	*) return 1 ;;
	esac
}

# install_name_tool without its "invalidates the code signature" warning; the
# file is signed again at the end of relocate.
name_tool() {
	local out
	out=$(/usr/bin/install_name_tool "$@" 2>&1) && return 0
	printf '%s\n' "$out" >&2
	complain "install_name_tool $* failed"
}

# Prints every Mach-O file under <dir>, sorted.
list_macho() {
	local file
	/usr/bin/find "$1" -type f | /usr/bin/sort | while IFS= read -r file; do
		if is_macho "$file"; then printf '%s\n' "$file"; fi
	done
}

# The install name of a dylib (LC_ID_DYLIB), or nothing.
macho_id() {
	/usr/bin/otool -l "$1" | /usr/bin/awk '
		/^ *cmd / { cmd = $2 }
		cmd == "LC_ID_DYLIB" && /^ *name / && !done { sub(/^ *name /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; done = 1 }'
}

# Every library a Mach-O loads, one per line.
macho_deps() {
	/usr/bin/otool -l "$1" | /usr/bin/awk '
		/^ *cmd / { cmd = $2 }
		(cmd == "LC_LOAD_DYLIB" || cmd == "LC_LOAD_WEAK_DYLIB" || cmd == "LC_REEXPORT_DYLIB" || cmd == "LC_LAZY_LOAD_DYLIB" || cmd == "LC_LOAD_UPWARD_DYLIB") && /^ *name / {
			sub(/^ *name /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }'
}

# Every LC_RPATH of a Mach-O, one per line.
macho_rpaths() {
	/usr/bin/otool -l "$1" | /usr/bin/awk '
		/^ *cmd / { cmd = $2 }
		cmd == "LC_RPATH" && /^ *path / { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }'
}

# The rpath from the folder of <file> to <root>/lib: @loader_path/../lib for
# bin/, @loader_path for lib/, @loader_path/.. for lib/postgresql/.
loader_rpath() {
	local root=$1 file=$2 dir rel up="" part
	dir=${file%/*}
	rel=${dir#"$root"}
	rel=${rel#/}
	case $rel in
	lib) printf '@loader_path\n' ;;
	lib/*)
		rel=${rel#lib/}
		while [ -n "$rel" ]; do
			part=${rel%%/*}
			up="$up/.."
			[ "$part" = "$rel" ] && rel="" || rel=${rel#*/}
		done
		printf '@loader_path%s\n' "$up"
		;;
	*)
		while [ -n "$rel" ]; do
			part=${rel%%/*}
			up="$up../"
			[ "$part" = "$rel" ] && rel="" || rel=${rel#*/}
		done
		printf '@loader_path/%slib\n' "$up"
		;;
	esac
}

# Copies into <pkg>/lib every dylib under <deps>/lib that a Mach-O of the
# package loads, under the name it is loaded by (the real file, not the
# symlink), until nothing new is referenced. ICU libraries load each other.
bundle_dependencies() {
	local pkg=$1 deps=$2 changed=1 file dep name
	while [ "$changed" = 1 ]; do
		changed=0
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			while IFS= read -r dep; do
				case $dep in
				"$deps/lib/"*)
					name=${dep##*/}
					if [ ! -e "$pkg/lib/$name" ]; then
						[ -f "$dep" ] || complain "$file loads $dep, which does not exist" || return 1
						/bin/mkdir -p "$pkg/lib" || return 1
						/bin/cp -L "$dep" "$pkg/lib/$name" || return 1
						/bin/chmod 0755 "$pkg/lib/$name"
						printf 'bundled %s\n' "$name"
						changed=1
					fi
					;;
				esac
			done <<EOF
$(macho_deps "$file")
EOF
		done <<EOF
$(list_macho "$pkg")
EOF
	done
}

# Relocation (spec 0003, Relokasi), in order, in the package folder:
# 1. every dylib in lib/ keeps one real file under the name in its install
#    name, and every symlink is removed;
# 2. every dylib gets the install name @rpath/<file name>;
# 3. every load command that points into <build> becomes @rpath/<file name>;
# 4. every LC_RPATH is removed and each Mach-O gets one @loader_path rpath to
#    lib/ (only when the package has a lib/ folder, so Valkey gets none);
# 5. every Mach-O is signed ad hoc, without the hardened runtime.
relocate() {
	local pkg=$1 build=$2 file id want dep rpath out
	local tmp_build=${build#/private}
	if [ -d "$pkg/lib" ]; then
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			is_macho "$file" || continue
			id=$(macho_id "$file")
			[ -n "$id" ] || continue
			want=${id##*/}
			if [ "${file##*/}" != "$want" ]; then
				/bin/rm -f "$pkg/lib/$want"
				/bin/mv "$file" "$pkg/lib/$want" || return 1
				printf 'renamed lib/%s to lib/%s\n' "${file##*/}" "$want"
			fi
		done <<EOF
$(/usr/bin/find "$pkg/lib" -maxdepth 1 -type f -name '*.dylib' | /usr/bin/sort)
EOF
	fi
	/usr/bin/find "$pkg" -type l -print -delete | /usr/bin/sed 's/^/removed symlink /'
	/bin/chmod -R u+w "$pkg" || return 1

	while IFS= read -r file; do
		[ -n "$file" ] || continue
		id=$(macho_id "$file")
		if [ -n "$id" ]; then
			name_tool -id "@rpath/${file##*/}" "$file" || return 1
		fi
		while IFS= read -r dep; do
			case $dep in
			"$build/"* | "$tmp_build/"*)
				name_tool -change "$dep" "@rpath/${dep##*/}" "$file" || return 1
				;;
			esac
		done <<EOF
$(macho_deps "$file")
EOF
		while IFS= read -r rpath; do
			[ -n "$rpath" ] || continue
			name_tool -delete_rpath "$rpath" "$file" || return 1
		done <<EOF
$(macho_rpaths "$file")
EOF
		if [ -d "$pkg/lib" ]; then
			name_tool -add_rpath "$(loader_rpath "$pkg" "$file")" "$file" || return 1
		fi
		out=$(/usr/bin/codesign --force --sign - "$file" 2>&1) || {
			printf '%s\n' "$out" >&2
			complain "codesign failed on $file"
			return 1
		}
	done <<EOF
$(list_macho "$pkg")
EOF
}

# The bash audit (AC-6 for maintainer artifacts): every Mach-O has an arm64
# slice, loads only @rpath/, @loader_path/, @executable_path/, /usr/lib/, or
# /System/Library/ (and every @rpath/ or @loader_path/ name resolves to a file
# in the package), and has no absolute LC_RPATH.
audit_macho() {
	local root=$1 file rel dir dep rpath name found resolved problems=""
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		rel=${file#"$root"/}
		dir=${file%/*}
		case " $(/usr/bin/lipo -archs "$file" 2>/dev/null) " in
		*" arm64 "*) ;;
		*) problems="$problems$rel: no arm64 slice
" ;;
		esac
		while IFS= read -r rpath; do
			case $rpath in
			"") ;;
			@*) ;;
			*) problems="$problems$rel: LC_RPATH $rpath is absolute
" ;;
			esac
		done <<EOF
$(macho_rpaths "$file")
EOF
		while IFS= read -r dep; do
			case $dep in
			"") ;;
			/usr/lib/* | /System/Library/*) ;;
			@executable_path/*) ;;
			@loader_path/*)
				[ -f "$dir/${dep#@loader_path/}" ] ||
					problems="$problems$rel: $dep does not resolve inside the package
"
				;;
			@rpath/*)
				name=${dep#@rpath/}
				found=0
				while IFS= read -r rpath; do
					case $rpath in
					@loader_path) resolved=$dir ;;
					@loader_path/*) resolved=$dir/${rpath#@loader_path/} ;;
					*) continue ;;
					esac
					if [ -f "$resolved/$name" ]; then found=1; fi
				done <<EOF
$(macho_rpaths "$file")
EOF
				[ "$found" = 1 ] ||
					problems="$problems$rel: $dep does not resolve inside the package
"
				;;
			*) problems="$problems$rel: references $dep
" ;;
			esac
		done <<EOF
$(macho_deps "$file")
EOF
	done <<EOF
$(list_macho "$root")
EOF
	if [ -n "$problems" ]; then
		printf '%s' "$problems" >&2
		complain "the audit found references outside the maintainer allowlist"
		return 1
	fi
}

# AC-12: the package holds only regular files and folders, with no setuid or
# setgid file.
check_tree() {
	local root=$1 bad
	bad=$(/usr/bin/find "$root" ! -type f ! -type d; /usr/bin/find "$root" -type f \( -perm -4000 -o -perm -2000 \))
	if [ -n "$bad" ]; then
		printf '%s\n' "$bad" >&2
		complain "the package holds something other than regular files and folders, or a setuid or setgid file"
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Scans

# Fails when /opt/homebrew appears in a configure log (meson-log.txt or
# config.log) under <dir>, or in any extra file given after it.
scan_config_logs() {
	local dir=$1 hits
	shift
	hits=$(
		/usr/bin/find "$dir" -type f \( -name meson-log.txt -o -name config.log \) -exec /usr/bin/grep -lF /opt/homebrew {} +
		for extra in "$@"; do
			/usr/bin/grep -lF /opt/homebrew "$extra"
		done
	) || true
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits" >&2
		complain "/opt/homebrew appears in the configure logs"
		return 1
	fi
}

# Fails when the builder's home path appears in any file of the package.
scan_home() {
	local root=$1 home=$2 hits
	case $home in
	/?*) ;;
	*) complain "the home path to scan for is not absolute: '$home'" || return 1 ;;
	esac
	hits=$(/usr/bin/grep -rlF -- "$home" "$root") || true
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits" >&2
		complain "the package contains the home path $home"
		return 1
	fi
}

# ---------------------------------------------------------------------------
# Version check from a copy of the package

# Runs `<exe> --version` for every executable under <root> and requires the
# output to contain <version>.
check_versions() {
	local root=$1 version=$2 exe out
	shift 2
	for exe in "$@"; do
		out=$("$root/$exe" --version 2>&1) ||
			complain "$exe --version failed in the copy: $out" || return 1
		case $out in
		*"$version"*) printf '%s: %s\n' "$exe" "$out" ;;
		*) complain "$exe --version does not print $version: $out" || return 1 ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Package and manifest

# The first line of a command's output; sed reads all of it, so the command
# never dies of SIGPIPE under pipefail.
first_line() {
	"$@" 2>&1 | /usr/bin/sed -n 1p
}

# The pinned version of a tool in requirements.txt.
requirement_version() {
	/usr/bin/sed -n "s/^$1==\([^ ]*\).*/\1/p" "$2"
}

# Writes `<sha256>  <file name>` next to <file>.
write_sha256_file() {
	local file=$1
	printf '%s  %s\n' "$(sha256_of "$file")" "${file##*/}" >"$file.sha256"
}

# Packs <pkg_parent>/<id> into <tarball> without AppleDouble entries or the
# builder's user name.
pack() {
	local parent=$1 id=$2 tarball=$3
	/usr/bin/tar -czf "$tarball" --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel -C "$parent" "$id"
}
