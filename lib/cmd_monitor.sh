#!/usr/bin/env bash
# DESCRIPTION: Manage the monitoring dashboard (Grafana + Prometheus)

cmd_monitor() {
    detect_platform
    check_docker

    source "$LOGOS_NODE_LIB/monitoring.sh"

    local subcmd="${1:-start}"
    shift 2>/dev/null || true

    case "$subcmd" in
        start)
            _monitor_start
            ;;
        stop)
            _monitor_stop
            ;;
        status)
            _monitor_status
            ;;
        auth)
            _monitor_auth "$@"
            ;;
        -h|--help|help)
            _monitor_help
            ;;
        *)
            log_error "Unknown monitor subcommand: $subcmd"
            _monitor_help
            return 1
            ;;
    esac
}

_monitor_help() {
    echo ""
    log_step "Monitoring dashboard management"
    echo ""
    log_info "${BOLD}Usage:${RESET}"
    log_info "  logosup monitor [start|stop|status|auth]"
    echo ""
    log_info "${BOLD}Commands:${RESET}"
    log_info "  start    Start the monitoring stack (Grafana + Prometheus + exporter)"
    log_info "  stop     Stop the monitoring stack"
    log_info "  status   Show monitoring status and Grafana URL"
    log_info "  auth     Enable or disable Grafana login (set password)"
    echo ""
    log_info "Grafana will be available at ${BOLD}https://localhost:${LOGOS_GRAFANA_PORT}${RESET}"
    if [[ "${LOGOS_GRAFANA_AUTH}" == "true" ]]; then
        log_info "Login: admin / ${BOLD}(your password)${RESET}"
    else
        log_info "No login required (anonymous access enabled)"
    fi
    echo ""
}

_monitor_start() {
    local compose_path
    compose_path="$(get_monitoring_compose_path)"

    # Always regenerate the monitoring compose. Skipping when the file
    # exists strands operators on stale layouts across CLI updates — the
    # most recent breakage was a pre-a2db098 file declaring logosnode-net
    # as `external: true`, which the new CLI (compose-managed) can't
    # bring up. The compose is fully derived from lib/monitoring.sh; the
    # regen is cheap and always correct.
    generate_monitoring_compose_file

    # Build and start
    monitoring_build || die "Failed to build monitoring containers"
    monitoring_up

    echo ""
    log_success "Monitoring stack started"
    echo ""
    local grafana_host
    grafana_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    grafana_host="${grafana_host:-localhost}"
    log_info "Grafana: ${BOLD}https://${grafana_host}:${LOGOS_GRAFANA_PORT}${RESET}"
    if [[ "${LOGOS_GRAFANA_AUTH}" == "true" ]]; then
        log_info "Login: admin / ${BOLD}(your password)${RESET}"
    else
        log_info "No login required to view dashboards"
    fi
    log_dim "Self-signed cert — accept the browser warning on first visit"
    echo ""
    log_info "Stop with: ${BOLD}logosup monitor stop${RESET}"
    echo ""
}

_monitor_stop() {
    if ! monitoring_is_running; then
        log_info "Monitoring stack is not running"
        return 0
    fi

    log_step "Stopping monitoring stack..."
    monitoring_down
    log_success "Monitoring stack stopped"
}

_monitor_status() {
    print_banner

    log_step "Monitoring"

    local containers=("logos-exporter" "logos-prometheus" "logos-grafana")
    local all_running=true

    for name in "${containers[@]}"; do
        local status
        status="$($DOCKER_CMD ps --filter "name=${name}" --format '{{.Status}}' 2>/dev/null)"
        if [[ -n "$status" ]]; then
            log_success "${name}: ${status}"
        else
            log_error "${name}: not running"
            all_running=false
        fi
    done

    echo ""
    if [[ "$all_running" == "true" ]]; then
        local grafana_host
        grafana_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
        grafana_host="${grafana_host:-localhost}"
        log_info "Grafana: ${BOLD}https://${grafana_host}:${LOGOS_GRAFANA_PORT}${RESET}"
    else
        log_info "Start with: ${BOLD}logosup monitor start${RESET}"
    fi
    echo ""
}

