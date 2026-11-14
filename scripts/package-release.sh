#!/bin/bash
# Packages an already built app locally. Never builds, installs, opens,
# terminates processes, changes quarantine, or contacts a network service.
set -euo pipefail
umask 077

trio_project_dir="$(cd -P -- "$(dirname "$0")/.." && pwd)"
trio_release_root="$trio_project_dir/build/releases"
trio_folder_name="Trio-macOS-universal"
trio_asset_name="$trio_folder_name.zip"
trio_checksum_name="$trio_asset_name.sha256"
trio_stage_dir=""
trio_backup_dir=""
trio_lock_owned=0
trio_promoting=0
trio_completed=0
trio_published_names=()

trio_fail() { printf 'Trio package: %s\n' "$1" >&2; exit 1; }

trio_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

trio_check_architectures() {
    local trio_architectures
    trio_architectures="$(/usr/bin/lipo -archs "$1")" || return 1
    [[ " $trio_architectures " == *" arm64 "* && " $trio_architectures " == *" x86_64 "* ]]
}

trio_validate_bundle() {
    local trio_app="$1"
    [[ -d "$trio_app" && ! -L "$trio_app" ]] || return 1
    [[ -s "$trio_app/Contents/Info.plist" && ! -L "$trio_app/Contents/Info.plist" ]] || return 1
    [[ "$(trio_identifier "$trio_app")" == "com.allm4.Trio" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$trio_app/Contents/Info.plist")" == "Trio" ]] || return 1
    [[ -x "$trio_app/Contents/MacOS/Trio" && ! -L "$trio_app/Contents/MacOS/Trio" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$trio_app" || return 1
    trio_check_architectures "$trio_app/Contents/MacOS/Trio" || return 1
    # The login helper is a nested app with its own identity and signature.
    local trio_helper="$trio_app/Contents/Library/LoginItems/TrioLoginHelper.app"
    [[ -d "$trio_helper" && "$(trio_identifier "$trio_helper")" == "com.allm4.Trio.LoginHelper" ]] || return 1
    trio_check_architectures "$trio_helper/Contents/MacOS/TrioLoginHelper" || return 1
}

trio_cleanup() {
    local trio_exit_status=$?
    local trio_name
    trap - EXIT
    if [[ "$trio_promoting" -eq 1 && "$trio_completed" -eq 0 ]]; then
        # Only move outputs this invocation placed while holding its lock.
        # Old outputs are preserved intact in the backup until promotion ends.
        if [[ ${#trio_published_names[@]} -gt 0 ]]; then
            for trio_name in "${trio_published_names[@]}"; do
                if [[ -e "$trio_release_root/$trio_name" && ! -L "$trio_release_root/$trio_name" ]]; then
                    /bin/mv "$trio_release_root/$trio_name" "$trio_stage_dir/rejected-$trio_name" || true
                fi
            done
        fi
        if [[ -n "$trio_backup_dir" && -d "$trio_backup_dir" ]]; then
            for trio_name in "$trio_folder_name" "$trio_asset_name" "$trio_checksum_name" release.json; do
                if [[ -e "$trio_backup_dir/$trio_name" && ! -e "$trio_release_root/$trio_name" && ! -L "$trio_release_root/$trio_name" ]]; then
                    /bin/mv "$trio_backup_dir/$trio_name" "$trio_release_root/$trio_name" || true
                fi
            done
        fi
    fi
    if [[ -n "$trio_stage_dir" && -d "$trio_stage_dir" && ! -L "$trio_stage_dir" ]]; then
        case "$trio_stage_dir" in
            "$trio_release_root"/.trio-package.*) /bin/rm -rf "$trio_stage_dir" ;;
        esac
    fi
    if [[ "$trio_lock_owned" -eq 1 ]]; then /bin/rmdir "$trio_release_root/.trio-package.lock" 2>/dev/null || true; fi
    exit "$trio_exit_status"
}

[[ $# -le 1 ]] || trio_fail "Usage: scripts/package-release.sh [path/to/Trio.app]"
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || trio_fail "This packaging script requires macOS."
trio_source_app="${1:-$trio_project_dir/build/Trio.app}"
[[ -d "$trio_source_app" && ! -L "$trio_source_app" ]] || trio_fail "The source app is missing or is a symlink."
trio_source_app="$(cd -P -- "$(dirname "$trio_source_app")" && pwd)/$(basename "$trio_source_app")"
trio_validate_bundle "$trio_source_app" || trio_fail "The app identity, signatures, or Universal architectures could not be verified."

trio_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$trio_source_app/Contents/Info.plist")"
trio_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$trio_source_app/Contents/Info.plist")"
trio_min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$trio_source_app/Contents/Info.plist")"
[[ "$trio_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || trio_fail "Invalid CFBundleShortVersionString."
[[ "$trio_build" =~ ^[0-9]+(\.[0-9]+){0,2}([dab]|fc)?[0-9]*$ ]] || trio_fail "Invalid CFBundleVersion."
[[ "$trio_min_os" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || trio_fail "Invalid LSMinimumSystemVersion."
[[ -s "$trio_project_dir/scripts/Install.command" && -s "$trio_project_dir/docs/INSTALLATION.md" ]] || trio_fail "Installer or installation guide is missing."
/bin/bash -n "$trio_project_dir/scripts/Install.command"
[[ ! -L "$trio_project_dir/build" && ! -L "$trio_release_root" ]] || trio_fail "The output directory is a symlink."
/bin/mkdir -p "$trio_release_root"
/bin/mkdir "$trio_release_root/.trio-package.lock" 2>/dev/null || trio_fail "Another package job is running, or its lock needs review."
trio_lock_owned=1
trap trio_cleanup EXIT
trio_stage_dir="$(/usr/bin/mktemp -d "$trio_release_root/.trio-package.XXXXXX")"
trio_payload="$trio_stage_dir/$trio_folder_name"
/bin/mkdir "$trio_payload"
/usr/bin/ditto --rsrc --extattr --qtn --acl "$trio_source_app" "$trio_payload/Trio.app"
/bin/cp "$trio_project_dir/scripts/Install.command" "$trio_payload/Install.command"
/bin/chmod +x "$trio_payload/Install.command"
/bin/cp "$trio_project_dir/docs/INSTALLATION.md" "$trio_payload/INSTALLATION.md"
/bin/cat > "$trio_payload/README.txt" <<'README'
Trio para macOS | Aplicativo gratuito / Free app / App gratuita

Português
Leia INSTALLATION.md. Install.command copia o app para Aplicativos e conserva
a versão anterior. A primeira abertura pode exigir aprovação normal do macOS.
O pacote contém Apple Silicon e Intel; hardware Intel ainda não foi testado.
Aplicativo gratuito. Código-fonte, versão atual e histórico:
https://github.com/Benfic4rthur/Trio

English
Read INSTALLATION.md. Install.command copies the app to Applications and keeps
the previous version. macOS may require its normal first-open approval.
The package contains Apple Silicon and Intel code; Intel hardware is untested.
Free app. Source code, current version and release history:
https://github.com/Benfic4rthur/Trio

Español
Lee INSTALLATION.md. Install.command copia la app a Aplicaciones y conserva
la versión anterior. macOS puede solicitar su autorización normal al abrirla.
Incluye código para Apple Silicon e Intel; no se ha probado hardware Intel.
App gratuita. Código fuente, versión actual e historial:
https://github.com/Benfic4rthur/Trio
README

trio_validate_bundle "$trio_payload/Trio.app" || trio_fail "The staged app failed verification."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent --rsrc --extattr --qtn "$trio_payload" "$trio_stage_dir/$trio_asset_name"
/bin/mkdir "$trio_stage_dir/verify"
/usr/bin/ditto -x -k --rsrc --extattr --qtn "$trio_stage_dir/$trio_asset_name" "$trio_stage_dir/verify"
trio_extracted="$trio_stage_dir/verify/$trio_folder_name"
trio_validate_bundle "$trio_extracted/Trio.app" || trio_fail "The app extracted from the ZIP failed verification."
/bin/bash -n "$trio_extracted/Install.command"
/usr/bin/cmp "$trio_project_dir/scripts/Install.command" "$trio_extracted/Install.command"
/usr/bin/cmp "$trio_project_dir/docs/INSTALLATION.md" "$trio_extracted/INSTALLATION.md"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$trio_extracted/Trio.app/Contents/Info.plist")" == "$trio_version" ]] || trio_fail "The extracted version differs from the source."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$trio_extracted/Trio.app/Contents/Info.plist")" == "$trio_build" ]] || trio_fail "The extracted build differs from the source."

/usr/bin/python3 - "$trio_stage_dir/$trio_asset_name" "$trio_stage_dir/release.json" \
    "$trio_stage_dir/$trio_checksum_name" "$trio_version" "$trio_build" "$trio_min_os" <<'PY'
import hashlib
import json
import pathlib
import sys

archive, metadata, checksum = map(pathlib.Path, sys.argv[1:4])
digest = hashlib.sha256()
with archive.open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
sha = digest.hexdigest()
payload = {
    "bundleIdentifier": "com.allm4.Trio",
    "version": sys.argv[4],
    "build": sys.argv[5],
    "minOS": sys.argv[6],
    "architectures": ["arm64", "x86_64"],
    "assetName": archive.name,
    "sha256": sha,
    "size": archive.stat().st_size,
    "url": "./downloads/" + archive.name,
    "distribution": "free-download",
    "publicDownload": True,
    "publicRelease": False,
    "notarized": False,
    "intelHardwareTested": False,
}
metadata.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
checksum.write_text(f"{sha}  {archive.name}\n", encoding="ascii")
PY

# All validation is complete before changing any previous package output.
for trio_name in "$trio_folder_name" "$trio_asset_name" "$trio_checksum_name" release.json; do
    [[ ! -L "$trio_release_root/$trio_name" ]] || trio_fail "An output path is a symlink: $trio_name"
done
if [[ -e "$trio_release_root/$trio_folder_name" ]]; then
    [[ -d "$trio_release_root/$trio_folder_name" && "$(trio_identifier "$trio_release_root/$trio_folder_name/Trio.app")" == "com.allm4.Trio" ]] || trio_fail "An unknown directory occupies the package output path."
fi
[[ ! -L "$trio_release_root/previous" ]] || trio_fail "The backup path is a symlink."
trio_promoting=1
for trio_name in "$trio_folder_name" "$trio_asset_name" "$trio_checksum_name" release.json; do
    if [[ -e "$trio_release_root/$trio_name" ]]; then
        if [[ -z "$trio_backup_dir" ]]; then
            /bin/mkdir -p "$trio_release_root/previous"
            trio_backup_dir="$(/usr/bin/mktemp -d "$trio_release_root/previous/$(/bin/date +%Y%m%d-%H%M%S).XXXXXX")"
        fi
        /bin/mv "$trio_release_root/$trio_name" "$trio_backup_dir/$trio_name"
    fi
done
for trio_name in "$trio_folder_name" "$trio_asset_name" "$trio_checksum_name" release.json; do
    /bin/mv "$trio_stage_dir/$trio_name" "$trio_release_root/$trio_name"
    trio_published_names+=("$trio_name")
done
trio_completed=1
printf 'Verified local package: %s\nMetadata: %s\n' "$trio_release_root/$trio_asset_name" "$trio_release_root/release.json"
if [[ -n "$trio_backup_dir" ]]; then printf 'Previous outputs preserved: %s\n' "$trio_backup_dir"; fi
