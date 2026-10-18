# PostgreSQL 17 and 18, built with meson from the official source tarballs,
# with OpenSSL, ICU, lz4, and zstd built from source and bundled as dylibs
# (spec 0003, Resep build maintainer). Sourced by build.sh.
#
# Pinned sources. Each sha256 was matched against the .sha256 file next to the
# tarball on ftp.postgresql.org when it was pinned (2026-10-18):
#   555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f  postgresql-18.6.tar.bz2
#   dd27f2b3c59e73ed14aa3324901242bf69a032a6347805f274e6260322d42979  postgresql-17.11.tar.bz2

recipe_source() {
	case $1 in
	18.6) SOURCE_SHA256=555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f ;;
	17.11) SOURCE_SHA256=dd27f2b3c59e73ed14aa3324901242bf69a032a6347805f274e6260322d42979 ;;
	*) return 1 ;;
	esac
	SOURCE_URL=https://ftp.postgresql.org/pub/source/v$1/postgresql-$1.tar.bz2
	SOURCE_DIR=postgresql-$1
}

# Built in this order into <build>/deps; only the dylibs the package loads
# and their license texts are packaged.
RECIPE_DEPS="openssl icu lz4 zstd"
RECIPE_LICENSE_FILE=COPYRIGHT
RECIPE_EXECUTABLES="bin/postgres bin/initdb bin/psql bin/pg_dump"

# The staging prefix has no "postgres" or "pgsql" in its path, so the layout
# keeps lib/postgresql/ and share/postgresql/, and PostgreSQL finds them
# relative to bin/ after the move.
PG_PREFIX_NAME=stackly-pg

# The meson options for one major version. GSSAPI, LDAP, PAM, Bonjour, NLS,
# JIT, the PL languages other than PL/pgSQL, and libxslt stay out; 18 also
# leaves out OAuth through libcurl, libnuma, and liburing, options 17 lacks.
pg_meson_options() {
	local major=${1%%.*} name
	printf '%s\n' --buildtype=release -Dlibdir=lib -Ddocs=disabled -Dssl=openssl \
		-Dicu=enabled -Dlz4=enabled -Dzstd=enabled -Dlibxml=enabled -Dzlib=enabled \
		-Dreadline=enabled -Dlibedit_preferred=true -Duuid=e2fs
	for name in gssapi ldap pam bonjour bsd_auth selinux systemd tap_tests nls llvm \
		plperl plpython pltcl libxslt; do
		printf -- '-D%s=disabled\n' "$name"
	done
	case $major in
	17) ;;
	18)
		for name in libcurl libnuma liburing; do
			printf -- '-D%s=disabled\n' "$name"
		done
		;;
	*) return 1 ;;
	esac
}

# Runs in the source folder; installs into <stage>/stackly-pg. The meson build
# folder sits inside the source, where the configure log scan finds it.
recipe_build() {
	local stage=$1 version=$2 options
	options=$(pg_meson_options "$version")
	# shellcheck disable=SC2086
	meson setup build --prefix="$stage/$PG_PREFIX_NAME" $options
	ninja -C build -j "$JOBS"
	meson install -C build --no-rebuild
}

# bin/ (pg_config included), lib/ without static libraries and pkgconfig/,
# lib/postgresql/, share/postgresql/, and include/.
recipe_package() {
	local stage=$1/$PG_PREFIX_NAME pkg=$2 entry
	[ -d "$stage/lib/postgresql" ] && [ -d "$stage/share/postgresql" ] ||
		die "the staging prefix has no lib/postgresql/ or share/postgresql/ (flat layout?)"
	/bin/cp -R "$stage/bin" "$pkg/bin"
	/bin/cp -R "$stage/lib" "$pkg/lib"
	/bin/rm -rf "$pkg/lib/pkgconfig"
	/usr/bin/find "$pkg/lib" -name '*.a' -print -delete | /usr/bin/sed 's,^.*/lib/,left out lib/,'
	/bin/mkdir -p "$pkg/share"
	/bin/cp -R "$stage/share/postgresql" "$pkg/share/postgresql"
	for entry in "$stage"/share/*; do
		[ -e "$entry" ] || continue
		[ "${entry##*/}" = postgresql ] || printf 'left out share/%s\n' "${entry##*/}"
	done
	/bin/cp -R "$stage/include" "$pkg/include"
}

# The notice scan (spec 0003, Notice pihak ketiga): the copyright owners of
# PostgreSQL itself (`|` between them), and the folders of the source to scan.
RECIPE_OWNERS="PostgreSQL Global Development Group|Regents of the University of California"
RECIPE_NOTICE_DIRS="src contrib"

