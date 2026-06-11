#!/usr/bin/env bash
# DESCRIPTION: Security hardening — firewall, SSH, auto-updates, fail2ban

cmd_security() {
    local subcmd="${1:-scan}"
    shift 2>/dev/null || true

    case "$subcmd" in
        scan|"")    _security_scan ;;
        apply)      _security_apply ;;
        -h|--help|help) _security_help ;;
        *)
            log_error "Unknown security subcommand: $subcmd"
            _security_help
            return 1
            ;;
    esac
}

_security_help() {
    echo ""
    log_step "Server security hardening"
    echo ""
    log_info "${BOLD}Usage:${RESET}"
    log_info "  logosup security              Scan and report security findings"
    log_info "  logosup security apply         Apply recommended fixes (interactive)"
    echo ""
    log_info "${BOLD}Checks:${RESET}"
    log_info "  Firewall (UFW/firewalld)         Ensure firewall is active with correct ports"
    log_info "  SSH hardening                    Disable root login, check key-based auth"
    log_info "  Automatic security updates       Enable unattended upgrades"
    log_info "  fail2ban                         Brute-force protection for SSH"
    log_info "  File permissions                 Node data directory & Docker socket"
    echo ""
}

# ── Distro detection ─────────────────────────────────────────────────

_detect_distro() {
    DISTRO=""
    DISTRO_FAMILY=""
    PKG_MANAGER=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO="${ID:-unknown}"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="rhel"
    fi

    case "$DISTRO" in
        ubuntu|debian|raspbian|linuxmint|pop)
            DISTRO_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        fedora|rhel|centos|rocky|alma|ol)
            DISTRO_FAMILY="rhel"
            PKG_MANAGER="dnf"
            # CentOS 7 / older may only have yum
            if ! command -v dnf &>/dev/null && command -v yum &>/dev/null; then
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros)
            DISTRO_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse*|sles)
            DISTRO_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            DISTRO_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            DISTRO_FAMILY="unknown"
            ;;
    esac
}

# ── Check helpers ────────────────────────────────────────────────────

# Each check sets:  STATUS (pass/warn/fail), DETAIL (description)
# and appends to FINDINGS array

declare -a FINDINGS=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

_add_finding() {
    local status="$1"   # pass, warn, fail
    local label="$2"
    local detail="$3"

    case "$status" in
        pass) FINDINGS+=("${GREEN}✔${RESET}  ${label}: ${detail}"); PASS_COUNT=$((PASS_COUNT + 1)) ;;
        warn) FINDINGS+=("${YELLOW}⚠${RESET}  ${label}: ${detail}"); WARN_COUNT=$((WARN_COUNT + 1)) ;;
        fail) FINDINGS+=("${RED}✖${RESET}  ${label}: ${detail}"); FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

# ── Individual checks ────────────────────────────────────────────────

