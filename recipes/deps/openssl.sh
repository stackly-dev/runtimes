# OpenSSL, the 3.5 LTS line, bundled with PostgreSQL as libssl.3.dylib and
# libcrypto.3.dylib. Sourced by build.sh.
#
# The sha256 was matched against openssl-3.5.9.tar.gz.sha256 from the
# release page when it was pinned (2026-10-18):
#   603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a *openssl-3.5.9.tar.gz

DEP_NAME=openssl
DEP_VERSION=3.5.9
DEP_URL=https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
DEP_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
DEP_LICENSE=Apache-2.0
DEP_LICENSE_FILE=LICENSE.txt
DEP_SOURCE_DIR=openssl-$DEP_VERSION

# Runs in the source folder. no-module keeps the legacy provider out and the
# artifact carries no openssl.cnf; OPENSSLDIR stays /etc/ssl, which macOS
# has, and install_sw never writes there.
dep_build() {
	local prefix=$1
	/usr/bin/perl ./Configure darwin64-arm64-cc shared no-tests no-docs no-module \
		--openssldir=/etc/ssl --prefix="$prefix" --libdir=lib
	/usr/bin/make -j"$JOBS"
	/usr/bin/make install_sw
}
