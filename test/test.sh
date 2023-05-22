#!/usr/bin/env bash

# Example showing example package with simple hook

export ROOT="$PWD/root"

../pkg.sh build example
../pkg.sh install example

ls -l root/{package,hook}-file

../pkg.sh uninstall example