_check_firewall() {
    if command -v ufw &>/dev/null; then
        FIREWALL_TYPE="ufw"
        local status
        status="$(sudo ufw status 2>/dev/null)" || status=""
        if echo "$status" | grep -q "Status: active"; then
            _add_finding "pass" "Firewall (UFW)" "active"
            # Check if our ports are allowed
            local missing_ports=()
            if ! echo "$status" | grep -q "22/tcp"; then
                if ! echo "$status" | grep -q "22 "; then
                    missing_ports+=("22/tcp (SSH)")
                fi
            fi
            if ! echo "$status" | grep -q "${LOGOS_UDP_PORT}/udp"; then
                missing_ports+=("${LOGOS_UDP_PORT}/udp (Node P2P)")
            fi
            # Check service ports if those services are running
            if docker_is_running 2>/dev/null; then
                if ! echo "$status" | grep -q "${LOGOS_API_PORT}"; then
                    missing_ports+=("${LOGOS_API_PORT}/tcp (Node API)")
                fi
            fi
            if [[ -f "$LOGOS_NODE_DIR/docker-compose.monitoring.yml" ]]; then
                source "$LOGOS_NODE_LIB/monitoring.sh" 2>/dev/null || true
                if monitoring_is_running 2>/dev/null; then
                    if ! echo "$status" | grep -q "${LOGOS_GRAFANA_PORT}"; then
                        missing_ports+=("${LOGOS_GRAFANA_PORT}/tcp (Grafana)")
                    fi
                fi
            fi
            if [[ ${#missing_ports[@]} -gt 0 ]]; then
                _add_finding "warn" "Firewall ports" "missing: ${missing_ports[*]}"
            else
                _add_finding "pass" "Firewall ports" "all required ports allowed"
            fi
        else
            _add_finding "fail" "Firewall (UFW)" "installed but inactive"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        FIREWALL_TYPE="firewalld"
        if sudo firewall-cmd --state &>/dev/null 2>&1; then
            _add_finding "pass" "Firewall (firewalld)" "active"
        else
            _add_finding "fail" "Firewall (firewalld)" "installed but inactive"
        fi
    else
        FIREWALL_TYPE="none"
        _add_finding "fail" "Firewall" "no firewall installed (ufw or firewalld)"
    fi
}

_check_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        _add_finding "warn" "SSH" "sshd_config not found (SSH may not be installed)"
        return
    fi

    # Check root login
    local root_login
    root_login="$(grep -i "^PermitRootLogin" "$sshd_config" 2>/dev/null | awk '{print $2}')" || true
    # Also check sshd_config.d/ drop-ins
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local dropin_root
        dropin_root="$(grep -rhi "^PermitRootLogin" /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print $2}')" || true
        [[ -n "$dropin_root" ]] && root_login="$dropin_root"
    fi

    case "${root_login,,}" in
        no)              _add_finding "pass" "SSH root login" "disabled" ;;
        prohibit-password|forced-commands-only)
                         _add_finding "pass" "SSH root login" "key-only (${root_login})" ;;
        yes|"")          _add_finding "warn" "SSH root login" "enabled (${root_login:-default})" ;;
        *)               _add_finding "warn" "SSH root login" "unknown setting: $root_login" ;;
    esac

    # Check password authentication
    local pass_auth
    pass_auth="$(grep -i "^PasswordAuthentication" "$sshd_config" 2>/dev/null | awk '{print $2}')" || true
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local dropin_pass
        dropin_pass="$(grep -rhi "^PasswordAuthentication" /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print $2}')" || true
        [[ -n "$dropin_pass" ]] && pass_auth="$dropin_pass"
    fi

    case "${pass_auth,,}" in
        no)     _add_finding "pass" "SSH password auth" "disabled (key-only)" ;;
        yes|"") _add_finding "warn" "SSH password auth" "enabled — consider key-only access" ;;
        *)      _add_finding "warn" "SSH password auth" "unknown: $pass_auth" ;;
    esac

    # Check if any authorized_keys exist for current user (safety check before disabling passwords)
    if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -s "$HOME/.ssh/authorized_keys" ]]; then
        _add_finding "pass" "SSH authorized keys" "found for current user"
        SSH_HAS_KEYS=true
    else
        _add_finding "warn" "SSH authorized keys" "none found — add your public key before disabling password auth"
        SSH_HAS_KEYS=false
    fi
}

