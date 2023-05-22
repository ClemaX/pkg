#!/usr/bin/env bash

set -euo pipefail

# Processor core count
NPROC=$(nproc || echo 1)

# Pager command to show error logs when running interactively
PAGER=$(command -v less || command -v more || command -v tail || command -v cat || :)

# Skip test-suites when available
export SKIP_TESTS="${SKIP_TESTS:-false}"
# Makefile flags: Run as many tasks as there are processor cores
export MAKEFLAGS="${MAKEFLAGS:--j$NPROC}"
# xz options: -T N: Use N threads, -N: Compression preset
export XZ_OPT="${XZ_OPT:--T${NPROC:-0} -6}"

# Temporary variables for build script interaction
PKG_VARS=(pkg_dir pkg_file name version sources md5sums cache_dir data_dir)

# Temporary interface functions
PKG_BUILD_FUNS=(prepare build)
PKG_INSTALL_FUNS=(pre_install post_install)
PKG_UNINSTALL_FUNS=(pre_uninstall post_uninstall)
PKG_FUNS=(
	"${PKG_BUILD_FUNS[@]}"
	"${PKG_INSTALL_FUNS[@]}"
	"${PKG_UNINSTALL_FUNS[@]}"
)

# Target root directory
ROOT="${ROOT:-/}"

# Package management database directory
PKG_DATA="$ROOT/var/lib/pkg"
# Package cache directory
PKG_CACHE="$ROOT/var/cache/pkg"

# Temporary build directory
PKG_TMP="/tmp"

# tar extraction parameters: x: Extract
TAR_XFLAGS=(-x)
# tar compression parameters: c: Compress, J: Filter the archive through xz
TAR_CFLAGS=(-cJ)

# Package extension
TAR_PKG_EXT=.tar.xz

# Package flags
TAR_PKG_CFLAGS=("${TAR_CFLAGS[@]}")
TAR_PKG_XFLAGS=("${TAR_XFLAGS[@]}" --keep-directory-symlink --no-overwrite-dir)

# Source flags
TAR_SRC_XFLAGS=("${TAR_XFLAGS[@]}" --no-same-owner)


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

# Create runtime directories
pkg_init()
{
	mkdir -vp "$PKG_DATA"
	mkdir -vp "$PKG_CACHE"
}

