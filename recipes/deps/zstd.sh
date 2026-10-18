# zstd, bundled with PostgreSQL as libzstd.1.dylib, under the BSD-3-Clause
# side of its BSD or GPL-2.0 dual license. Sourced by build.sh.
#
# The sha256 was matched against zstd-1.5.7.tar.gz.sha256 from the release
# page when it was pinned (2026-10-18):
#   eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3  zstd-1.5.7.tar.gz

DEP_NAME=zstd
DEP_VERSION=1.5.7
DEP_URL=https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
DEP_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
DEP_LICENSE=BSD-3-Clause
DEP_LICENSE_FILE=LICENSE
DEP_SOURCE_DIR=zstd-$DEP_VERSION

# Runs in the source folder. Only the shared library, its headers, and its .pc
# file are installed; PREFIX is passed to the build too, because the install
# name is taken from it.
dep_build() {
	local prefix=$1
	/usr/bin/make -C lib -j"$JOBS" PREFIX="$prefix" libzstd-release
	/usr/bin/make -C lib PREFIX="$prefix" install-shared install-includes install-pc
}
