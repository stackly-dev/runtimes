# Valkey, built with make from the upstream source tarball (spec 0003,
# Resep build maintainer). Sourced by build.sh.
#
# Pinned sources. Each sha256 was matched against the valkey-hashes list
# (https://github.com/valkey-io/valkey-hashes, README) when it was pinned:
#   9.1.2  hash valkey-9.1.2.tar.gz sha256 19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983
#          (matched on 2026-10-18)

recipe_source() {
	case $1 in
	9.1.2)
		SOURCE_URL=https://github.com/valkey-io/valkey/archive/refs/tags/9.1.2.tar.gz
		SOURCE_SHA256=19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983
		;;
	*) return 1 ;;
	esac
	SOURCE_DIR=valkey-$1
}

# No bundled dylib: Valkey links only macOS system libraries.
RECIPE_DEPS=""
RECIPE_LICENSE_FILE=COPYING
RECIPE_EXECUTABLES="bin/valkey-server bin/valkey-cli"

# The settings for both make calls. Valkey rebuilds from scratch when a later
# call passes different settings.
VALKEY_MAKE_SETTINGS="BUILD_TLS=no USE_SYSTEMD=no MALLOC=libc"

# Runs in the source folder; installs into <stage>/valkey. The version ($2)
# is not needed: the source folder is that version.
recipe_build() {
	local stage=$1
	# shellcheck disable=SC2086
	/usr/bin/make -j"$JOBS" $VALKEY_MAKE_SETTINGS
	# shellcheck disable=SC2086
	/usr/bin/make $VALKEY_MAKE_SETTINGS PREFIX="$stage/valkey" USE_REDIS_SYMLINKS=no install
}

# `make install` makes valkey-check-aof, valkey-check-rdb, and valkey-sentinel
# symlinks to valkey-server: the first two become copies of the file and the
# sentinel is left out.
recipe_package() {
	local stage=$1 pkg=$2 name
	/bin/mkdir -p "$pkg/bin"
	for name in valkey-server valkey-cli valkey-benchmark; do
		[ ! -L "$stage/valkey/bin/$name" ] || die "$name is a symlink in the staging prefix"
		/bin/cp "$stage/valkey/bin/$name" "$pkg/bin/$name"
	done
	for name in valkey-check-aof valkey-check-rdb; do
		/bin/cp -L "$stage/valkey/bin/$name" "$pkg/bin/$name"
	done
}

# The notice scan (spec 0003, Notice pihak ketiga): the copyright owners of
# Valkey itself (`|` between them), and the folders of the source to scan.
# deps/ is covered by the vendored components below.
RECIPE_OWNERS="Valkey contributors|Redis Ltd|Salvatore Sanfilippo|Redis contributors"
RECIPE_NOTICE_DIRS="src"

# The .c and .h files of src/ whose first comment block names another
# copyright holder (or names one only on the line after `Copyright`), from
# the scan of the pinned source. Their blocks go under `Third party notices`
# in LICENSES/valkey.txt.
recipe_notice_files() {
	case $1 in
	9.1.2)
		/bin/cat <<'EOF'
src/ae_evport.c
src/ae_kqueue.c
src/connection.c
src/crc16.c
src/crc64.c
src/crccombine.c
src/crcspeed.c
src/crcspeed.h
src/geo.c
src/geohash.c
src/geohash.h
src/geohash_helper.c
src/geohash_helper.h
src/intset.c
src/intset.h
src/lzf.h
src/lzfP.h
src/lzf_c.c
src/lzf_d.c
src/modules/helloacl.c
src/mt19937-64.c
src/mt19937-64.h
src/quicklist.c
src/quicklist.h
src/rdma.c
src/rio.c
src/rio.h
src/sds.c
src/sds.h
src/setcpuaffinity.c
src/setproctitle.c
src/sha256.c
src/sha256.h
src/siphash.c
src/strl.c
src/t_zset.c
src/unix.c
src/util.c
src/valkey-check-aof.c
src/ziplist.c
src/ziplist.h
EOF
		;;
	*) return 1 ;;
	esac
}

# Third party code in the source tarball that is linked statically into the
# packaged binaries (deps/ of the source; jemalloc is not built with
# MALLOC=libc, and gtest-parallel is a test script). One `name|SPDX` per line.
recipe_vendored() {
	printf '%s\n' \
		'lua|MIT' \
		'libvalkey|BSD-3-Clause' \
		'linenoise|BSD-2-Clause' \
		'hdr_histogram|BSD-2-Clause OR CC0-1.0' \
		'fpconv|BSL-1.0' \
		'fast_float|Apache-2.0 OR MIT OR BSL-1.0'
}

# Writes LICENSES/<name>.txt for every vendored component, from the license
# files in deps/ of the source.
recipe_vendored_licenses() {
	local src=$1 dir=$2
	/bin/cp "$src/deps/lua/COPYRIGHT" "$dir/lua.txt"
	/bin/cp "$src/deps/libvalkey/COPYING" "$dir/libvalkey.txt"
	# linenoise keeps its license in the first comment of linenoise.c.
	/usr/bin/sed -n '1,/\*\//p' "$src/deps/linenoise/linenoise.c" >"$dir/linenoise.txt"
	/bin/cat "$src/deps/hdr_histogram/LICENSE.txt" "$src/deps/hdr_histogram/COPYING.txt" >"$dir/hdr_histogram.txt"
	/bin/cp "$src/deps/fpconv/LICENSE.txt" "$dir/fpconv.txt"
	# fast_float keeps its three license notices in the leading comment of ffc.h.
	/usr/bin/awk '/^\/\//{ print; next } { exit }' "$src/deps/fast_float/ffc.h" >"$dir/fast_float.txt"
}
