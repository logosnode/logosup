#!/usr/bin/env bash
# DESCRIPTION: Install and set up the Logos Blockchain node

cmd_install() {
    print_banner
    log_step "Installing Logos Node"
    print_separator

    # 1. Detect platform
    detect_platform
    log_info "Platform: ${BOLD}${LOGOS_OS}/${LOGOS_ARCH}${RESET}"
    [[ "$LOGOS_WSL" == "true" ]] && log_info "WSL detected"

    # 2. Check Docker
    log_step "Checking prerequisites..."
    check_docker
    log_success "Docker is running ($($DOCKER_COMPOSE version --short 2>/dev/null || echo 'compose available'))"
    require_cmd "curl" "Install curl: https://curl.se/download.html"
    log_success "curl available"

    # 3. Initialize config directory
    init_config
    log_success "Config directory: $LOGOS_NODE_DIR"

    # 4. Fetch latest release version
    fetch_latest_versions || die "Failed to fetch release information"

    # Save versions to config
    save_setting "LOGOS_NODE_VERSION" "$LOGOS_NODE_VERSION"
    save_setting "LOGOS_CIRCUITS_VERSION" "$LOGOS_CIRCUITS_VERSION"

    echo ""
    print_separator
    log_info "Ready to install:"
    log_info "  Node version:     ${BOLD}${LOGOS_NODE_VERSION}${RESET}"
    log_info "  Circuits version: ${BOLD}v${LOGOS_CIRCUITS_VERSION}${RESET}"
    log_info "  Docker image:     ${BOLD}${LOGOS_DOCKER_IMAGE}:${LOGOS_NODE_VERSION}${RESET}"
    log_info "  API port:         ${BOLD}${LOGOS_API_PORT}${RESET}"
    log_info "  UDP port:         ${BOLD}${LOGOS_UDP_PORT}${RESET}"
    print_separator
    echo ""

    if ! confirm "Proceed with installation?"; then
        log_info "Installation cancelled"
        exit 0
    fi

    # 5. Generate docker-compose.yml
    generate_compose_file

    # 6. Build Docker image
    docker_build || die "Docker build failed. Check the output above for details."

    # 7. Generate node config (user_config.yaml)
    local config_path
    config_path="$(get_user_config_path)"

    if [[ -f "$config_path" ]]; then
        log_warn "Node configuration already exists at $config_path"
        if ! confirm "Overwrite existing configuration? (your keys will be lost)" "n"; then
            log_info "Keeping existing configuration"
        else
            docker_init_config || die "Failed to generate node configuration"
        fi
    else
        docker_init_config || die "Failed to generate node configuration"
    fi

    # 8. Show wallet keys and faucet info
    echo ""
    print_separator
    log_step "Your node wallet keys"

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

    local keystore_path
    keystore_path="$(get_keystore_path)"
    if [[ -f "$keystore_path" ]]; then
        echo ""
        log_warn "Secret keys are stored in ${BOLD}${keystore_path}${RESET}"
        log_info "${BOLD}Back this file up${RESET} — losing it means losing this node's identity."
    fi

    echo ""
    log_step "Request testnet tokens"
    log_info "Visit the faucet to receive test tokens:"
    log_info "  ${BOLD}${LOGOS_FAUCET_URL}${RESET}"
    log_info ""
    log_info "Enter one of your wallet keys above in the 'Destination Public Key' field"
    log_info "and click 'Request Funds'. Wait 1-2 minutes for the tokens to arrive."
    log_info ""
    log_info "After receiving tokens, your UTXO must age for ~3.5 hours (two epochs)"
    log_info "before your node can participate in consensus."

    # ── Optional extras (before starting the node) ─────────────────────

    # Security hardening (Linux only)
    if [[ "$LOGOS_OS" == "linux" ]]; then
        echo ""
        if confirm "Run security hardening? (firewall, auto-updates, fail2ban)" "n"; then
            source "$LOGOS_NODE_LIB/cmd_security.sh"
            cmd_security apply
        fi
    fi

    # Monitoring dashboard
    source "$LOGOS_NODE_LIB/monitoring.sh"
    if monitoring_is_running; then
        log_info "Monitoring dashboard is running at ${BOLD}https://localhost:${LOGOS_GRAFANA_PORT}${RESET}"
    else
        echo ""
        if confirm "Enable monitoring dashboard? (Grafana + Prometheus)" "n"; then
            # Ask about auth before starting
            echo ""
            if confirm "Require login for Grafana? (recommended if exposed to network)" "n"; then
                source "$LOGOS_NODE_LIB/cmd_monitor.sh"
                _monitor_auth_enable
            fi
            source "$LOGOS_NODE_LIB/cmd_monitor.sh"
            cmd_monitor start
        fi
    fi

    # ── Summary & start ──────────────────────────────────────────────
    echo ""
    print_separator
    log_step "Installation complete!"
    echo ""
    log_info "Start your node:    ${BOLD}logosup start${RESET}"
    log_info "Check status:       ${BOLD}logosup status${RESET}"
    log_info "View logs:          ${BOLD}logosup logs${RESET}"
    log_info "View your keys:     ${BOLD}logosup keys${RESET}"
    log_info "Open faucet:        ${BOLD}logosup faucet${RESET}"
    log_info "Monitoring:         ${BOLD}logosup monitor start${RESET}"
    log_info "Security:           ${BOLD}logosup security${RESET}"
    log_info "Grafana dashboard:  ${BOLD}https://localhost:${LOGOS_GRAFANA_PORT}${RESET}"
    echo ""

    if confirm "Start the node now?"; then
        source "$LOGOS_NODE_LIB/cmd_start.sh"
        cmd_start
    fi
}
