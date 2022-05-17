#!/usr/bin/env bash

set -euo pipefail

SKIP_TESTS="${SKIP_TESTS:-false}"

PKG_DATA="$PWD/fake/var/lib/pkg"
PKG_CACHE="$PWD/fake/var/cache/pkg"

PKG_TMP="/tmp"

print_usage()
{
	echo "Usage: $0 action [package]...

Where action is one of:
	build:      Build a package and output an installable archive.
	install:    Build and install a package to it's final destination.
	list:       List installed packages.
	list-files: List files owned by installed packages.
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
	curl --output "$name" "$url"

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
	else
		pkg_src_fetch_http "$url" src_name
	fi

	echo "Fetched $src_name!"
}

pkg_src_check() # src_name expected_sum
{
	local src_name="$1"
	local expected_sum="$2"
	local actual_sum

	actual_sum=$(md5sum "$src_name" | cut -d ' ' -f 1)

	[ "$actual_sum" != "$expected_sum" ] && false
}

pkg_build() # [pkg]...
{
	[ "$#" -lt 1 ] && echo "build needs at least one target!" >&2 && false

	pkg_init

	local pkg_file="$1"; shift
	local build_dir cache_dir

	pkg_file=$(basename "$pkg_file" .pkg).pkg

	local sources md5sums
	local name version

	# shellcheck source=/dev/null
	source "$pkg_file"

	pkg_assert_var "$pkg_file" name version
	pkg_assert_fun "$pkg_file" build

	# shellcheck disable=SC2154
	build_dir=$(mktemp -d "$PKG_TMP/$name-$version.XXXX.build")
	cache_dir="$PKG_CACHE/$name/$version"

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
				pkg_src_fetch "${sources[$i]}" src_file
				[ "$i" -lt "${#md5sums[@]}" ] && pkg_src_check "$src_file" "${md5sums[$i]}"
				((i += 1))
			done
		fi
		if pkg_assert_fun prepare
		then
			echo "Preparing $pkg_file..."
			prepare
			unset -f prepare
		fi
	popd

	pushd "$build_dir"
		export DESTDIR="$build_dir"
		# TODO: Make some constants read-only

		if [ -d "$cache_dir" ]
		then
			echo "Initializing build directory..."
			cp -a "$cache_dir/." .
		else
			echo "No $cache_dir"
		fi

		echo "Building $pkg_file..."
		build

		unset -f build
	popd
}

pkg_install() # [pkg]...
{
	[ "$#" -lt 1 ] && echo "install needs at least one target!" >&2 && false
}

pkg_list()
{
	true	
}

pkg_list_files() # [pkg]...
{
	[ "$#" -lt 1 ] && echo "list-files needs at least one target!" >&2 && false
}

action="${1:-}"; shift

case "$action" in
	build)		pkg_build "$@";;
	install)	pkg_install "$@";;
	list)		pkg_list "$@";;
	list_files)	pkg_list_files "$@";;
	help)		print_usage;;

	*)			print_usage; exit 1;;
esac