_check_auto_updates() {
    case "$DISTRO_FAMILY" in
        debian)
            if dpkg -l unattended-upgrades &>/dev/null 2>&1 && \
               [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
                local enabled
                enabled="$(grep -c 'APT::Periodic::Unattended-Upgrade.*"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)" || enabled=0
                if [[ "$enabled" -gt 0 ]]; then
                    _add_finding "pass" "Auto security updates" "unattended-upgrades active"
                else
                    _add_finding "warn" "Auto security updates" "unattended-upgrades installed but not enabled"
                fi
            else
                _add_finding "fail" "Auto security updates" "unattended-upgrades not installed"
            fi
            ;;
        rhel)
            if command -v dnf &>/dev/null && dnf list installed dnf-automatic &>/dev/null 2>&1; then
                if systemctl is-active dnf-automatic.timer &>/dev/null; then
                    _add_finding "pass" "Auto security updates" "dnf-automatic active"
                else
                    _add_finding "warn" "Auto security updates" "dnf-automatic installed but timer not active"
                fi
            else
                _add_finding "fail" "Auto security updates" "dnf-automatic not installed"
            fi
            ;;
        arch)
            _add_finding "warn" "Auto security updates" "Arch Linux — manual updates recommended (pacman -Syu)"
            ;;
        *)
            _add_finding "warn" "Auto security updates" "cannot detect for $DISTRO"
            ;;
    esac
}

_check_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active fail2ban &>/dev/null 2>&1; then
            local jails
            jails="$(sudo fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*:\s*//')" || jails=""
            if echo "$jails" | grep -q "sshd"; then
                _add_finding "pass" "fail2ban" "active with sshd jail"
            else
                _add_finding "warn" "fail2ban" "active but no sshd jail"
            fi
        else
            _add_finding "warn" "fail2ban" "installed but not running"
        fi
    else
        _add_finding "fail" "fail2ban" "not installed"
    fi
}

_check_permissions() {
    # Node data directory
    if [[ -d "$LOGOS_NODE_DIR" ]]; then
        local perms
        perms="$(stat -c '%a' "$LOGOS_NODE_DIR" 2>/dev/null || stat -f '%Lp' "$LOGOS_NODE_DIR" 2>/dev/null)" || perms=""
        if [[ "$perms" == "700" ]]; then
            _add_finding "pass" "Node directory permissions" "$LOGOS_NODE_DIR ($perms)"
        else
            _add_finding "warn" "Node directory permissions" "$LOGOS_NODE_DIR ($perms) — should be 700"
        fi
    fi

    # Docker socket
    if [[ -S /var/run/docker.sock ]]; then
        local sock_perms
        sock_perms="$(stat -c '%a' /var/run/docker.sock 2>/dev/null || stat -f '%Lp' /var/run/docker.sock 2>/dev/null)" || sock_perms=""
        local sock_group
        sock_group="$(stat -c '%G' /var/run/docker.sock 2>/dev/null || stat -f '%Sg' /var/run/docker.sock 2>/dev/null)" || sock_group=""
        if [[ "$sock_perms" == "660" ]] || [[ "$sock_perms" == "770" ]]; then
            _add_finding "pass" "Docker socket" "permissions $sock_perms, group: $sock_group"
        else
            _add_finding "warn" "Docker socket" "permissions $sock_perms (expected 660 or 770)"
        fi
    fi
}

# Flag ufw-docker presence when the bridged monitoring stack is installed. The
# node itself uses host networking on Linux (so its QUIC port is unaffected by
# ufw-docker's DOCKER-USER UDP drops), but Grafana stays on the bridge — and
# ufw-docker will block LAN access to it until the operator allows the port
# explicitly. Warn-only; no auto-apply, since `ufw-docker allow` needs root
# and the exact command is operator-environment specific.
_check_ufw_docker() {
    [[ "$LOGOS_OS" == "linux" ]] || return 0

    # The ufw-docker shell helper edits /etc/ufw/after.rules; the binary itself
    # may not stick around in PATH after install. Match either signal.
    local has_rules=false has_bin=false
    grep -qE '^-A DOCKER-USER' /etc/ufw/after.rules 2>/dev/null && has_rules=true
    command -v ufw-docker &>/dev/null && has_bin=true
    [[ "$has_rules" == "false" && "$has_bin" == "false" ]] && return 0

    # Only warn when there's actually a bridged surface affected. Gate on the
    # monitoring compose existing on disk, not on the stack running — the
    # block applies regardless of whether Grafana is currently up.
    local mon_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
    [[ -f "$mon_compose" ]] || return 0

    _add_finding "warn" "ufw-docker" \
        "detected — may block LAN access to Grafana (${LOGOS_GRAFANA_PORT}/tcp). Allow with: sudo ufw-docker allow logos-grafana 3000/tcp"
}

