#!/bin/bash
set -euo pipefail

source_app="$1"
install_directory="$2"
destination="$install_directory/Ure.app"

mkdir -p "$install_directory"
staging=$(mktemp -d "$install_directory/.ure-install.XXXXXX")
installed=false

cleanup() {
    if [ "$installed" = false ] && [ -e "$staging/Previous.app" ]; then
        if ! mv "$staging/Previous.app" "$destination"; then
            printf 'Previous app retained at %s\n' "$staging/Previous.app" >&2
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

/usr/bin/ditto "$source_app" "$staging/Ure.app"
/usr/bin/codesign --verify --deep --strict "$staging/Ure.app"

if [ -e "$destination" ]; then
    mv "$destination" "$staging/Previous.app"
fi
if ! mv "$staging/Ure.app" "$destination"; then
    exit 1
fi
installed=true
printf 'Installed %s\n' "$destination"