# Check if given variables have been set
pkg_has_var() # [name]...
{
	until [ $# -eq 0 ]
	do
		local name="$1"; shift

		[ -n "${!name-}" ] || return 1
	done
}

# Check if given functions have been defined
pkg_has_fun() # [name]...
{
	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		declare -f -F "$name" >/dev/null || return 1
	done
}

# Assert that given variables have been set
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

# Assert that given functions have been defined
pkg_assert_fun() # pkg_file [name]...
{
	local pkg_file="$1"; shift

	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		if ! pkg_has_fun "$name"
		then
			fatal "$pkg_file: Package needs a $name function!"
		fi
	done
}

# Run a given function
pkg_run() # pkg_fun
{
	local log

	for pkg_fun in "$@"
	do
		if pkg_has_fun "$pkg_fun"
		then
			log=$(mktemp "$PKG_TMP/$name-$version.XXXX.$pkg_fun.log")

			echo "Running $pkg_fun..."

			set +e
				(set -eu; "$pkg_fun") > "$log" 2>&1
				err="$?"
			set -e

			if  [ "$err" -eq 0 ]
			then
				rm "$log"
			else
				[ -t 1 ] && [ -n "$PAGER" ] && "$PAGER" "$log"
				fatal "Could not run $pkg_fun! See $log for more details."
			fi

			unset -f "$pkg_fun"
		fi
	done
}

# Fetch a repo at "url" as "proto://repo:ref", create a tar archive and an
# md5 sum and store it's name in a variable named "name_dst".
pkg_src_fetch_git() # url name_dst
{
	local url="$1"
	local name_dst

	declare -n name_dst="$2"

	if [[ "$url" =~ ^([^:]+)://([^:]+):(.*) ]]
	then
		local proto="${BASH_REMATCH[1]}"
		local repo="${BASH_REMATCH[2]}"
		local ref="${BASH_REMATCH[3]}"

		name="$(basename "$repo" .git)-$ref"

		if [ -d "$name/.git" ]
		then
			pushd "$name"
				git fetch --depth 1 origin "$ref"
				git checkout FETCH_HEAD
				git submodule update --init --recursive --depth 1
			popd
		else
			mkdir -vp "$name"
			pushd "$name"
				git init
				git remote add origin "$proto://$repo"

				git fetch --depth 1 origin "$ref"
				git checkout FETCH_HEAD
				git submodule update --init --recursive --depth 1
			popd
		fi
		name_dst="$name"

		echo "$url"
	else
		fatal "Invalid url format: $1"
	fi
}

# Fetch a file using HTTP at "url" and store it's name in a variable named
# "name_dst".
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

# Fetch a file at "url" and store it's name in a variable named "name_dst".
pkg_src_fetch() # url name_dst
{
	local url="$1"
	local name

	declare -n name="$2"

	echo "Fetching $url..."

	if [[ "$url" =~ ^[^:]+://[^:]+\.git:.* ]]
	then
		# Fetch git repo.
		pkg_src_fetch_git "$url" name
	elif [[ "$url" =~ ^[^:]+://[^:]+.* ]]
	then
		# Fetch http file.
		pkg_src_fetch_http "$url" name
	else
		# Fetch local file.
		name="${url##*/}"

		if [ "$url" != "${url#/}" ]
		then
			cp -av --no-preserve=ownership "$ROOT/$url" "$name"
		else
			cp -av --no-preserve=ownership "$PKGDIR/$url" "$name"
		fi
	fi

	echo "$url -> $name"
}

# Check "src_name" integrity given an md5 "expected_sum"
pkg_src_check() # src_name expected_sum
{
	local src_name="$1"
	local expected_sum="$2"
	local actual_sum

	actual_sum=$(md5sum "$src_name" | cut -d ' ' -f 1)

	[ "$actual_sum" == "$expected_sum" ] || return 1
}

# Archive a package's "build_dir" to "archive_path" and store it's md5 sum to
# "archive_path".md5
pkg_archive() # archive_path build_dir
{
	local archive_path="$1"
	local build_dir="$2"

	pushd "$build_dir"
		tar "${TAR_PKG_CFLAGS[@]}" -f "$archive_path" .
	popd

	md5sum "$archive_path" > "$archive_path.md5"
}

# Extract a package at "archive_path" to "install_dir" after checking the md5
# sum at "archive_path".md5
pkg_extract() # archive_path install_dir
{
	local archive_path="$1"
	local install_dir="$2"

	md5sum --quiet --check "$archive_path.md5"

	pushd "$install_dir"
		tar "${TAR_PKG_XFLAGS[@]}" -f "$archive_path"
	popd
}

# List the files in "archive_path" rebased onto "root" or '/' by default
pkg_archive_files() # archive_path [root]
{
	local archive_path="$1"
	local root="${2-}/"

	tar -tf "$archive_path" | sed -e "s|^./|$root|g" -e '/^$/d'
}

# Load a package script
#
# Assigns pkg_dir pkg_file name version sources md5sums cache_dir data_dir
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

# Unloads a package script
pkg_unload()
{
	unset "${PKG_VARS[@]}"

	unset -f "${PKG_FUNS[@]}" 2>/dev/null || :
}

# Prepare a package for building
pkg_prepare() # src_dir
{
	local src_dir="$1"
	local src dst

	echo "Preparing $name..."

	export SRCDIR="$src_dir"
	export PKGDIR="$pkg_dir"

	mkdir -vp "$cache_dir"
	pushd "$cache_dir"
		if pkg_has_var sources
		then
			pkg_has_var md5sums || md5sums=()

			local i=0
			# shellcheck disable=SC2034
			local src_file

			while [ "$i" -lt "${#sources[@]}" ]
			do
				src="${sources[$i]}"
				src_file=$(basename "$src")

				if [ "$i" -ge "${#md5sums[@]}" ] \
				|| ! [ -f "$src_file" ] \
				|| pkg_src_check "$src_file" "${md5sums[$i]}"
				then
					pkg_src_fetch "$src" src_file
				fi

				if [ "$i" -lt "${#md5sums[@]}" ] \
				&& ! pkg_src_check "$src_file" "${md5sums[$i]}"
				then
					fatal "$src_file: File does not match md5sum!"
				fi

				sources[i]="$src_file"

				((i += 1))
			done
		fi

		echo "Copying cached sources to $src_dir..."
		mkdir -vp "$src_dir"

		cp -a . "$src_dir"

		pushd "$src_dir"
			for src in "${sources[@]}"
			do
				if [[ "$src" =~ ^([^:]*\.(tar|tgz)[^:]*)(:(.*))?$ ]]
				then
					src="${BASH_REMATCH[1]}"
					dst="${BASH_REMATCH[4]}"

					if [ -z "$dst" ]
					then
						echo "Extracting $src..."
						tar "${TAR_SRC_XFLAGS[@]}" -f "$src"
					else

						echo "Extracting $src to $dst..."

						mkdir -p "./$dst"
						pushd "./$dst"
							tar --strip-components=1 \
								"${TAR_SRC_XFLAGS[@]}" -f "$src"
						popd
					fi
				fi
			done

			pkg_run prepare
		popd
	popd
}

# Link an installed package to it's current version
pkg_link() # name version
{
	local name="$1"
	local version="$2"

	local data_dir="$PKG_DATA/$name" cache_dir="$PKG_CACHE/$name"
	local archive="pkg$TAR_PKG_EXT"

	mkdir -vp "$data_dir" "$cache_dir"

	ln -sfv "$version/$name.pkg" "$data_dir/$name.pkg"
	ln -sfv "$version/$archive" "$cache_dir/$archive"
	ln -sfv "$version/$archive.md5" "$cache_dir/$archive.md5"
}

# Build given packages
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

			# Check if this specific version is already built
			if ! pkg_built_version "$pkg" "$version"
			then
				pkg_prepare "$src_dir"

				pushd "$build_dir"
					echo "Building $pkg_file..."

					# shellcheck disable=SC2034
					DESTDIR="$build_dir" USRLIBDIR="/usr/lib" USRBINDIR="/usr/bin"
					# TODO: Make constants read-only

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
			else
				echo "$name has already been built!"
			fi

			if ! diff "$pkg_dir/$pkg_file" "$data_dir/$pkg_file" >/dev/null 2>&1
			then
				echo "Storing $pkg_file..."
				install -vD -m644 "$pkg_dir/$pkg_file" "$data_dir/$pkg_file"
			fi

			pkg_link "$name" "$version"
		popd; pkg_unload
	done
}

# Check if given packages are installed
pkg_installed() # [pkg]...
{
	local pkg

	for pkg in "$@"
	do
		[ -f "$PKG_DATA/$pkg/files" ] || return 1
	done
}

# Check if given packages have been built
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

# Check if a specific version of a given package has been built
pkg_built_version() # pkg version
{
	local pkg="$1"
	local version="$2"

	local pkg_archive

	pkg_archive="$PKG_CACHE/$pkg/$version/pkg$TAR_PKG_EXT"

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
}

# Assert that the given packages have been installed
pkg_assert_installed() # [pkg...]
{
	local pkg

	for pkg in "$@"
	do
		pkg_installed "$pkg" || fatal "$pkg is not installed!"
	done
}

# Assert that the given packages have been built
pkg_assert_built() # [pkg]...
{
	local pkg

	for pkg in "$@"
	do
		pkg_built "$pkg" || fatal "$pkg has not been built!"
	done
}

# List a package's files
pkg_files() # pkg
{
	local pkg="${1%.pkg}"

	grep "$PKG_DATA/$pkg/files" -e '[^/]$'
}

# List a package's directories
pkg_dirs() # pkg
{
	local pkg="${1%.pkg}"

	grep "$PKG_DATA/$pkg/files" -v -e '[^/]$' \
	| sort -r
}

# Uninstall the given packages
pkg_uninstall() # [pkg]...
{
	local pkg
	local pkg_files

	local file directory

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
				| while read -r file
				do
					rm -f -- "$file"
				done

				pkg_dirs "$pkg" \
				| while read -r directory
				do
					directory="${directory%/}"

					if [ -d "$directory" ] && ! [ -h "$directory" ]
					then
						rmdir --ignore-fail-on-non-empty -- "$directory"
					fi
				done

				rm -- "$pkg_files"

				pkg_run post_uninstall

			pkg_unload

			echo "Uninstalled $pkg!"
		else
			echo "warning: $pkg is not installed"
		fi
	done
}

# Install the given packages
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
			echo "Installing $pkg..."

			pkg_run pre_install

			pkg_extract "$pkg_archive" "$ROOT"

			pkg_archive_files "$pkg_archive" "$ROOT" > "$data_dir/../files"

			pkg_run post_install

		pkg_unload
	done
}

# List the installed packages
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

# List the given packages's files
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

# List the given packages's versions
pkg_version() # [pkg]...
{
	local pkg
	local data_dir

	for pkg in "$@"
	do
		pkg="${pkg%.pkg}"; shift
		data_dir="$PKG_DATA/$pkg"

		pkg_assert_installed "$pkg"

		pkg_load "$data_dir/$pkg.pkg"
			echo "$version"
		pkg_unload
	done
}

# Parse action
action="${1:-}"
[ $# -gt 0 ] && shift

case "$action" in
	build)		pkg_build "$@";;
	install)	pkg_install "$@";;
	uninstall)	pkg_uninstall "$@";;
	list)		pkg_list;;
	files)		pkg_list_files "$@";;
	version)	pkg_version "$@";;
	help)		print_usage;;
	*)			print_usage; exit 1;;
esac