# ── Scan (report only) ──────────────────────────────────────────────

_security_scan() {
    detect_platform
    if [[ "$LOGOS_OS" != "linux" ]]; then
        log_info "Security hardening is designed for Linux servers."
        log_info "Your platform (${LOGOS_OS}) manages security differently."
        return 0
    fi

    _detect_distro

    log_step "Security scan"
    log_info "Distro: ${BOLD}${DISTRO}${RESET} (${DISTRO_FAMILY})"
    echo ""

    FINDINGS=()
    PASS_COUNT=0
    WARN_COUNT=0
    FAIL_COUNT=0
    FIREWALL_TYPE=""
    SSH_HAS_KEYS=false

    _check_firewall
    _check_ssh
    _check_auto_updates
    _check_fail2ban
    _check_permissions
    _check_ufw_docker

    # Print findings
    for finding in "${FINDINGS[@]}"; do
        echo -e "  $finding"
    done

    echo ""
    print_separator
    log_info "Results: ${GREEN}${PASS_COUNT} passed${RESET}, ${YELLOW}${WARN_COUNT} warnings${RESET}, ${RED}${FAIL_COUNT} issues${RESET}"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]] || [[ $WARN_COUNT -gt 0 ]]; then
        log_info "Run ${BOLD}logosup security apply${RESET} to fix issues interactively"
        echo ""
    fi
}

# ── Apply (interactive) ─────────────────────────────────────────────

_security_apply() {
    detect_platform
    if [[ "$LOGOS_OS" != "linux" ]]; then
        log_info "Security hardening is designed for Linux servers."
        return 0
    fi

    _detect_distro

    log_step "Security hardening"
    log_info "Distro: ${BOLD}${DISTRO}${RESET} (${DISTRO_FAMILY})"
    log_info "Each fix will ask for confirmation before applying."
    echo ""

    # Reset state
    FINDINGS=()
    PASS_COUNT=0
    WARN_COUNT=0
    FAIL_COUNT=0
    FIREWALL_TYPE=""
    SSH_HAS_KEYS=false

    # Run scan first to populate state
    _check_firewall
    _check_ssh
    _check_auto_updates
    _check_fail2ban
    _check_permissions
    _check_ufw_docker

    # ufw-docker finding is informational — surface it up-front so the operator
    # sees it before the interactive prompts. No corresponding _apply step;
    # the suggested command needs root and is environment-specific.
    for finding in "${FINDINGS[@]}"; do
        if [[ "$finding" == *"ufw-docker"* ]]; then
            echo -e "  $finding"
            echo ""
            break
        fi
    done

    local changes_made=0

    # ── Firewall ──────────────────────────────────────────────────────
    _apply_firewall && ((changes_made++)) || true

    # ── SSH hardening ─────────────────────────────────────────────────
    _apply_ssh && ((changes_made++)) || true

    # ── Auto updates ──────────────────────────────────────────────────
    _apply_auto_updates && ((changes_made++)) || true

    # ── fail2ban ──────────────────────────────────────────────────────
    _apply_fail2ban && ((changes_made++)) || true

    # ── Permissions ───────────────────────────────────────────────────
    _apply_permissions && ((changes_made++)) || true

    echo ""
    print_separator
    if [[ $changes_made -gt 0 ]]; then
        log_success "Security hardening complete ($changes_made changes applied)"
    else
        log_success "No changes needed — your server is already well configured"
    fi
    echo ""

    # Re-run scan to show final state
    log_step "Updated security status"
    echo ""
    FINDINGS=()
    PASS_COUNT=0
    WARN_COUNT=0
    FAIL_COUNT=0
    _check_firewall
    _check_ssh
    _check_auto_updates
    _check_fail2ban
    _check_permissions
    for finding in "${FINDINGS[@]}"; do
        echo -e "  $finding"
    done
    echo ""
    log_info "Results: ${GREEN}${PASS_COUNT} passed${RESET}, ${YELLOW}${WARN_COUNT} warnings${RESET}, ${RED}${FAIL_COUNT} issues${RESET}"
    echo ""
}

