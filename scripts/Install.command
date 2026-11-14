#!/bin/bash
# Runs beside Trio.app in the extracted Trio-macOS-universal folder.
# Uses only macOS tools, preserves quarantine, and never changes Gatekeeper.
set -euo pipefail
umask 077

trio_expected_identifier="com.allm4.Trio"
trio_stage_dir=""
trio_lock_dir=""
trio_lock_owned=0
trio_previous_app=""
trio_destination_app=""

trio_fail() {
    printf '\nTrio: %s\n' "$1" >&2
    exit 1
}

trio_bundle_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

trio_validate_bundle() {
    local trio_app_path="$1"
    [[ -d "$trio_app_path" && ! -L "$trio_app_path" ]] || return 1
    [[ -d "$trio_app_path/Contents" && ! -L "$trio_app_path/Contents" ]] || return 1
    [[ -d "$trio_app_path/Contents/MacOS" && ! -L "$trio_app_path/Contents/MacOS" ]] || return 1
    [[ -s "$trio_app_path/Contents/Info.plist" && ! -L "$trio_app_path/Contents/Info.plist" ]] || return 1
    [[ "$(trio_bundle_identifier "$trio_app_path")" == "$trio_expected_identifier" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$trio_app_path/Contents/Info.plist" 2>/dev/null)" == "Trio" ]] || return 1
    [[ -s "$trio_app_path/Contents/MacOS/Trio" && -x "$trio_app_path/Contents/MacOS/Trio" && ! -L "$trio_app_path/Contents/MacOS/Trio" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$trio_app_path"
}

trio_cleanup() {
    local trio_result=$?
    trap - EXIT
    # Restore the previous bundle if installation stopped after moving it.
    # Never replace a path another process created in the meantime.
    if [[ -n "$trio_previous_app" && -d "$trio_previous_app" && ! -e "$trio_destination_app" && ! -L "$trio_destination_app" ]]; then
        /bin/mv "$trio_previous_app" "$trio_destination_app" || printf 'Trio: versão anterior preservada em %s\n' "$trio_previous_app" >&2
    fi
    if [[ -n "$trio_stage_dir" && -d "$trio_stage_dir" && ! -L "$trio_stage_dir" ]]; then
        case "$trio_stage_dir" in
            "$trio_destination_root"/.Trio-install.*) /bin/rm -rf "$trio_stage_dir" ;;
        esac
    fi
    if [[ "$trio_lock_owned" -eq 1 ]]; then
        /bin/rmdir "$trio_lock_dir" 2>/dev/null || true
    fi
    exit "$trio_result"
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || trio_fail "Este instalador requer macOS."
trio_script_dir="$(cd -P -- "$(dirname "$0")" && pwd)"
trio_source_app="$trio_script_dir/Trio.app"
trio_validate_bundle "$trio_source_app" || trio_fail "Trio.app ausente, com identidade inesperada ou assinatura inválida. Nada foi instalado."

if /usr/bin/pgrep -x Trio >/dev/null 2>&1; then
    trio_fail "Encerre o Trio nas configurações antes de instalar a atualização. Nenhum processo foi encerrado pelo instalador."
fi

trio_destination_root="/Applications"
if [[ ! -d "$trio_destination_root" || -L "$trio_destination_root" || ! -w "$trio_destination_root" ]]; then
    trio_home_dir="${HOME:-}"
    [[ "$trio_home_dir" == /* && "$trio_home_dir" != "/" && -d "$trio_home_dir" ]] || trio_fail "Não foi possível localizar sua pasta pessoal."
    [[ "$(/usr/bin/stat -f '%u' "$trio_home_dir")" == "$(/usr/bin/id -u)" ]] || trio_fail "A pasta pessoal não pertence ao usuário atual."
    trio_destination_root="$trio_home_dir/Applications"
    [[ ! -L "$trio_destination_root" ]] || trio_fail "A pasta Aplicativos pessoal é um link; escolha a instalação manual pelo Finder."
    /bin/mkdir -p "$trio_destination_root"
fi
[[ -d "$trio_destination_root" && -w "$trio_destination_root" && ! -L "$trio_destination_root" ]] || trio_fail "A pasta Aplicativos não permite escrita sem administrador."

trio_destination_app="$trio_destination_root/Trio.app"
[[ "$trio_source_app" != "$trio_destination_app" ]] || trio_fail "O Trio já está nessa pasta. Abra Trio.app diretamente."
[[ ! -L "$trio_destination_app" ]] || trio_fail "O destino Trio.app é um link. Nenhum arquivo foi substituído."
if [[ -e "$trio_destination_app" ]]; then
    [[ -d "$trio_destination_app" && "$(trio_bundle_identifier "$trio_destination_app")" == "$trio_expected_identifier" ]] || trio_fail "Já existe outro item chamado Trio.app. Nenhum arquivo foi substituído."
fi

trio_lock_dir="$trio_destination_root/.Trio-install.lock"
/bin/mkdir "$trio_lock_dir" 2>/dev/null || trio_fail "Há outra instalação em andamento ou uma trava anterior em $trio_lock_dir. Verifique antes de tentar novamente."
trio_lock_owned=1
trap trio_cleanup EXIT
trio_stage_dir="$(/usr/bin/mktemp -d "$trio_destination_root/.Trio-install.XXXXXX")"

printf 'Verificando e copiando apenas Trio.app...\n'
# Explicit flags also override an inherited DITTONORSRC setting. Quarantine
# and extended attributes remain available to the system's first-open checks.
/usr/bin/ditto --rsrc --extattr --qtn --acl "$trio_source_app" "$trio_stage_dir/Trio.app"
trio_validate_bundle "$trio_stage_dir/Trio.app" || trio_fail "A cópia não passou pela verificação de integridade. A versão instalada foi preservada."
if /usr/bin/pgrep -x Trio >/dev/null 2>&1; then
    trio_fail "O Trio foi aberto durante a instalação. Encerre-o e tente novamente."
fi

if [[ -e "$trio_destination_app" ]]; then
    [[ ! -L "$trio_destination_app" && "$(trio_bundle_identifier "$trio_destination_app")" == "$trio_expected_identifier" ]] || trio_fail "O destino mudou durante a instalação. Nada foi substituído."
    trio_backup_dir="$trio_destination_root/.Trio-backups"
    [[ ! -L "$trio_backup_dir" ]] || trio_fail "A pasta de backup é um link; instalação interrompida."
    /bin/mkdir -p "$trio_backup_dir"
    trio_previous_app="$trio_backup_dir/Trio-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
    [[ ! -e "$trio_previous_app" && ! -L "$trio_previous_app" ]] || trio_fail "O caminho de backup já existe."
    /bin/mv "$trio_destination_app" "$trio_previous_app"
fi
/bin/mv "$trio_stage_dir/Trio.app" "$trio_destination_app"
if ! trio_validate_bundle "$trio_destination_app"; then
    # Only move back the exact Trio bundle this installer just placed.
    if [[ ! -L "$trio_destination_app" && "$(trio_bundle_identifier "$trio_destination_app")" == "$trio_expected_identifier" ]]; then
        /bin/mv "$trio_destination_app" "$trio_stage_dir/RejectedTrio.app"
    fi
    trio_fail "A verificação final falhou. A versão anterior será restaurada quando possível."
fi

printf '\nTrio instalado em:\n%s\n' "$trio_destination_app"
if [[ -n "$trio_previous_app" ]]; then
    printf '\nVersão anterior preservada em:\n%s\n' "$trio_previous_app"
fi
printf '\nO macOS pode pedir aprovação em Ajustes do Sistema > Privacidade e Segurança > Abrir Mesmo Assim.\n'
printf 'Confirme apenas se você conhece e confia na origem deste pacote.\n'
printf 'Depois, autorize somente o Trio em Privacidade e Segurança > Acessibilidade.\n'
if ! /usr/bin/open "$trio_destination_app"; then
    printf '\nO app foi instalado. Abra-o pelo Finder e siga o aviso do macOS.\n'
fi