_monitor_auth() {
    local action="${1:-}"

    case "$action" in
        on|enable)
            _monitor_auth_enable
            ;;
        off|disable)
            _monitor_auth_disable
            ;;
        "")
            # Interactive — toggle based on current state
            if [[ "${LOGOS_GRAFANA_AUTH}" == "true" ]]; then
                log_info "Grafana authentication is currently ${BOLD}enabled${RESET}"
                echo ""
                if confirm "Disable authentication (allow anonymous access)?" "n"; then
                    _monitor_auth_disable
                else
                    log_info "Change password? Run: ${BOLD}logosup monitor auth on${RESET}"
                fi
            else
                log_info "Grafana authentication is currently ${BOLD}disabled${RESET} (anonymous access)"
                echo ""
                if confirm "Enable authentication (require login)?"; then
                    _monitor_auth_enable
                fi
            fi
            ;;
        *)
            log_info "${BOLD}Usage:${RESET}"
            log_info "  logosup monitor auth          Toggle authentication (interactive)"
            log_info "  logosup monitor auth on        Enable auth and set password"
            log_info "  logosup monitor auth off       Disable auth (anonymous access)"
            ;;
    esac
}

_monitor_auth_enable() {
    echo ""
    log_step "Set Grafana password"
    log_info "Username: ${BOLD}admin${RESET}"
    echo ""

    # Check if a password is already set
    local existing_password=""
    existing_password="$(grep '^LOGOS_GRAFANA_PASSWORD=' "$LOGOS_SETTINGS_FILE" 2>/dev/null | cut -d= -f2)" || true

    if [[ -n "$existing_password" && "$existing_password" != "logos" ]]; then
        log_info "A password is already configured."
        if ! confirm "Replace existing password?"; then
            # Keep existing password, just ensure auth is enabled
            save_setting "LOGOS_GRAFANA_AUTH" "true"
            export LOGOS_GRAFANA_AUTH="true"
            export LOGOS_GRAFANA_PASSWORD="$existing_password"
            log_success "Authentication enabled — login: ${BOLD}admin${RESET} / (existing password)"
            _monitor_restart_if_running
            return 0
        fi
    fi

    local password=""
    local password_confirm=""

    while true; do
        echo -en "${BOLD}?${RESET} Enter password: "
        read -rs password < /dev/tty 2>/dev/null || password=""
        echo ""

        if [[ -z "$password" ]]; then
            log_warn "Password cannot be empty"
            continue
        fi
        if [[ ${#password} -lt 4 ]]; then
            log_warn "Password must be at least 4 characters"
            continue
        fi

        echo -en "${BOLD}?${RESET} Confirm password: "
        read -rs password_confirm < /dev/tty 2>/dev/null || password_confirm=""
        echo ""

        if [[ "$password" != "$password_confirm" ]]; then
            log_warn "Passwords do not match"
            continue
        fi

        break
    done

    save_setting "LOGOS_GRAFANA_AUTH" "true"
    save_setting "LOGOS_GRAFANA_PASSWORD" "$password"
    export LOGOS_GRAFANA_AUTH="true"
    export LOGOS_GRAFANA_PASSWORD="$password"

    log_success "Authentication enabled — login: ${BOLD}admin${RESET} / (your password)"

    _monitor_restart_if_running
}

_monitor_auth_disable() {
    save_setting "LOGOS_GRAFANA_AUTH" "false"
    save_setting "LOGOS_GRAFANA_PASSWORD" "logos"
    export LOGOS_GRAFANA_AUTH="false"
    export LOGOS_GRAFANA_PASSWORD="logos"

    log_success "Authentication disabled — anonymous access enabled"

    _monitor_restart_if_running
}

_monitor_restart_if_running() {
    if monitoring_is_running; then
        echo ""
        log_info "Applying changes..."
        # Regenerate compose and force-recreate Grafana so new env vars take effect
        generate_monitoring_compose_file
        local compose_path
        compose_path="$(get_monitoring_compose_path)"
        COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE -f "$compose_path" up -d --force-recreate logos-grafana
        # Reset password inside running Grafana (env vars only apply on first boot)
        sleep 3
        $DOCKER_CMD exec logos-grafana grafana cli admin reset-admin-password "$LOGOS_GRAFANA_PASSWORD" &>/dev/null || true
        log_success "Monitoring stack restarted"
    else
        log_info "Changes will apply on next: ${BOLD}logosup monitor start${RESET}"
    fi
}