# ── Apply: Firewall ──────────────────────────────────────────────────

_apply_firewall() {
    print_separator
    log_step "Firewall"

    if [[ "$FIREWALL_TYPE" == "ufw" ]]; then
        local status
        status="$(sudo ufw status 2>/dev/null)" || status=""
        if echo "$status" | grep -q "Status: active"; then
            log_success "UFW is already active"
            _apply_firewall_ports
            return 0
        fi

        echo ""
        log_info "UFW will be configured with the following rules:"
        log_info "  • Allow SSH (port 22/tcp)"
        log_info "  • Allow Node P2P (port ${LOGOS_UDP_PORT}/udp)"
        _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Access node status from your local network"
        _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Access monitoring dashboard from your local network"
        log_info "  • Default: deny all other incoming traffic"
        echo ""

        if confirm "Enable UFW firewall with these rules?"; then
            sudo ufw default deny incoming
            sudo ufw default allow outgoing
            sudo ufw allow 22/tcp comment "SSH"
            sudo ufw allow "${LOGOS_UDP_PORT}/udp" comment "Logos Node P2P"
            _apply_optional_ports
            sudo ufw --force enable
            log_success "UFW enabled"
            return 0
        else
            log_info "Skipped firewall"
            return 1
        fi

    elif [[ "$FIREWALL_TYPE" == "firewalld" ]]; then
        if sudo firewall-cmd --state &>/dev/null 2>&1; then
            log_success "firewalld is already active"
            return 0
        fi
        if confirm "Enable firewalld?"; then
            sudo systemctl enable --now firewalld
            sudo firewall-cmd --permanent --add-service=ssh
            sudo firewall-cmd --permanent --add-port="${LOGOS_UDP_PORT}/udp"
            _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Access node status from your local network"
            _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Access monitoring dashboard from your local network"
            _apply_optional_ports_firewalld
            sudo firewall-cmd --reload
            log_success "firewalld enabled"
            return 0
        else
            log_info "Skipped firewall"
            return 1
        fi

    else
        # No firewall installed — install one
        case "$DISTRO_FAMILY" in
            debian)
                log_info "No firewall detected."
                if confirm "Install and enable UFW?"; then
                    sudo apt-get update -qq && sudo apt-get install -y -qq ufw
                    FIREWALL_TYPE="ufw"
                    sudo ufw default deny incoming
                    sudo ufw default allow outgoing
                    sudo ufw allow 22/tcp comment "SSH"
                    sudo ufw allow "${LOGOS_UDP_PORT}/udp" comment "Logos Node P2P"
                    _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Access node status from your local network"
                    _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Access monitoring dashboard from your local network"
                    _apply_optional_ports
                    sudo ufw --force enable
                    log_success "UFW installed and enabled"
                    return 0
                fi
                ;;
            rhel)
                log_info "No firewall detected."
                if confirm "Install and enable firewalld?"; then
                    sudo "$PKG_MANAGER" install -y -q firewalld
                    FIREWALL_TYPE="firewalld"
                    sudo systemctl enable --now firewalld
                    sudo firewall-cmd --permanent --add-service=ssh
                    sudo firewall-cmd --permanent --add-port="${LOGOS_UDP_PORT}/udp"
                    _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Access node status from your local network"
                    _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Access monitoring dashboard from your local network"
                    _apply_optional_ports_firewalld
                    sudo firewall-cmd --reload
                    log_success "firewalld installed and enabled"
                    return 0
                fi
                ;;
            arch)
                log_info "No firewall detected."
                if confirm "Install and enable UFW?"; then
                    sudo pacman -S --noconfirm ufw
                    FIREWALL_TYPE="ufw"
                    sudo ufw default deny incoming
                    sudo ufw default allow outgoing
                    sudo ufw allow 22/tcp comment "SSH"
                    sudo ufw allow "${LOGOS_UDP_PORT}/udp" comment "Logos Node P2P"
                    _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Access node status from your local network"
                    _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Access monitoring dashboard from your local network"
                    _apply_optional_ports
                    sudo ufw --force enable
                    log_success "UFW installed and enabled"
                    return 0
                fi
                ;;
            *)
                log_warn "Cannot auto-install firewall for $DISTRO. Please install one manually."
                ;;
        esac
        return 1
    fi
}

