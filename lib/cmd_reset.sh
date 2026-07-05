#!/usr/bin/env bash
# DESCRIPTION: Wipe local node data and regenerate config (post-breaking-release migration)

cmd_reset() {
    detect_platform
    check_docker
    _offer_drift_cleanup

    local skip_confirm=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) skip_confirm=true; shift ;;
            -h|--help|help)
                log_info "Usage: logosup reset [-y|--yes]"
                log_info ""
                log_info "Wipes ${BOLD}~/.logos-node/data/${RESET} and regenerates user_config.yaml."
                log_info "Use after a breaking release (e.g. genesis reset)."
                log_info "Your existing user_config.yaml is backed up before regeneration."
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    _perform_migration "manual" "$skip_confirm"
}

# Core migration helper. Shared by `logosup reset` and the breaking-version
# branch in `logosup update`.
#
# Args:
#   $1 = reason ("manual" | "update")
#   $2 = skip_confirm ("true" to bypass the confirmation prompt)
_perform_migration() {
    local reason="${1:-manual}"
    local skip_confirm="${2:-false}"

    print_banner
    log_step "Logos Node migration"
    print_separator
    echo ""

    if [[ "$reason" == "update" ]]; then
        log_warn "${BOLD}Breaking-change migration to ${LOGOS_NODE_VERSION}${RESET}"
    else
        log_warn "${BOLD}This will wipe local node data${RESET}"
    fi

    # Detect whether the current on-disk config predates 0.2.0 — if so, we
    # can preserve wallet identities across the genesis reset by running
    # `migrate-from-0.1.2` before wiping data. The stable discriminator is
    # `tip_poll:` under cryptarchia.network.sync (0.2.0-only marker); its
    # absence means the config is 0.1.x shape. Both 0.1.2 and 0.2.0 have
    # top-level `wallet:` and `known_keys:` under it, so those don't work
    # as version markers. Funds still don't carry over — only identities.
    local preserve_keys=false
    local config_path
    config_path="$(get_user_config_path)"
    if [[ -f "$config_path" ]] && ! grep -qE '^[[:space:]]+tip_poll:[[:space:]]*$' "$config_path"; then
        preserve_keys=true
    fi

    log_info "Steps that will run:"
    log_info "  1. Stop node (and monitoring, if running)"
    log_info "  2. Back up ${BOLD}user_config.yaml${RESET} → ${BOLD}user_config.yaml.pre-migration-<timestamp>${RESET}"
    log_info "  3. Delete ${BOLD}${LOGOS_NODE_DIR}/data/${RESET} (chain DB + logs)"
    log_info "  4. Rebuild Docker image for the current node version"
    if [[ "$preserve_keys" == "true" ]]; then
        log_info "  5. Migrate 0.1.2 → 0.2.0 config ${BOLD}(preserves wallet keys)${RESET}"
    else
        log_info "  5. Regenerate fresh ${BOLD}user_config.yaml${RESET} (new wallet keys)"
    fi
    log_info "  6. Restart node (and monitoring, if it was running)"
    echo ""
    log_dim "After migration you must request faucet funds again — the new chain starts from zero."
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        if ! confirm "Wipe all local node data and regenerate config?" "n"; then
            log_info "Migration cancelled — nothing changed."
            return 0
        fi
    fi

    # ── Step 1: stop node + monitoring ────────────────────────────────
    if docker_is_running; then
        log_step "Stopping node..."
        docker_down
        log_success "Node stopped"
    fi

    source "$LOGOS_NODE_LIB/monitoring.sh"
    if monitoring_is_running; then
        log_step "Stopping monitoring stack..."
        monitoring_down
        log_success "Monitoring stopped"
    fi
    # cmd_start auto-restarts monitoring at the end if the compose file exists.

    # ── Step 2: back up user_config.yaml ──────────────────────────────
    # (config_path already resolved above during preserve_keys detection)
    if [[ -f "$config_path" ]]; then
        local backup_path="${config_path}.pre-migration-$(date +%Y%m%d-%H%M%S)"
        cp "$config_path" "$backup_path"
        chmod 600 "$backup_path"
        log_success "Backed up config to ${BOLD}${backup_path}${RESET}"
        # In the fresh-keys path we drop the old config so init-config generates
        # cleanly. In the preserve-keys path we keep it in place because
        # migrate-from-0.1.2 needs to read it.
        if [[ "$preserve_keys" != "true" ]]; then
            rm -f "$config_path"
        fi
    fi

    # ── Step 3: wipe data dir ─────────────────────────────────────────
    log_step "Wiping ${LOGOS_NODE_DIR}/data/ ..."
    rm -rf "${LOGOS_NODE_DIR}/data"
    mkdir -p "${LOGOS_NODE_DIR}/data"
    log_success "Local chain data cleared"

    # ── Step 4: rebuild image ─────────────────────────────────────────
    docker_build || die "Failed to build Docker image for ${LOGOS_NODE_VERSION}"

    # Regenerate docker-compose.yml against the current lib/docker.sh schema.
    # Without this, operators whose node compose was generated by an older
    # release stay on the old schema indefinitely (e.g. missing the logging
    # caps added in 0.2.2 — saw a 59GB json log on one operator's pi as a
    # direct consequence). Reset is the right place to bring the compose
    # back in sync since we're recreating the container right after anyway.
    generate_compose_file

    # Also regenerate the monitoring compose file in case its schema has
    # changed in this release (e.g. new services like logos-otel). Without
    # this, the existing compose on disk would be stale and the dashboard
    # would silently miss data sources.
    if [[ -f "$(get_monitoring_compose_path)" ]]; then
        generate_monitoring_compose_file
    fi

    # ── Step 5: regenerate config ─────────────────────────────────────
    if [[ "$preserve_keys" == "true" ]]; then
        docker_migrate_from_012 || die "Failed to migrate 0.1.2 config to 0.2.0"
    else
        docker_init_config || die "Failed to regenerate node configuration"
    fi

    # ── Show new keys + faucet ────────────────────────────────────────
    echo ""
    print_separator
    log_step "Your new wallet keys"

    local keys
    keys="$(get_wallet_keys)"
    if [[ -n "$keys" ]]; then
        while IFS= read -r key; do
            log_info "  ${BOLD}${key}${RESET}"
        done <<< "$keys"
    else
        log_warn "Could not parse wallet keys from config"
        log_info "Check your keys with: logosup keys"
    fi

    echo ""
    log_step "Re-claim testnet tokens"
    log_info "Visit the faucet to receive test tokens for your new keys:"
    log_info "  ${BOLD}${LOGOS_FAUCET_URL}${RESET}"
    log_info ""
    log_info "Funds from the previous chain do ${BOLD}not${RESET} carry over."
    echo ""

    # ── Step 6: restart node (cmd_start auto-restarts monitoring) ─────
    log_step "Starting node on the new chain..."
    source "$LOGOS_NODE_LIB/cmd_start.sh"
    cmd_start

    echo ""
    print_separator
    log_success "Migration complete"
    log_info "Check status:  ${BOLD}logosup status${RESET}"
    log_info "View logs:     ${BOLD}logosup logs${RESET}"
    log_info "Faucet:        ${BOLD}logosup faucet${RESET}"
    echo ""
}
