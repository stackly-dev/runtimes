# lz4, bundled with PostgreSQL as liblz4.1.dylib (the library only, which is
# BSD-2-Clause; the lz4 programs are GPL and are not built). Sourced by
# build.sh.
#
# The sha256 was matched against lz4-1.10.0.tar.gz.sha256 from the release
# page when it was pinned (2026-10-18):
#   537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b  lz4-1.10.0.tar.gz

DEP_NAME=lz4
DEP_VERSION=1.10.0
DEP_URL=https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz
DEP_SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
DEP_LICENSE=BSD-2-Clause
DEP_LICENSE_FILE=lib/LICENSE
DEP_SOURCE_DIR=lz4-$DEP_VERSION

# Runs in the source folder. PREFIX is passed to the build too, because the
# install name is taken from it.
dep_build() {
	local prefix=$1
	/usr/bin/make -C lib -j"$JOBS" BUILD_STATIC=no PREFIX="$prefix" lib
	/usr/bin/make -C lib BUILD_STATIC=no PREFIX="$prefix" install
}
