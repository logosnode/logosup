#!/usr/bin/env bash
# DESCRIPTION: Start the Logos Blockchain node

cmd_start() {
    detect_platform
    check_docker

    local config_path
    config_path="$(get_user_config_path)"
    local compose_path
    compose_path="$(get_compose_path)"

    if [[ ! -f "$config_path" ]]; then
        die "Node configuration not found at $config_path\nRun 'logosup install' first."
    fi

    if [[ ! -f "$compose_path" ]]; then
        die "Docker compose file not found. Run 'logosup install' first."
    fi

    if docker_is_running; then
        log_warn "Logos Node is already running"
        log_info "Use 'logosup status' to check node status"
        log_info "Use 'logosup stop' to stop, then 'logosup start' to restart"
        return 0
    fi

    # Regenerate compose if the on-disk file disagrees with current settings.
    # Two flavors of drift: network mode (host vs bridge) and host port mapping
    # (bridge mode only — host mode has no port maps to drift).
    if [[ -f "$compose_path" ]]; then
        local needs_regen=false
        local file_has_host_mode=false
        grep -q '^[[:space:]]*network_mode:[[:space:]]*host' "$compose_path" 2>/dev/null && file_has_host_mode=true

        if [[ "$LOGOS_DOCKER_NETWORK_MODE" == "host" ]] && [[ "$file_has_host_mode" == "false" ]]; then
            log_info "Switching to host networking — regenerating docker-compose.yml"
            needs_regen=true
        elif [[ "$LOGOS_DOCKER_NETWORK_MODE" != "host" ]] && [[ "$file_has_host_mode" == "true" ]]; then
            log_info "Switching to bridge networking — regenerating docker-compose.yml"
            needs_regen=true
        elif [[ "$LOGOS_DOCKER_NETWORK_MODE" != "host" ]]; then
            if ! grep -q "\"${LOGOS_API_PORT}:8080\"" "$compose_path" 2>/dev/null || \
               ! grep -q "\"${LOGOS_UDP_PORT}:3000/udp\"" "$compose_path" 2>/dev/null; then
                log_info "Port settings changed — regenerating docker-compose.yml"
                needs_regen=true
            fi
        fi

        if [[ "$needs_regen" == "true" ]]; then
            generate_compose_file
            # OTLP endpoint baked into user_config.yaml depends on the network
            # mode (logos-otel DNS under bridge, 127.0.0.1 under host). Rewrite
            # if the mode just flipped. Idempotent / no-op otherwise.
            migrate_user_config_otlp_endpoint "$(get_user_config_path)"
        fi
    fi

    log_step "Starting Logos Node..."
    local start_output
    if ! start_output="$(docker_up 2>&1)"; then
        echo "$start_output"
        if echo "$start_output" | grep -q "port is already allocated"; then
            local conflict_port
            conflict_port="$(echo "$start_output" | grep -oE 'Bind for [0-9.:]+' | head -1 | sed 's/Bind for //' | sed 's/.*://')" || true
            echo ""
            log_error "Port ${conflict_port:-} is already in use by another process."
            log_info "Find what's using it:  ${BOLD}sudo lsof -i :${conflict_port:-${LOGOS_API_PORT}} | grep LISTEN${RESET}"
            log_info "Or change the port:    ${BOLD}Edit LOGOS_API_PORT in $LOGOS_SETTINGS_FILE${RESET}"
            log_info "Then regenerate:       ${BOLD}logosup update node${RESET}"
        else
            log_error "Failed to start node. Check 'logosup logs' for details."
        fi
        return 1
    fi

    log_success "Logos Node container started"
    log_info "Waiting for node to initialize..."

    local health_rc
    docker_health_wait 120 && health_rc=0 || health_rc=$?

    if [[ $health_rc -eq 0 ]]; then
        echo ""
        log_success "Node is running and healthy!"
        echo ""
        _show_brief_status
    elif [[ $health_rc -eq 2 ]]; then
        echo ""
        log_error "Node container exited unexpectedly"
        log_info "Last log lines:"
        echo ""
        $DOCKER_CMD logs --tail 30 "$LOGOS_CONTAINER_NAME" 2>&1 | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done || true
        echo ""
        log_info "For the full log run: ${BOLD}logosup logs${RESET}"
        return 1
    else
        echo ""
        log_warn "Node started but health check hasn't passed yet"
        log_info "This is normal during initial sync. The node may take a few minutes."
        log_info "Check progress with: ${BOLD}logosup status${RESET}"
        log_info "View logs with:      ${BOLD}logosup logs${RESET}"
    fi

    # Start monitoring if compose file exists
    local monitoring_compose
    monitoring_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
    if [[ -f "$monitoring_compose" ]]; then
        source "$LOGOS_NODE_LIB/monitoring.sh"
        if ! monitoring_is_running; then
            log_step "Starting monitoring stack..."
            monitoring_up
            local grafana_host
            grafana_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
            grafana_host="${grafana_host:-localhost}"
            log_success "Monitoring running at ${BOLD}https://${grafana_host}:${LOGOS_GRAFANA_PORT}${RESET}"
        fi
    fi

    echo ""
    log_info "Check node status: ${BOLD}logosup status${RESET}"
}

_show_brief_status() {
    local api_url="http://localhost:${LOGOS_API_PORT}"

    local consensus
    consensus="$(curl -sf "${api_url}/cryptarchia/info" 2>/dev/null)" || true

    local network
    network="$(curl -sf "${api_url}/network/info" 2>/dev/null)" || true

    if [[ -n "$consensus" ]]; then
        local mode slot height
        mode="$(echo "$consensus" | sed -E 's/.*"mode":"([^"]+)".*/\1/')"
        slot="$(echo "$consensus" | sed -E 's/.*"slot":([0-9]+).*/\1/')"
        height="$(echo "$consensus" | sed -E 's/.*"height":([0-9]+).*/\1/')"

        log_info "Consensus mode: ${BOLD}${mode}${RESET}"
        log_info "Slot: ${slot}  |  Height: ${height}"
    fi

    if [[ -n "$network" ]]; then
        local peers
        peers="$(echo "$network" | sed -E 's/.*"n_peers":([0-9]+).*/\1/')"
        log_info "Connected peers: ${BOLD}${peers}${RESET}"
    fi
}
