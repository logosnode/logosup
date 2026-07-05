#!/usr/bin/env bash
# DESCRIPTION: View Logos Node logs

_logs_help() {
    echo ""
    log_step "Logos Node logs"
    echo ""
    log_info "${BOLD}Usage:${RESET}"
    log_info "  logosup logs [OPTIONS]"
    echo ""
    log_info "${BOLD}Options:${RESET}"
    log_info "  -n, --lines N       Last N lines per container (default: 10)"
    log_info "  --no-follow         Don't tail; print and exit"
    log_info "  --all               Include monitoring stack (grafana, prometheus, exporter, otel)"
    log_info "  --node-only         Only node container (default when monitoring not deployed)"
    log_info "  -h, --help          Show this message"
    echo ""
    log_info "${BOLD}Examples:${RESET}"
    log_info "  logosup logs                 # last 10 lines then tail"
    log_info "  logosup logs -n 100          # last 100 lines then tail"
    log_info "  logosup logs -n 50 --all     # node + monitoring"
    log_info "  logosup logs --no-follow     # just dump the last 10 and exit"
    echo ""
    log_dim "Any other flags after -- pass through to \`docker compose logs\`,"
    log_dim "e.g. logosup logs -- --since=10m --timestamps"
    echo ""
}

cmd_logs() {
    detect_platform
    check_docker

    local tail_count=10
    local follow=true
    local include_monitoring=false
    local node_only=false
    local passthrough=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--lines|--tail)
                tail_count="${2:-10}"
                shift 2
                ;;
            --tail=*|--lines=*)
                tail_count="${1#*=}"
                shift
                ;;
            --no-follow)
                follow=false
                shift
                ;;
            -f|--follow)
                follow=true
                shift
                ;;
            --all|-a)
                include_monitoring=true
                shift
                ;;
            --node-only)
                node_only=true
                shift
                ;;
            -h|--help|help)
                _logs_help
                return 0
                ;;
            --)
                shift
                passthrough+=("$@")
                break
                ;;
            *)
                # Legacy: allow bare passthrough for backwards compat
                passthrough+=("$1")
                shift
                ;;
        esac
    done

    if ! docker_is_running; then
        log_warn "Logos Node is not running"
        log_info "Showing last available logs..."
        echo ""
    fi

    # Build compose file list. Default: node only. --all includes monitoring
    # if the monitoring compose was ever generated (regardless of whether the
    # stack is currently up — down containers still have logs).
    local -a compose_files
    compose_files=("-f" "$(get_compose_path)")
    local monitoring_compose
    monitoring_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
    if $include_monitoring && ! $node_only && [[ -f "$monitoring_compose" ]]; then
        compose_files+=("-f" "$monitoring_compose")
    fi

    local -a args=("--tail=$tail_count")
    $follow && args+=("-f")
    args+=("${passthrough[@]}")

    COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE "${compose_files[@]}" logs "${args[@]}"
}
