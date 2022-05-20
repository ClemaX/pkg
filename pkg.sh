#!/usr/bin/env bash

set -euo pipefail

NPROC=$(nproc || echo 1)

export SKIP_TESTS="${SKIP_TESTS:-false}"
export MAKEFLAGS="-j$NPROC"

PKG_VARS=(pkg_dir pkg_file name version sources md5sums cache_dir data_dir)

PKG_BUILD_FUNS=(prepare build)
PKG_INSTALL_FUNS=(pre_isntall post_install)
PKG_UNINSTALL_FUNS=(pre_uninstall post_uninstall)
PKG_FUNS=(
	"${PKG_BUILD_FUNS[@]}"
	"${PKG_INSTALL_FUNS[@]}"
	"${PKG_UNINSTALL_FUNS[@]}"
)

ROOT="${ROOT:-$PWD/fake}"

PKG_DATA="$ROOT/var/lib/pkg"
PKG_CACHE="$ROOT/var/cache/pkg"

PKG_TMP="/tmp"

TAR_XFLAGS=xf

TAR_PKG_CFLAGS=cJf
TAR_PKG_XFLAGS="$TAR_XFLAGS"
TAR_PKG_EXT=.tar.xz

TAR_SRC_XFLAGS="$TAR_XFLAGS"


fatal() # [msg]...
{
	echo "$@" >&2
	return 1
}

print_usage()
{
	echo "Usage: $0 action [package]...

Where action is one of:
	build:      Build a package and output an installable archive.
	install:    Install a package's files to their final destination.
	uninstall:	Uninstall a package's files.
	list:       List installed packages.
	files:		List files owned by installed packages.
	help:       Print this help message." >&2
}

pkg_init()
{
	mkdir -p "$PKG_DATA"
	mkdir -p "$PKG_CACHE"
}

