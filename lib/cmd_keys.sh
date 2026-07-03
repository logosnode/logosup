#!/usr/bin/env bash
# DESCRIPTION: Show, backup, and restore wallet keys

cmd_keys() {
    local subcmd="${1:-show}"
    shift 2>/dev/null || true

    case "$subcmd" in
        show|"")           _keys_show ;;
        backup|export)     _keys_backup "$@" ;;
        restore|import)    _keys_restore "$@" ;;
        -h|--help|help)    _keys_help ;;
        *)
            log_error "Unknown subcommand: ${subcmd}"
            _keys_help
            return 1
            ;;
    esac
}

_keys_help() {
    echo ""
    log_step "Wallet key management"
    echo ""
    log_info "${BOLD}Usage:${RESET}"
    log_info "  logosup keys                          Show public keys"
    log_info "  logosup keys backup|export [FILE]     Export wallet keys to a file"
    log_info "  logosup keys restore|import <FILE>    Splice wallet keys back into config"
    echo ""
    log_info "${BOLD}What's in a backup file:${RESET}"
    log_info "  A YAML containing only the key-bearing fields: ${DIM}wallet.known_keys${RESET},"
    log_info "  ${DIM}kms.backend.keys${RESET} (the actual signing material as ${DIM}!Zk${RESET}/${DIM}!Ed25519${RESET}),"
    log_info "  the libp2p ${DIM}node_key${RESET}, blend signing key ids, and funding-pk references."
    log_info "  No peers, ports, monitoring config — just identity. ${BOLD}Anyone with this file can"
    log_info "  spend your funds${RESET}; keep it offline / encrypted."
    echo ""
    log_info "${BOLD}Cross-version safe:${RESET} restore only touches the listed key paths. Network"
    log_info "  settings, monitoring, log filters etc are preserved as-is. Backups taken on"
    log_info "  one node version restore cleanly onto a different version."
    echo ""
    log_info "${BOLD}Dependencies:${RESET} python3 + PyYAML (pre-installed on most Linux/macOS)."
    log_info "  If missing: ${DIM}sudo apt install python3-yaml${RESET}  /  ${DIM}pip3 install pyyaml${RESET}"
    echo ""
}

_keys_show() {
    local config_path
    config_path="$(get_user_config_path)"

    if [[ ! -f "$config_path" ]]; then
        die "Node configuration not found at $config_path\nRun 'logosup install' first."
    fi

    log_step "Wallet keys"

    # LeaderFunding first, star + bold. Others get [Role] tags when the role
    # is known via keystore.yaml. Falls back gracefully on pre-0.2.0 configs
    # (no keystore → plain numbered list, same as before).
    local keys leader_pk
    keys="$(get_wallet_keys_prioritized)"
    leader_pk="$(get_wallet_leader_pk 2>/dev/null)"

    if [[ -z "$keys" ]]; then
        log_warn "No keys found in $config_path"
        return 1
    fi

    echo ""
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local role role_tag key_str is_leader=false
        [[ "$key" == "$leader_pk" ]] && is_leader=true
        role="$(get_wallet_key_role "$key" 2>/dev/null)"
        if $is_leader; then
            role_tag="${BOLD}${CYAN}★ [${role:-LeaderFunding}]${RESET} "
            key_str="${BOLD}${key}${RESET}"
        elif [[ -n "$role" ]]; then
            role_tag="${DIM}[${role}]${RESET} "
            key_str="${BOLD}${key}${RESET}"
        else
            role_tag=""
            key_str="${BOLD}${key}${RESET}"
        fi
        log_info "  ${role_tag}${key_str}"
    done <<< "$keys"

    if [[ -n "$leader_pk" ]]; then
        echo ""
        log_dim "★ = LeaderFunding — fund this key to participate in consensus"
    fi

    echo ""
    log_info "Use these keys with the faucet to receive testnet tokens."
    log_info "Faucet: ${BOLD}${LOGOS_FAUCET_URL}${RESET}"
    echo ""
    log_dim "Backup your keys: ${BOLD}logosup keys backup${RESET}"
    echo ""
}

_keys_check_python() {
    if ! command -v python3 &>/dev/null; then
        log_error "python3 is required for keys backup/restore but isn't installed."
        log_info "Install: ${BOLD}sudo apt install python3${RESET}  /  ${BOLD}brew install python3${RESET}"
        return 1
    fi
    if ! python3 -c "import yaml" &>/dev/null; then
        log_error "PyYAML (python3-yaml) is required but isn't installed."
        log_info "Install: ${BOLD}sudo apt install python3-yaml${RESET}  /  ${BOLD}pip3 install pyyaml${RESET}"
        return 1
    fi
    return 0
}