# Track optional ports to add
declare -a OPTIONAL_PORTS=()

_ask_optional_port() {
    local name="$1"
    local port="$2"
    local proto="$3"
    local desc="$4"

    echo ""
    log_info "${desc}"
    if confirm "  Allow ${name} (port ${port}/${proto}) through firewall?" "n"; then
        OPTIONAL_PORTS+=("${port}/${proto}:${name}")
        log_info "  • Allow ${name} (port ${port}/${proto})"
    else
        log_dim "  Skipping ${name} — only accessible from localhost"
    fi
}

_apply_optional_ports() {
    for entry in "${OPTIONAL_PORTS[@]}"; do
        local port_proto="${entry%%:*}"
        local name="${entry#*:}"
        sudo ufw allow "$port_proto" comment "$name"
    done
    OPTIONAL_PORTS=()
}

_apply_optional_ports_firewalld() {
    for entry in "${OPTIONAL_PORTS[@]}"; do
        local port_proto="${entry%%:*}"
        sudo firewall-cmd --permanent --add-port="$port_proto"
    done
    OPTIONAL_PORTS=()
}

_apply_firewall_ports() {
    local status
    status="$(sudo ufw status 2>/dev/null)" || return 0

    # Core ports
    local missing_core=false
    if ! echo "$status" | grep -q "22"; then
        missing_core=true
    fi
    if ! echo "$status" | grep -q "${LOGOS_UDP_PORT}/udp"; then
        missing_core=true
    fi

    if [[ "$missing_core" == "true" ]]; then
        if confirm "Add missing firewall rules for SSH and Node P2P?"; then
            sudo ufw allow 22/tcp comment "SSH"
            sudo ufw allow "${LOGOS_UDP_PORT}/udp" comment "Logos Node P2P"
            log_success "Core firewall rules updated"
        fi
    fi

    # Service ports — check running services and offer to open their ports
    if docker_is_running 2>/dev/null && ! echo "$status" | grep -q "${LOGOS_API_PORT}"; then
        _ask_optional_port "Node API" "${LOGOS_API_PORT}" "tcp" "Node is running but API port is blocked from network"
    fi

    if [[ -f "$LOGOS_NODE_DIR/docker-compose.monitoring.yml" ]]; then
        source "$LOGOS_NODE_LIB/monitoring.sh" 2>/dev/null || true
        if monitoring_is_running 2>/dev/null && ! echo "$status" | grep -q "${LOGOS_GRAFANA_PORT}"; then
            _ask_optional_port "Grafana" "${LOGOS_GRAFANA_PORT}" "tcp" "Monitoring is running but Grafana port is blocked from network"
        fi
    fi

    if [[ ${#OPTIONAL_PORTS[@]} -gt 0 ]]; then
        _apply_optional_ports
        log_success "Service firewall rules updated"
    fi
}

# ── Apply: SSH ───────────────────────────────────────────────────────

_apply_ssh() {
    print_separator
    log_step "SSH hardening"

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        log_info "SSH server not found — skipping"
        return 1
    fi

    local changed=false

    # Root login
    local root_login
    root_login="$(grep -i "^PermitRootLogin" "$sshd_config" 2>/dev/null | awk '{print $2}')" || true
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local dropin
        dropin="$(grep -rhi "^PermitRootLogin" /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print $2}')" || true
        [[ -n "$dropin" ]] && root_login="$dropin"
    fi

    case "${root_login,,}" in
        no|prohibit-password|forced-commands-only)
            log_success "Root login already restricted (${root_login})"
            ;;
        *)
            log_warn "Root login is ${root_login:-enabled (default)}"
            if confirm "Disable root SSH login? (set to 'prohibit-password')"; then
                if grep -q "^PermitRootLogin" "$sshd_config"; then
                    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
                elif grep -q "^#PermitRootLogin" "$sshd_config"; then
                    sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
                else
                    echo "PermitRootLogin prohibit-password" | sudo tee -a "$sshd_config" > /dev/null
                fi
                changed=true
                log_success "Root login set to prohibit-password"
            fi
            ;;
    esac

    # Password auth — only offer to disable if user has authorized_keys
    local pass_auth
    pass_auth="$(grep -i "^PasswordAuthentication" "$sshd_config" 2>/dev/null | awk '{print $2}')" || true
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local dropin_pass
        dropin_pass="$(grep -rhi "^PasswordAuthentication" /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print $2}')" || true
        [[ -n "$dropin_pass" ]] && pass_auth="$dropin_pass"
    fi

    case "${pass_auth,,}" in
        no)
            log_success "Password authentication already disabled"
            ;;
        *)
            if [[ "$SSH_HAS_KEYS" == "true" ]]; then
                log_warn "Password authentication is enabled"
                log_info "You have SSH keys configured, so key-only access is safe."
                if confirm "Disable SSH password authentication? (key-only login)" "n"; then
                    if grep -q "^PasswordAuthentication" "$sshd_config"; then
                        sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
                    elif grep -q "^#PasswordAuthentication" "$sshd_config"; then
                        sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
                    else
                        echo "PasswordAuthentication no" | sudo tee -a "$sshd_config" > /dev/null
                    fi
                    changed=true
                    log_success "Password authentication disabled"
                fi
            else
                log_warn "Password authentication is enabled"
                log_warn "No SSH keys found — ${BOLD}add your public key before disabling password auth${RESET}"
                log_info "  ssh-copy-id $(whoami)@$(hostname)"
                log_info "  Then re-run: logosup security apply"
            fi
            ;;
    esac

    # Restart SSH if changes were made
    if [[ "$changed" == "true" ]]; then
        log_info "Restarting SSH service..."
        if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
            log_success "SSH service restarted"
        else
            log_warn "Could not restart SSH — changes will apply on next reboot"
        fi
        return 0
    fi
    return 1
}

