#!/usr/bin/env bash

set -euo pipefail

SKIP_TESTS="${SKIP_TESTS:-false}"

ROOT="${ROOT:-$PWD/fake}"

PKG_DATA="$ROOT/var/lib/pkg"
PKG_CACHE="$ROOT/var/cache/pkg"

PKG_TMP="/tmp"

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

pkg_installed()
{
	local name="$1"

	[ -d "$PKG_DATA/$name" ] || false
}

pkg_has_var() # [name]...
{
	until [ $# -eq 0 ]
	do
		local name="$1"; shift

		[ -n "${!name-}" ] || return
	done
}

pkg_has_fun() # [name]...
{
	while [ $# -gt 0 ]
	do
		local name="$1"; shift

		declare -f -F "$name" >/dev/null || return
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

# Fetch an archive at "proto://repo:branch" and create a tar archive and a
# md5 hash.
pkg_src_fetch_git() # name_dst
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
			git clone --depth 1 --single-branch --branch "$branch" "$proto://$repo" "$name"
		fi
		name_dst="$name"
	else
		echo "Invalid url format: $1" >&2 && false
	fi
}

pkg_src_fetch_http()
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

pkg_src_fetch() # [url]...
{
	local url="$1"; shift
	local src_name

	echo "Fetching $url..."

	# Fetch git repo or http file.
	if [[ "$url" =~ ^[^:]+://[^:]+\.git:.* ]]
	then
		pkg_src_fetch_git "$url" src_name
	elif [[ "$url" =~ ^[^:]+://[^:]+.* ]]
	then
		pkg_src_fetch_http "$url" src_name
	else
		src_name=$(basename "$url")

		cp -a "$ROOT/$url" "$src_name"
	fi

	if [[ "$src_name" =~ .*\.tar.* ]]
	then
		echo "Extracting $src_name..."
		tar xf "$src_name"
	fi

	echo "Fetched $src_name!"
}

pkg_src_check() # src_name expected_sum
{
	local src_name="$1"
	local expected_sum="$2"
	local actual_sum

	actual_sum=$(md5sum "$src_name" | cut -d ' ' -f 1)

	[ "$actual_sum" == "$expected_sum" ] || return
}

pkg_archive() # archive_path build_dir
{
	local archive_path="$1"
	local build_dir="$2"

	pushd "$build_dir"
		tar cf "$archive_path" .
	popd

	md5sum "$archive_path" > "$archive_path.md5"
}

pkg_extract() # archive_path install_dir
{
	local archive_path="$1"
	local install_dir="$2"

	md5sum --check "$archive_path.md5"

	pushd "$install_dir"
		tar xf "$archive_path"
	popd
}

pkg_archive_files() # archive_path [root]
{
	local archive_path="$1"
	local root="${2-}/"

	tar -tf "$archive_path" | sed -e "s|^./|$root|g" -e '/^$/d'
}

pkg_load() # pkg_file
{
	local pkg_file="$1"

	sources=() md5sums=()
	name='' version=''

	# shellcheck source=/dev/null
	source "$pkg_file"

	pkg_assert_var "$pkg_file" name version
	pkg_assert_fun "$pkg_file" build
}

pkg_prepare() # cache_dir
{
	local cache_dir="$1"

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

				[ "$i" -lt "${#md5sums[@]}" ] && pkg_src_check "$src_file" "${md5sums[$i]}"
				((i += 1))
			done
		fi
		if pkg_has_fun prepare
		then
			echo "Preparing $pkg_file..."
			prepare; unset -f prepare
		fi
	popd
}

pkg_build() # [pkg]...
{
	[ "$#" -lt 1 ] && echo "build needs at least one target!" >&2 && false

	local pkg_file
	local src_dir build_dir cache_dir
	local pkg_archive

	local sources md5sums
	local name version

	pkg_init

	while [ "$#" -gt 0 ]
	do
		pkg_file="${1%.pkg}.pkg"; shift

		echo "Loading $pkg_file..."
		pkg_load "$pkg_file"

		src_dir=$(mktemp -d "$PKG_TMP/$name-$version.XXXX.source")
		build_dir=$(mktemp -d "$PKG_TMP/$name-$version.XXXX.build")
		cache_dir="$PKG_CACHE/$name/$version"

		pkg_archive="$cache_dir/pkg.tar.xf"

		if [ -f "$pkg_archive" ]
		then
			if md5sum --check "$pkg_archive.md5"
			then
				echo "$name has already been built!"

				ln -sf "$pkg_archive" "$cache_dir/../pkg.tar.xf"
				ln -sf "$pkg_archive.md5" "$cache_dir/../pkg.tar.xf.md5"

				continue
			else
				echo "warning: removing corrupt archive $pkg_archive!"
				rm "$pkg_archive"
			fi
		fi

		pkg_prepare "$cache_dir"

		pushd "$build_dir"
			echo "Initializing source directory..."
			cp -a "$cache_dir/." "$src_dir"

			echo "Building $pkg_file..."

			export DESTDIR="$build_dir" SRCDIR="$src_dir"
			export USRLIBDIR="/usr/lib" USRBINDIR="/usr/bin"
			# TODO: Make some constants read-only

			build; unset -f build

			if [ -d "$src_dir" ]
			then
				echo "Removing source directory..."
				rm -rf "$src_dir"
			fi

		popd

		echo "Packaging $pkg_file..."
		pkg_archive "$pkg_archive" "$build_dir"

		ln -sf "$pkg_archive" "$cache_dir/../pkg.tar.xf"
		ln -sf "$pkg_archive.md5" "$cache_dir/../pkg.tar.xf.md5"
	done
}

pkg_installed() # [pkg]...
{
	local pkg

	while [ "$#" -gt 0 ]
	do
		pkg="${1%.pkg}"; shift

		[ -f "$PKG_DATA/$pkg/files" ] || return
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
	[ "$#" -lt 1 ] && echo "uninstall needs at least one target!" >&2 && false

	local data_dir
	local pkg
	local pkg_files

	while [ "$#" -gt 0 ]
	do
		pkg="${1%.pkg}"; shift
		data_dir="$PKG_DATA/$pkg"
		pkg_files="$data_dir/files"

		if [ -f "$pkg_files" ]
		then
			echo "Uninstalling $pkg..."

			pkg_files "$pkg" \
			| xargs --delimiter=$'\n' \
				rm -f

			pkg_dirs "$pkg" \
			| xargs --delimiter=$'\n' \
				rmdir --ignore-fail-on-non-empty

			rm "$pkg_files"

			echo "Uninstalled $pkg!"
		else
			echo "warning: $pkg is not installed"
		fi
	done
}

pkg_install() # [pkg]...
{
	[ "$#" -lt 1 ] && echo "install needs at least one target!" >&2 && false

	local pkg
	local cache_dir data_dir
	local pkg_archive

	while [ "$#" -gt 0 ]
	do
		pkg="${1%.pkg}"; shift
		cache_dir="$PKG_CACHE/$pkg"
		data_dir="$PKG_DATA/$pkg"

		! pkg_installed "$pkg" || pkg_uninstall "$pkg"
		pkg_archive="$cache_dir/pkg.tar.xf"

		if ! [ -f "$pkg_archive" ]
		then
			echo "$pkg has not been built!" >&2
			return 1
		fi

		pkg_extract "$pkg_archive" "$ROOT"

		mkdir -p "$data_dir"
		pkg_archive_files "$pkg_archive" "$ROOT" > "$data_dir/files"
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
	[ "$#" -lt 1 ] && echo "list-files needs at least one target!" >&2 && return 1

	local pkg

	while [ "$#" -gt 0 ]
	do
		pkg="${1%.pkg}"; shift

		if pkg_installed "$pkg"
		then
			pkg_files "$pkg"
		else
			echo "$pkg is not installed!" >&2
			return 1
		fi
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