_keys_backup() {
    local config_path
    config_path="$(get_user_config_path)"

    if [[ ! -f "$config_path" ]]; then
        die "Node configuration not found at $config_path\nRun 'logosup install' first."
    fi

    _keys_check_python || return 1

    local backup_file="${1:-logos-node-keys.backup.yaml}"

    if [[ -f "$backup_file" ]]; then
        log_warn "File already exists: $backup_file"
        if ! confirm "Overwrite?"; then
            log_info "Backup cancelled"
            return 0
        fi
    fi

    # Extract just the key paths into a portable YAML. The keys_io.py helper
    # walks a fixed list of key-bearing paths (network.node_key, kms.*, wallet.*,
    # blend.*.kms_id, leader/sdp funding_pk) so the backup is host-agnostic and
    # cross-version: future schema changes outside those paths don't break
    # restoration.
    if ! python3 "$LOGOS_NODE_LIB/keys_io.py" extract "$config_path" > "$backup_file"; then
        rm -f "$backup_file"
        die "Failed to extract keys from $config_path"
    fi
    chmod 600 "$backup_file"

    if [[ ! -s "$backup_file" ]]; then
        rm -f "$backup_file"
        die "Backup file is empty — no key fields found in config"
    fi

    echo ""
    log_success "Wallet keys backed up to ${BOLD}${backup_file}${RESET}"
    echo ""

    # Show the public keys in the backup
    local count=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        count=$((count + 1))
        log_info "  Key ${count}: ${DIM}${key:0:16}...${RESET}"
    done <<< "$(get_wallet_keys)"

    echo ""
    log_warn "This file contains your KMS private keys (full signing material)."
    log_warn "Store it securely — anyone with this file controls your wallet."
    log_dim "Restore with: ${BOLD}logosup keys restore $backup_file${RESET}"
    echo ""
}

_keys_restore() {
    local backup_file="${1:-}"

    if [[ -z "$backup_file" ]]; then
        log_error "Missing file argument."
        log_info "Usage:   logosup keys import <FILE>     (or: keys restore <FILE>)"
        log_info "Example: logosup keys import logos-node-keys.backup.yaml"
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        die "Backup file not found: $backup_file"
    fi

    _keys_check_python || return 1

    local config_path
    config_path="$(get_user_config_path)"

    if [[ ! -f "$config_path" ]]; then
        die "Node configuration not found at $config_path\nRun 'logosup install' first, then restore keys."
    fi

    # Sanity-check the backup. Both keys-only backups and full-config backups
    # have wallet: and kms: at the top level, so this guard catches truly
    # unrelated files (and the broken older format that only stored
    # known_keys without kms).
    if ! grep -qE "^wallet:" "$backup_file" || ! grep -qE "^kms:" "$backup_file"; then
        log_error "Backup file is missing top-level ${BOLD}wallet:${RESET} and/or ${BOLD}kms:${RESET} sections."
        log_dim "Old-style backups (just the known_keys block) can't be restored — they don't include the KMS signing material that the keys depend on."
        return 1
    fi

    echo ""
    log_step "Restore wallet keys from $backup_file"
    echo ""

    log_info "Backup contains keys:"
    awk '/^[[:space:]]*known_keys:/{found=1; next} found && /^[[:space:]]+[0-9a-f]{64}:/{print "  " substr($1, 1, 17) "..."; next} found{exit}' "$backup_file"
    echo ""

    local current_keys
    current_keys="$(get_wallet_keys 2>/dev/null)"
    if [[ -n "$current_keys" ]]; then
        log_info "Current config has keys:"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            log_info "  ${DIM}${key:0:16}...${RESET}"
        done <<< "$current_keys"
        echo ""
    fi

    log_warn "Wallet keys + KMS material from the backup will replace those in the current config."
    log_dim "Other config (peers, ports, monitoring, log levels) is preserved."
    log_dim "Previous config will be saved to ${BOLD}user_config.yaml.pre-restore-<timestamp>${RESET} for rollback."
    echo ""
    if ! confirm "Proceed with restore?" "n"; then
        log_info "Restore cancelled"
        return 0
    fi

    # Save current config with timestamp for unambiguous rollback
    local rollback="${config_path}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    cp "$config_path" "$rollback"
    chmod 600 "$rollback"

    # Splice via the python helper. Only key paths are written; everything
    # else in the current config is preserved. Cross-version safe.
    local tmp="${config_path}.tmp"
    if ! python3 "$LOGOS_NODE_LIB/keys_io.py" inject "$backup_file" "$config_path" "$tmp"; then
        rm -f "$tmp"
        die "Failed to inject keys into config (rollback at $rollback)"
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        die "Inject produced empty output (rollback at $rollback)"
    fi

    mv "$tmp" "$config_path"
    chmod 600 "$config_path"

    echo ""
    log_success "Wallet keys restored"
    log_info "Previous config saved to ${DIM}${rollback}${RESET}"
    echo ""

    if docker_is_running 2>/dev/null; then
        log_warn "Restart the node to use the restored keys:"
        log_info "  ${BOLD}logosup stop && logosup start${RESET}"
    fi
    echo ""
}