# ── Apply: Auto updates ─────────────────────────────────────────────

_apply_auto_updates() {
    print_separator
    log_step "Automatic security updates"

    case "$DISTRO_FAMILY" in
        debian)
            if dpkg -l unattended-upgrades &>/dev/null 2>&1; then
                local enabled
                enabled="$(grep -c 'APT::Periodic::Unattended-Upgrade.*"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)" || enabled=0
                if [[ "$enabled" -gt 0 ]]; then
                    log_success "Unattended upgrades already active"
                    return 1
                fi
                if confirm "Enable unattended security upgrades?"; then
                    sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
                    log_success "Unattended upgrades enabled"
                    return 0
                fi
            else
                if confirm "Install and enable unattended-upgrades?"; then
                    sudo apt-get update -qq && sudo apt-get install -y -qq unattended-upgrades
                    sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
                    log_success "Unattended upgrades installed and enabled"
                    return 0
                fi
            fi
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                if dnf list installed dnf-automatic &>/dev/null 2>&1; then
                    if systemctl is-active dnf-automatic.timer &>/dev/null; then
                        log_success "dnf-automatic already active"
                        return 1
                    fi
                    if confirm "Enable dnf-automatic timer?"; then
                        sudo systemctl enable --now dnf-automatic.timer
                        log_success "dnf-automatic timer enabled"
                        return 0
                    fi
                else
                    if confirm "Install and enable dnf-automatic?"; then
                        sudo dnf install -y -q dnf-automatic
                        sudo systemctl enable --now dnf-automatic.timer
                        log_success "dnf-automatic installed and enabled"
                        return 0
                    fi
                fi
            fi
            ;;
        arch)
            log_info "Arch Linux does not have unattended upgrades."
            log_info "Run ${BOLD}sudo pacman -Syu${RESET} regularly to stay updated."
            return 1
            ;;
        *)
            log_warn "Auto-update setup not supported for $DISTRO"
            return 1
            ;;
    esac
    return 1
}