# The .c and .h files of src/ and contrib/ whose first comment block names
# another copyright holder (or names one only on the line after
# `Copyright`), from the scan of the pinned sources; 17.11 and 18.6 have the
# same list. Their blocks go under `Third party notices` in
# LICENSES/postgresql.txt.
recipe_notice_files() {
	case $1 in
	17.11 | 18.6)
		/bin/cat <<'EOF'
contrib/pageinspect/btreefuncs.c
contrib/pgcrypto/crypt-des.c
contrib/pgcrypto/mbuf.c
contrib/pgcrypto/mbuf.h
contrib/pgcrypto/openssl.c
contrib/pgcrypto/pgcrypto.c
contrib/pgcrypto/pgcrypto.h
contrib/pgcrypto/pgp-armor.c
contrib/pgcrypto/pgp-cfb.c
contrib/pgcrypto/pgp-compress.c
contrib/pgcrypto/pgp-decrypt.c
contrib/pgcrypto/pgp-encrypt.c
contrib/pgcrypto/pgp-info.c
contrib/pgcrypto/pgp-mpi-openssl.c
contrib/pgcrypto/pgp-mpi.c
contrib/pgcrypto/pgp-pgsql.c
contrib/pgcrypto/pgp-pubdec.c
contrib/pgcrypto/pgp-pubenc.c
contrib/pgcrypto/pgp-pubkey.c
contrib/pgcrypto/pgp-s2k.c
contrib/pgcrypto/pgp.c
contrib/pgcrypto/pgp.h
contrib/pgcrypto/px-crypt.c
contrib/pgcrypto/px-crypt.h
contrib/pgcrypto/px-hmac.c
contrib/pgcrypto/px.c
contrib/pgcrypto/px.h
contrib/pgrowlocks/pgrowlocks.c
contrib/pgstattuple/pgstatindex.c
contrib/pgstattuple/pgstattuple.c
contrib/uuid-ossp/uuid-ossp.c
src/backend/regex/regc_color.c
src/backend/regex/regc_cvec.c
src/backend/regex/regc_lex.c
src/backend/regex/regc_locale.c
src/backend/regex/regc_nfa.c
src/backend/regex/regcomp.c
src/backend/regex/rege_dfa.c
src/backend/regex/regerror.c
src/backend/regex/regexec.c
src/backend/regex/regexport.c
src/backend/regex/regfree.c
src/backend/regex/regprefix.c
src/backend/utils/adt/inet_cidr_ntop.c
src/backend/utils/adt/inet_net_pton.c
src/backend/utils/mb/wstrcmp.c
src/backend/utils/mb/wstrncmp.c
src/bin/pg_dump/pg_backup.h
src/bin/pg_dump/pg_backup_archiver.c
src/bin/pg_dump/pg_backup_archiver.h
src/bin/pg_dump/pg_backup_custom.c
src/bin/pg_dump/pg_backup_directory.c
src/bin/pg_dump/pg_backup_null.c
src/bin/pg_dump/pg_backup_tar.c
src/bin/pg_dump/pg_restore.c
src/common/d2s.c
src/common/d2s_full_table.h
src/common/d2s_intrinsics.h
src/common/f2s.c
src/common/ryu_common.h
src/include/common/shortest_dec.h
src/include/getopt_long.h
src/include/pg_getopt.h
src/include/regex/regcustom.h
src/include/regex/regexport.h
src/include/regex/regguts.h
src/pl/plperl/ppport.h
src/port/getopt_long.c
src/port/inet_net_ntop.c
src/port/pgmkdirp.c
src/port/snprintf.c
src/port/win32gettimeofday.c
src/tools/pg_bsd_indent/args.c
src/tools/pg_bsd_indent/err.c
src/tools/pg_bsd_indent/err.h
src/tools/pg_bsd_indent/indent.c
src/tools/pg_bsd_indent/indent.h
src/tools/pg_bsd_indent/indent_codes.h
src/tools/pg_bsd_indent/indent_globs.h
src/tools/pg_bsd_indent/io.c
src/tools/pg_bsd_indent/lexi.c
src/tools/pg_bsd_indent/parse.c
src/tools/pg_bsd_indent/pr_comment.c
EOF
		;;
	*) return 1 ;;
	esac
}

# PostgreSQL has no vendored component listed in the manifest.
recipe_vendored() {
	:
}

recipe_vendored_licenses() {
	:
}

# pg_config from the copy must find share/ and the module folder inside the
# copy, not in the staging prefix that still exists while this runs.
recipe_check_copy() {
	local root=$1 real name dir
	real=$(cd "$root" && pwd -P)
	for name in sharedir pkglibdir; do
		dir=$("$root/bin/pg_config" "--$name") || complain "pg_config --$name failed" || return 1
		case $dir in
		"$root"/* | "$real"/*) printf 'pg_config --%s: %s\n' "$name" "$dir" ;;
		*) complain "pg_config --$name points outside the copy: $dir" || return 1 ;;
		esac
	done
}
