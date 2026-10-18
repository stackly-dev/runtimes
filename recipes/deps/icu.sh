# ICU4C, bundled with PostgreSQL as libicuuc, libicui18n, and libicudata (the
# data lives inside libicudata). Sourced by build.sh.
#
# ICU publishes SHA-512 sums, not sha256. When it was pinned (2026-10-18) the
# tarball matched this line of SHASUM512.txt from the release page, and its
# sha256 below was computed from those same bytes:
#   04a49455e1489030c520a4bfd2664fa2171e7938d08f2acdbbcb1fda976639fd8b1f0704f2eec89ba59a7b6d118ceaab6ec5a096e40d9085a0895d91ce225245 *icu4c-78.3-sources.tgz

DEP_NAME=icu
DEP_VERSION=78.3
DEP_URL=https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz
DEP_SHA256=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
DEP_LICENSE=Unicode-3.0
DEP_LICENSE_FILE=LICENSE
DEP_SOURCE_DIR=icu

# Runs in the source folder. On macOS ICU gives its dylibs a bare install name
# (libicuuc.78.dylib) unless --enable-rpath, which makes it
# <prefix>/lib/libicuuc.78.dylib, so the relocation can rewrite it like every
# other reference into the build root. --enable-rpath also adds an absolute
# LC_RPATH to <prefix>/lib; the relocation removes every LC_RPATH and the
# audit refuses any that is absolute.
dep_build() {
	local prefix=$1
	cd source
	./configure --prefix="$prefix" --with-data-packaging=library \
		--disable-samples --disable-tests --enable-rpath
	/usr/bin/make -j"$JOBS"
	/usr/bin/make install
}