# ── Apply: fail2ban ──────────────────────────────────────────────────

_apply_fail2ban() {
    print_separator
    log_step "fail2ban (SSH brute-force protection)"

    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active fail2ban &>/dev/null 2>&1; then
            log_success "fail2ban already running"
            return 1
        fi
        if confirm "Start fail2ban?"; then
            sudo systemctl enable --now fail2ban
            log_success "fail2ban started"
            return 0
        fi
    else
        case "$DISTRO_FAMILY" in
            debian)
                if confirm "Install and enable fail2ban?"; then
                    sudo apt-get update -qq && sudo apt-get install -y -qq fail2ban
                    # Create basic sshd jail config
                    sudo tee /etc/fail2ban/jail.local > /dev/null << 'JAIL'
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
bantime = 3600
findtime = 600
JAIL
                    sudo systemctl enable --now fail2ban
                    log_success "fail2ban installed and enabled with sshd jail"
                    return 0
                fi
                ;;
            rhel)
                if confirm "Install and enable fail2ban?"; then
                    sudo "$PKG_MANAGER" install -y -q epel-release 2>/dev/null || true
                    sudo "$PKG_MANAGER" install -y -q fail2ban
                    sudo tee /etc/fail2ban/jail.local > /dev/null << 'JAIL'
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
bantime = 3600
findtime = 600
JAIL
                    sudo systemctl enable --now fail2ban
                    log_success "fail2ban installed and enabled"
                    return 0
                fi
                ;;
            arch)
                if confirm "Install and enable fail2ban?"; then
                    sudo pacman -S --noconfirm fail2ban
                    sudo tee /etc/fail2ban/jail.local > /dev/null << 'JAIL'
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
bantime = 3600
findtime = 600
JAIL
                    sudo systemctl enable --now fail2ban
                    log_success "fail2ban installed and enabled"
                    return 0
                fi
                ;;
            *)
                log_warn "Cannot auto-install fail2ban for $DISTRO"
                ;;
        esac
    fi
    return 1
}

# ── Apply: Permissions ───────────────────────────────────────────────

_apply_permissions() {
    print_separator
    log_step "File permissions"

    local changed=false

    if [[ -d "$LOGOS_NODE_DIR" ]]; then
        local perms
        perms="$(stat -c '%a' "$LOGOS_NODE_DIR" 2>/dev/null || stat -f '%Lp' "$LOGOS_NODE_DIR" 2>/dev/null)" || perms=""
        if [[ "$perms" != "700" ]]; then
            if confirm "Fix node directory permissions? ($perms → 700)"; then
                chmod 700 "$LOGOS_NODE_DIR"
                log_success "Node directory permissions set to 700"
                changed=true
            fi
        else
            log_success "Node directory permissions OK (700)"
        fi
    fi

    if [[ "$changed" == "true" ]]; then
        return 0
    fi
    return 1
}