pkg_has_var() # [name]...
{
	until [ $# -eq 0 ]
	do
		local name="$1"; shift

		[ -n "${!name-}" ] || return 1
	done
}

pkg_has_fun() # [name]...
{
	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		declare -f -F "$name" >/dev/null || return 1
	done
}

pkg_assert_var() # pkg_file [name]...
{
	local pkg_file="$1"; shift

	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		if ! pkg_has_var "$name"
		then
			echo "$pkg_file: Package needs a $name variable!" >&2
			return 1
		fi
	done
}

pkg_assert_fun() # pkg_file [name]...
{
	local pkg_file="$1"; shift

	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		if ! pkg_has_fun "$name"
		then
			echo "$pkg_file: Package needs a $name function!" >&2
			return 1
		fi
	done
}

pkg_run() # pkg_fun
{
	local log

	for pkg_fun in "$@"
	do
		if pkg_has_fun "$pkg_fun"
		then
			log=$(mktemp "$PKG_TMP/$name-$version.XXXX.$pkg_fun.log")

			echo "Running $pkg_fun..."

			if "$pkg_fun" > "$log" 2>&1
			then
				rm "$log"
			else
				echo "Could not run $pkg_fun! See $log for more details." >&2
				return 1
			fi

			unset -f "$pkg_fun"
		fi
	done
}

# Fetch an archive at "proto://repo:branch" and create a tar archive and a
# md5 hash.
pkg_src_fetch_git() # url name_dst
{
	local url="$1"
	local name_dst

	declare -n name_dst="$2"

	if [[ "$url" =~ ^([^:]+)://([^:]+):(.*) ]]
	then
		local proto="${BASH_REMATCH[1]}"
		local repo="${BASH_REMATCH[2]}"
		local branch="${BASH_REMATCH[3]}"

		name="$(basename "$repo" .git)-$branch"

		if [ -d "$name/.git" ]
		then
			pushd "$name"
				git fetch --depth 1 origin "$branch"
			popd
		else
			git clone --depth 1 --single-branch \
				--branch "$branch" "$proto://$repo" "$name"
		fi
		name_dst="$name"

		echo "$url"
	else
		fatal "Invalid url format: $1"
	fi
}

pkg_src_fetch_http() # url name_dst
{
	local url="$1"
	local name_dst
	local name

	declare -n name_dst="$2"

	name=$(basename "$url")
	curl --location --output "$name" "$url"

	# shellcheck disable=SC2034
	name_dst="$name"
}

pkg_src_fetch() # url name_dst
{
	local url="$1"
	local name

	declare -n name="$2"

	echo "Fetching $url..."

	# Fetch git repo or http file.
	if [[ "$url" =~ ^[^:]+://[^:]+\.git:.* ]]
	then
		pkg_src_fetch_git "$url" name
	elif [[ "$url" =~ ^[^:]+://[^:]+.* ]]
	then
		pkg_src_fetch_http "$url" name
	else
		name="${url##*/}"

		if [ "$url" != "${url#/}" ]
		then
			cp -av "$ROOT/$url" "$name"
		else
			cp -av "$PKGDIR/$url" "$name"
		fi
	fi

	echo "$url -> $name"
}

pkg_src_check() # src_name expected_sum
{
	local src_name="$1"
	local expected_sum="$2"
	local actual_sum

	actual_sum=$(md5sum "$src_name" | cut -d ' ' -f 1)

	[ "$actual_sum" == "$expected_sum" ] || return 1
}

pkg_archive() # archive_path build_dir
{
	local archive_path="$1"
	local build_dir="$2"

	pushd "$build_dir"
		tar "$TAR_PKG_CFLAGS" "$archive_path" .
	popd

	md5sum "$archive_path" > "$archive_path.md5"
}

pkg_extract() # archive_path install_dir
{
	local archive_path="$1"
	local install_dir="$2"

	md5sum --quiet --check "$archive_path.md5"

	pushd "$install_dir"
		tar "$TAR_PKG_XFLAGS" "$archive_path"
	popd
}

pkg_archive_files() # archive_path [root]
{
	local archive_path="$1"
	local root="${2-}/"

	tar -tf "$archive_path" | sed -e "s|^./|$root|g" -e '/^$/d'
}

# assigns pkg_dir pkg_file name version sources md5sums cache_dir data_dir
pkg_load() # pkg_file
{
	pkg_file="$1"

	if [ -d "$pkg_file" ]
	then
		pkg_dir="$PWD/${pkg_file%/}"
		pkg_file="${pkg_dir##*/}.pkg"
	else
		[ "$pkg_file" != "${pkg_file#/}" ] \
		&& pkg_dir="$(dirname "$pkg_file")" \
		|| pkg_dir="$PWD/$(dirname "$pkg_file")" \
		
		pkg_file="${pkg_file##*/}"
		pkg_file="${pkg_file%.pkg}.pkg"

		if ! [ -f "$pkg_file" ] \
		&& [ -f "$PKG_DATA/${pkg_file%.pkg}/$pkg_file" ]
		then
			pkg_dir="$PKG_DATA/${pkg_file%.pkg}"
			echo "Using previously built $pkg_file,,,"
		fi
	fi

	sources=() md5sums=()
	name='' version=''

	[ -f "$pkg_dir/$pkg_file" ] || fatal "missing $pkg_dir/$pkg_file!"

	# shellcheck source=/dev/null
	source "$pkg_dir/$pkg_file"

	pkg_assert_var "$pkg_file" name version
	pkg_assert_fun "$pkg_file" build

	cache_dir="$PKG_CACHE/$name/$version"
	data_dir="$PKG_DATA/$name/$version"
}

pkg_unload()
{
	unset "${PKG_VARS[@]}"

	unset -f "${PKG_FUNS[@]}" 2>/dev/null || :
}

pkg_prepare() # src_dir
{
	local src_dir="$1"

	echo "Preparing $name..."

	export SRCDIR="$src_dir"
	export PKGDIR="$pkg_dir"

	mkdir -p "$cache_dir"
	pushd "$cache_dir"
		if pkg_has_var sources
		then
			pkg_has_var md5sums || md5sums=()

			local i=0
			# shellcheck disable=SC2034
			local src_file

			while [ "$i" -lt "${#sources[@]}" ]
			do
				src_file=$(basename "${sources[$i]}")

				if [ "$i" -ge "${#md5sums[@]}" ] || ! [ -f "$src_file" ] \
				|| pkg_src_check "$src_file" "${md5sums[$i]}"
				then
					pkg_src_fetch "${sources[$i]}" src_file
				fi

				if [ "$i" -lt "${#md5sums[@]}" ] \
				&& ! pkg_src_check "$src_file" "${md5sums[$i]}"
				then
					fatal "$src_file: File does not match md5sum!"
				fi

				sources[$i]="$src_file"

				((i += 1))
			done
		fi

		echo "Initializing source directory..."

		if [ -d "$cache_dir" ]
		then
			echo "Copying cached sources to $src_dir..."
			cp -a "$cache_dir/." "$src_dir"

			pushd "$src_dir"
				for src in "${sources[@]}"
				do
					if [[ "$src" =~ .*\.tar.* ]]
					then
						echo "Extracting $src..."
						tar "$TAR_SRC_XFLAGS" "$src"
					fi
				done
			popd
		else
			mkdir -p "$src_dir"
		fi

		pushd "$src_dir"
			pkg_run prepare
		popd
	popd
}

pkg_link() # name version
{
	local name="$1"
	local version="$2"

	local data_dir="$PKG_DATA/$name" cache_dir="$PKG_CACHE/$name"
	local archive="pkg$TAR_PKG_EXT"

	ln -sfv "$data_dir/$version/$name.pkg" "$data_dir/$name.pkg"
	ln -sfv "$cache_dir/$version/$archive" "$cache_dir/$archive"
	ln -sfv "$cache_dir/$version/$archive.md5" "$cache_dir/$archive.md5"
}

pkg_build() # [pkg]...
{
	local "${PKG_VARS[@]}"

	local src_dir build_dir
	local archive

	pkg_init

	for pkg in "$@"
	do
		pkg_load "$pkg"; shift; pushd "$pkg_dir"
			echo "Loading $pkg_file..."

			src_dir=$(mktemp -d "$PKG_TMP/$name-$version.XXXX.source")
			build_dir=$(mktemp -d "$PKG_TMP/$name-$version.XXXX.build")

			archive="$cache_dir/pkg$TAR_PKG_EXT"

			if pkg_built "$pkg"
			then
				echo "$name has already been built!"

				pkg_link "$name" "$version"
				continue
			fi

			pkg_prepare "$src_dir"

			pushd "$build_dir"
				echo "Building $pkg_file..."

				export DESTDIR="$build_dir"
				export USRLIBDIR="/usr/lib" USRBINDIR="/usr/bin"
				# TODO: Make some constants read-only

				pkg_run build

				if [ -d "$src_dir" ]
				then
					echo "Removing source directory..."
					rm -rf "$src_dir"
				fi
			popd

			echo "Packaging $pkg_file..."
			pkg_archive "$archive" "$build_dir"

			if [ -d "$build_dir" ]
			then
				echo "Removing build directory..."
				rm -rf "$build_dir"
			fi

			echo "Storing $pkg_file..."
			install -D "$pkg_dir/$pkg_file" "$data_dir/$pkg_file"

			pkg_link "$name" "$version"
		popd; pkg_unload
	done
}

pkg_installed() # [pkg]...
{
	local pkg

	for pkg in "$@"
	do
		[ -f "$PKG_DATA/$pkg/files" ] || return 1
	done
}

pkg_built() # [pkg]...
{
	local pkg pkg_archive

	for pkg in "$@"
	do
		pkg_archive="$PKG_CACHE/$pkg/pkg$TAR_PKG_EXT"

		if [ -f "$pkg_archive" ]
		then
			if ! md5sum --quiet --check "$pkg_archive.md5"
			then
				echo "warning: removing corrupt archive $pkg_archive!"
				rm "$pkg_archive"
				return 1
			fi
		else
			return 1
		fi
	done
}

pkg_assert_installed() # pkg
{
	local pkg

	for pkg in "$@"
	do
		pkg_installed "$pkg" || fatal "$pkg is not installed!"
	done
}

pkg_assert_built() # [pkg]...
{
	local pkg

	for pkg in "$@"
	do
		pkg_built "$pkg" || fatal "$pkg has not been built!"
	done
}


pkg_files() # pkg
{
	local pkg="${1%.pkg}"

	grep "$PKG_DATA/$pkg/files" -e '[^/]$'
}

pkg_dirs() # pkg
{
	local pkg="${1%.pkg}"

	grep "$PKG_DATA/$pkg/files" -v -e '[^/]$'
}

pkg_uninstall() # [pkg]...
{
	local pkg
	local pkg_files

	local "${PKG_VARS[@]}"

	while [ "$#" -gt 0 ]
	do
		pkg="${1%.pkg}"; shift
		data_dir="$PKG_DATA/$pkg"
		pkg_files="$data_dir/files"

		if [ -f "$pkg_files" ]
		then
			pkg_load "$data_dir/$pkg.pkg"

				echo "Uninstalling $pkg..."

				unset -f "${PKG_BUILD_FUNS[@]}" "${PKG_INSTALL_FUNS[@]}" \
					2>/dev/null

				pkg_run pre_uninstall

				pkg_files "$pkg" \
				| xargs --delimiter=$'\n' \
					rm -f

				pkg_dirs "$pkg" \
				| xargs --delimiter=$'\n' \
					rmdir --ignore-fail-on-non-empty

				rm "$pkg_files"

				pkg_run post_uninstall

			pkg_unload

			echo "Uninstalled $pkg!"
		else
			echo "warning: $pkg is not installed"
		fi
	done
}

pkg_install() # [pkg]...
{
	local pkg pkg_archive

	local "${PKG_VARS[@]}"

	for pkg in "$@"
	do
		pkg="${pkg%.pkg}"; shift

		! pkg_installed "$pkg" || pkg_uninstall "$pkg"

		pkg_file="$PKG_DATA/$pkg/$pkg.pkg"
		pkg_archive="$PKG_CACHE/$pkg/pkg$TAR_PKG_EXT"

		pkg_assert_built "$pkg"

		pkg_load "$pkg_file"

			pkg_run pre_install

			pkg_extract "$pkg_archive" "$ROOT"

			pkg_archive_files "$pkg_archive" "$ROOT" > "$data_dir/../files"

			pkg_run post_install

		pkg_unload
	done
}

pkg_list()
{
	local data_dir

	for data_dir in "$PKG_DATA/"*
	do
		if [ -f "$data_dir/files" ]
		then
			basename "$data_dir"
		fi
	done
}

pkg_list_files() # [pkg]...
{
	local pkg

	for pkg in "$@"
	do
		pkg="${pkg%.pkg}"; shift

		pkg_assert_installed "$pkg"

		pkg_files "$pkg"
	done
}


action="${1:-}"
[ $# -gt 0 ] && shift

case "$action" in
	build)		pkg_build "$@";;
	install)	pkg_install "$@";;
	uninstall)	pkg_uninstall "$@";;
	list)		pkg_list;;
	files)		pkg_list_files "$@";;
	help)		print_usage;;
	*)			print_usage; exit 1;;
esac
