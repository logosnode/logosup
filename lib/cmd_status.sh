#!/usr/bin/env bash
# DESCRIPTION: Show Logos Node status and health

cmd_status() {
    detect_platform
    check_docker

    print_banner

    local api_url="http://localhost:${LOGOS_API_PORT}"

    # Container status
    log_step "Container"
    if docker_is_running; then
        local state started_at container_status
        state="$(docker inspect --format='{{.State.Status}}' "$LOGOS_CONTAINER_NAME" 2>/dev/null)" || true
        started_at="$(docker inspect --format='{{.State.StartedAt}}' "$LOGOS_CONTAINER_NAME" 2>/dev/null)" || true
        # Docker returns nanosecond precision (2026-07-03T16:02:01.609614217Z);
        # trim to seconds for readability.
        started_at="$(echo "$started_at" | sed -E 's/\.[0-9]+Z$/Z/')"
        container_status="${state} (up since ${started_at})"
        log_success "Running: ${container_status}"

        local health
        health="$(docker inspect --format='{{.State.Health.Status}}' "$LOGOS_CONTAINER_NAME" 2>/dev/null)" || true
        if [[ -n "$health" ]]; then
            case "$health" in
                healthy)   log_success "Health: ${GREEN}healthy${RESET}" ;;
                unhealthy) log_warn "Health: ${RED}unhealthy${RESET}" ;;
                starting)  log_info "Health: ${YELLOW}starting${RESET}" ;;
            esac
        fi
    else
        log_error "Not running"
        log_info "Start with: ${BOLD}logosup start${RESET}"
        return 1
    fi

    # Consensus info
    log_step "Consensus"
    local consensus
    consensus="$(curl -sf "${api_url}/cryptarchia/info" 2>/dev/null)" || true

    if [[ -n "$consensus" ]]; then
        local mode slot height lib tip
        # 0.2.0 wraps the mode in an enum object: "mode":{"Started":"Bootstrapping"}.
        # 0.1.x returned a scalar: "mode":"Bootstrapping". Try the wrapped shape
        # first (extracts the inner variant), fall back to the scalar. On no
        # match the substitution leaves the whole body — detect and blank out.
        mode="$(echo "$consensus" | sed -nE 's/.*"mode":[[:space:]]*\{"[^"]+":[[:space:]]*"([^"]+)"\}.*/\1/p')"
        if [[ -z "$mode" ]]; then
            mode="$(echo "$consensus" | sed -nE 's/.*"mode":[[:space:]]*"([^"]+)".*/\1/p')"
        fi
        slot="$(echo "$consensus" | sed -E 's/.*"slot":([0-9]+).*/\1/')"
        height="$(echo "$consensus" | sed -E 's/.*"height":([0-9]+).*/\1/')"

        case "$mode" in
            Online)        log_success "Mode: ${GREEN}${mode}${RESET}" ;;
            Bootstrapping) log_info "Mode: ${YELLOW}${mode}${RESET} (syncing...)" ;;
            "")            log_info "Mode: ${DIM}(unknown)${RESET}" ;;
            *)             log_info "Mode: ${mode}" ;;
        esac

        log_info "Slot:   ${BOLD}${slot}${RESET}"
        log_info "Height: ${BOLD}${height}${RESET}"
    else
        log_warn "Could not reach consensus API"
    fi

    # Network info
    log_step "Network"
    local network
    network="$(curl -sf "${api_url}/network/info" 2>/dev/null)" || true

    if [[ -n "$network" ]]; then
        local peers connections peer_id
        peers="$(echo "$network" | sed -E 's/.*"n_peers":([0-9]+).*/\1/')"
        connections="$(echo "$network" | sed -E 's/.*"n_connections":([0-9]+).*/\1/')"
        peer_id="$(echo "$network" | sed -E 's/.*"peer_id":"([^"]+)".*/\1/')"

        log_info "Peer ID:     ${DIM}${peer_id}${RESET}"
        log_info "Peers:       ${BOLD}${peers}${RESET}"
        log_info "Connections: ${BOLD}${connections}${RESET}"
    else
        log_warn "Could not reach network API"
    fi

    # Wallet balance (if keys are available). LeaderFunding is listed first
    # and highlighted — that's the key operators need to fund from the faucet
    # for the node to participate in consensus.
    local keys leader_pk
    keys="$(get_wallet_keys_prioritized 2>/dev/null)"
    leader_pk="$(get_wallet_leader_pk 2>/dev/null)"

    if [[ -n "$keys" ]]; then
        source "$LOGOS_NODE_LIB/wallet.sh"
        log_step "Wallet"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            # Bare call, then read WALLET_HTTP_CODE / WALLET_BODY globals.
            # Don't use $(wallet_get_balance ...) — subshells lose the globals.
            wallet_get_balance "$key"

            # Annotate with the semantic role (LeaderFunding, VaucherMaster,
            # Stake, SdpFunding, BlendZk, ...) from keystore.yaml when known.
            # Highlight the LeaderFunding line so it stands out.
            local role role_tag key_str is_leader=false
            [[ "$key" == "$leader_pk" ]] && is_leader=true
            role="$(get_wallet_key_role "$key" 2>/dev/null)"
            if $is_leader; then
                role_tag="${BOLD}${CYAN}★ [${role:-LeaderFunding}]${RESET} "
                key_str="${BOLD}${key}${RESET}"
            elif [[ -n "$role" ]]; then
                role_tag="${DIM}[${role}]${RESET} "
                key_str="${DIM}${key}${RESET}"
            else
                role_tag=""
                key_str="${DIM}${key}${RESET}"
            fi

            if [[ "$WALLET_HTTP_CODE" == "200" && -n "$WALLET_BODY" ]]; then
                local balance
                balance="$(echo "$WALLET_BODY" | sed -E 's/.*"balance":([0-9]+).*/\1/')"
                log_info "${role_tag}${key_str}  balance: ${BOLD}${balance}${RESET}"
            elif [[ "$WALLET_HTTP_CODE" == "200" ]]; then
                log_info "${role_tag}${key_str}  balance: ${BOLD}0${RESET}"
            elif echo "$WALLET_BODY" | grep -qiE "not (be )?found"; then
                # 0.1.x: "not found". 0.2.0: "The requested address could not
                # be found in the wallet". Both mean: wallet is tracking this
                # key but hasn't seen inbound funds. Render as plain 0.
                log_info "${role_tag}${key_str}  balance: ${BOLD}0${RESET}"
            else
                log_info "${role_tag}${key_str}  balance: ${DIM}error (HTTP ${WALLET_HTTP_CODE}): $(wallet_squash_body "$WALLET_BODY" 120 "$WALLET_HTTP_CODE")${RESET}"
            fi
        done <<< "$keys"

        if [[ -n "$leader_pk" ]]; then
            echo ""
            log_dim "★ = LeaderFunding — fund this key to participate in consensus"
        fi
    fi

    # ── Diagnostics: scan the last minute of node logs for known-bad patterns
    _scan_recent_node_logs

    # Useful links
    echo ""
    print_separator
    log_info "Dashboard: ${BOLD}${LOGOS_DASHBOARD_URL}${RESET}"
    log_info "Faucet:    ${BOLD}${LOGOS_FAUCET_URL}${RESET}"
    if [[ -f "$LOGOS_NODE_DIR/docker-compose.monitoring.yml" ]]; then
        local grafana_host
        grafana_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
        grafana_host="${grafana_host:-localhost}"
        log_info "Grafana:   ${BOLD}https://${grafana_host}:${LOGOS_GRAFANA_PORT}${RESET}"
        log_dim "Self-signed cert — accept the browser warning on first visit"
    fi

    # ── Version footer ──────────────────────────────────────────────────
    # Subtle line at the very end showing what's actually installed. Answers
    # "what version am I on" without an extra command. logosup version comes
    # from the CLI's VERSION file; node version is the pinned image tag
    # (falls back to the on-disk container's image if pin is missing);
    # docker-compose is best-effort since some environments hide it.
    local logosup_ver node_ver compose_ver
    if [[ -f "$LOGOS_NODE_DIR/cli/VERSION" ]]; then
        logosup_ver="$(head -1 "$LOGOS_NODE_DIR/cli/VERSION" 2>/dev/null)"
    fi
    logosup_ver="${logosup_ver:-unknown}"
    node_ver="${LOGOS_NODE_VERSION:-unknown}"
    compose_ver="$($DOCKER_COMPOSE version --short 2>/dev/null || echo unknown)"
    echo ""
    log_dim "logosup ${logosup_ver} · node ${node_ver} · compose ${compose_ver}"
    echo ""
}

# Scan the last minute of node container logs and surface categorized
# warnings. Emits nothing when the log window is clean — so healthy nodes
# don't grow a noisy status output. Silent when the container isn't
# running (Container section above already reported that).
#
# Each pattern is chosen because it silently blocks progress in a way
# operators can't tell from height/peer counts alone:
#   - protocol mismatch: connected peers on the wrong network version can't
#     serve chainsync. This wasted hours on the Lisbon Pi.
#   - IBD failure: the binary graceful-shutdowns when bootstrap peers can't
#     be reached; docker restarts it, and it happens again → crash loop.
#   - NTP failure: clock drift breaks consensus timing.
#   - Network unreachable: outbound blocked (usually UFW/Docker iptables).
#   - Gateway detection failure: libp2p NAT traversal can't work.
_scan_recent_node_logs() {
    docker_is_running || return 0

    local window
    # --since=60s covers active state without dragging in old crash-loop
    # noise from an install/reset that already resolved itself.
    window="$($DOCKER_CMD logs --since 60s "$LOGOS_CONTAINER_NAME" 2>&1)" || return 0
    [[ -z "$window" ]] && return 0

    local proto_mismatch ibd_failed ntp_failed net_unreach no_gateway
    proto_mismatch="$(echo "$window" | grep -cE 'does not support /logos-blockchain-[a-z]+-[0-9]+\.[0-9]+\.[0-9]+/chainsync' 2>/dev/null || echo 0)"
    ibd_failed="$(echo "$window"     | grep -cE 'Initial Block Download failed: AllPeersFailed'                          2>/dev/null || echo 0)"
    ntp_failed="$(echo "$window"     | grep -cE 'NTP sync failed'                                                        2>/dev/null || echo 0)"
    net_unreach="$(echo "$window"    | grep -cE 'Network is unreachable|Temporary failure in name resolution'            2>/dev/null || echo 0)"
    no_gateway="$(echo "$window"     | grep -cE 'Failed to detect gateway|Failed to get default gateway'                 2>/dev/null || echo 0)"

    # Nothing to say → don't print the section header at all.
    if (( proto_mismatch == 0 && ibd_failed == 0 && ntp_failed == 0 && net_unreach == 0 && no_gateway == 0 )); then
        return 0
    fi

    log_step "Diagnostics"
    log_dim "(from the last 60s of node logs)"

    # Extract the specific chainsync protocol the peers are refusing so we
    # can quote it back to the operator. Only meaningful if we found any.
    if (( proto_mismatch > 0 )); then
        local proto
        proto="$(echo "$window" | grep -oE '/logos-blockchain-[a-z]+-[0-9]+\.[0-9]+\.[0-9]+/chainsync/[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1)"
        log_warn "Protocol mismatch — ${proto_mismatch} peers don't speak this node's chainsync"
        log_dim "  Peers can gossip at the libp2p layer but can't serve blocks. Height won't advance."
        log_dim "  Our node advertises: ${BOLD}${proto}${RESET}${DIM}"
        log_dim "  Fleet may be on a different network version — cross-check network.yml"
        log_dim "  against https://github.com/logos-blockchain/logos-blockchain/releases/latest"
    fi

    if (( ibd_failed > 0 )); then
        log_warn "IBD failed ${ibd_failed}× — node graceful-shutdowns when bootstrap peers unreachable"
        log_dim "  Docker's restart policy is re-launching it in a loop. If this persists past 2-3"
        log_dim "  minutes, verify UDP connectivity to the bootstrap peers listed in network.yml:"
        log_dim "    for p in 3000 3001 3002 50001; do timeout 3 bash -c \"echo x > /dev/udp/65.109.51.37/\$p\" 2>&1 && echo \"\$p OK\"; done"
    fi

    if (( net_unreach > 0 )); then
        log_warn "Container reported network-unreachable ${net_unreach}× in last 60s"
        log_dim "  Usually a transient during boot before Docker's bridge finishes attaching."
        log_dim "  If it persists, check: ${BOLD}sudo systemctl restart docker${RESET}${DIM} then retry."
    fi

    if (( ntp_failed > 0 )); then
        log_warn "NTP sync failed ${ntp_failed}× — clock drift will break consensus timing"
        log_dim "  Container needs outbound DNS + UDP/123 to pool.ntp.org."
        log_dim "  Check: ${BOLD}docker exec ${LOGOS_CONTAINER_NAME} getent hosts pool.ntp.org${RESET}"
    fi

    if (( no_gateway > 0 )); then
        log_warn "libp2p NAT module can't detect gateway (${no_gateway}× in last 60s)"
        log_dim "  If your node has a static public IP, set ${BOLD}LOGOS_EXTERNAL_IP${RESET}${DIM} in"
        log_dim "  ${LOGOS_SETTINGS_FILE} and run ${BOLD}logosup reset${RESET}${DIM} to skip NAT traversal."
    fi
}
