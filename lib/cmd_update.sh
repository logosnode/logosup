#!/usr/bin/env bash
# DESCRIPTION: Update the Logos Node and/or CLI tool

# Heal CLI symlinks after the 0.4.0 rename (logos-node -> logosup).
# When git pull renames the dispatcher file, any /usr/local/bin/logos-node
# (or /logosnode) symlink dangles, and the operator's PATH-resolved CLI
# breaks. This recreates all three symlinks (logosup primary,
# logos-node + logosnode legacy aliases) pointing at the new file.
#
# Idempotent: only fires when cli_dir/logosup exists AND
# cli_dir/logos-node doesn't (i.e. the rename has happened in this clone).
_heal_cli_symlinks_after_rename() {
    local cli_dir="$1"
    [[ -f "$cli_dir/logosup" ]] || return 0
    [[ -f "$cli_dir/logos-node" ]] && return 0   # both names present, nothing to heal

    # Find where the operator's CLI symlinks live: prefer the dir of the
    # currently-active alias (whichever one they invoked us with), fall back
    # to standard locations.
    local heal_dir=""
    local active
    active="$(command -v logos-node 2>/dev/null)" || \
        active="$(command -v logosnode 2>/dev/null)" || \
        active="$(command -v logosup 2>/dev/null)" || true
    if [[ -n "$active" ]]; then
        heal_dir="$(dirname "$active")"
    else
        local d
        for d in /usr/local/bin "$HOME/.local/bin"; do
            [[ -d "$d" ]] && heal_dir="$d" && break
        done
    fi
    [[ -z "$heal_dir" ]] && return 0

    # Need heal if logosup is missing OR any old symlink dangles.
    local need_heal=false
    [[ -e "$heal_dir/logosup" ]] || need_heal=true
    local link
    for link in logos-node logosnode; do
        local p="$heal_dir/$link"
        if [[ -L "$p" ]] && [[ ! -e "$p" ]]; then
            need_heal=true
        fi
    done
    $need_heal || return 0

    log_info "Healing CLI symlinks in ${DIM}${heal_dir}${RESET} → ${BOLD}logosup${RESET}, ${DIM}logos-node${RESET}, ${DIM}logosnode${RESET}"
    local needs_sudo=false
    [[ -w "$heal_dir" ]] || needs_sudo=true
    for link in logosup logos-node logosnode; do
        if $needs_sudo && command -v sudo &>/dev/null; then
            sudo ln -sf "$cli_dir/logosup" "$heal_dir/$link" 2>/dev/null || true
        else
            ln -sf "$cli_dir/logosup" "$heal_dir/$link" 2>/dev/null || true
        fi
    done
}

cmd_update() {
    detect_platform
    check_docker
    load_config

    _offer_drift_cleanup

    local update_cli=false
    local update_node=false
    local branch=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--branch)
                branch="${2:-}"
                [[ -z "$branch" ]] && die "Missing branch name after $1"
                shift 2
                ;;
            cli)  update_cli=true; shift ;;
            node) update_node=true; shift ;;
            all)  update_cli=true; update_node=true; shift ;;
            -h|--help|help)
                log_info "Usage: logosup update [cli|node|all] [-b BRANCH]"
                log_info ""
                log_info "Options:"
                log_info "  -b, --branch BRANCH   Switch CLI to a specific git branch"
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_info "Usage: logosup update [cli|node|all] [-b BRANCH]"
                return 1
                ;;
        esac
    done

    # Default to updating everything
    if [[ "$update_cli" == "false" && "$update_node" == "false" ]]; then
        update_cli=true
        update_node=true
    fi

    print_banner

    local cli_updated=false
    local cli_changed_files=""

    # ── CLI update ────────────────────────────────────────────────────
    if [[ "$update_cli" == "true" ]]; then
        log_step "Checking for CLI updates..."

        local cli_dir="$LOGOS_NODE_DIR/cli"

        if [[ -d "$cli_dir/.git" ]]; then
            # Fix single-branch refspec from older installs (--depth 1 without --no-single-branch)
            local current_refspec
            current_refspec="$(git -C "$cli_dir" config remote.origin.fetch 2>/dev/null)" || true
            if [[ "$current_refspec" != "+refs/heads/*:refs/remotes/origin/*" ]]; then
                git -C "$cli_dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
            fi

            # Migrate git remote URL from the old `shayanb/logos-node` slug to
            # the new canonical `logosnode/logosup` if the operator's clone
            # still points at the old origin. GitHub redirects either form,
            # but rewriting locally removes the warnings and matches the
            # current repo identity.
            local current_url
            current_url="$(git -C "$cli_dir" remote get-url origin 2>/dev/null)" || true
            case "$current_url" in
                *shayanb/logos-node*)
                    local new_url="https://github.com/logosnode/logosup.git"
                    log_info "Migrating git remote: ${DIM}shayanb/logos-node${RESET} → ${BOLD}logosnode/logosup${RESET}"
                    git -C "$cli_dir" remote set-url origin "$new_url" 2>/dev/null \
                        || log_warn "Could not update remote URL — pull will still work via redirect"
                    ;;
            esac

            local before_sha
            before_sha="$(git -C "$cli_dir" rev-parse HEAD 2>/dev/null)"

            if [[ -n "$branch" ]]; then
                # Branch switch
                log_info "Switching to branch: ${BOLD}${branch}${RESET}"
                git -C "$cli_dir" fetch --all --quiet 2>/dev/null
                if git -C "$cli_dir" checkout "$branch" --quiet 2>/dev/null; then
                    git -C "$cli_dir" pull 2>/dev/null || true
                    log_success "CLI switched to branch ${BOLD}${branch}${RESET}"
                    # Show what changed between old and new branch
                    local after_sha
                    after_sha="$(git -C "$cli_dir" rev-parse HEAD 2>/dev/null)"
                    if [[ "$before_sha" != "$after_sha" ]]; then
                        git -C "$cli_dir" diff --stat "$before_sha" "$after_sha" 2>/dev/null
                    fi
                    cli_updated=true
                else
                    die "Branch '${branch}' not found"
                fi
            elif ! check_cli_update; then
                git -C "$cli_dir" pull
                log_success "CLI updated"
                cli_updated=true
            else
                log_success "CLI is up to date"
            fi

            # Track what changed
            if [[ "$cli_updated" == "true" ]]; then
                cli_changed_files="$(git -C "$cli_dir" diff --name-only "$before_sha" HEAD 2>/dev/null)" || true

                # If the dispatcher file was renamed in this pull (e.g.
                # logos-node -> logosup in 0.4.0), the old file is gone and
                # any /usr/local/bin/logos-node symlink now dangles.  Heal
                # the symlinks BEFORE the re-exec below so the operator's
                # PATH-resolved CLI keeps working.
                _heal_cli_symlinks_after_rename "$cli_dir"
            fi
        else
            log_dim "CLI not installed via git (skipping auto-update)"
        fi
    fi

    # If the CLI was updated AND we still need to do node work, re-exec so the
    # node update runs with the freshly-pulled code (otherwise the bash process
    # keeps using the old in-memory functions — e.g. a new is_breaking_version
    # entry on disk would never fire).
    if [[ "$cli_updated" == "true" && "$update_node" == "true" && -z "${LOGOS_UPDATE_REEXEC:-}" ]]; then
        # LOGOS_NODE_ENTRY was set at script start to the resolved-after-symlink
        # path of the dispatcher (e.g. ~/.logos-node/cli/logos-node). If the
        # pull just renamed that file (logos-node -> logosup), re-execing the
        # old path fails. Fall back to the new name in the same directory.
        local reexec_entry="$LOGOS_NODE_ENTRY"
        if [[ ! -f "$reexec_entry" ]]; then
            local reexec_dir
            reexec_dir="$(dirname "$reexec_entry")"
            if [[ -f "$reexec_dir/logosup" ]]; then
                reexec_entry="$reexec_dir/logosup"
            fi
        fi

        echo ""
        log_info "Re-running with updated CLI to apply node update..."
        export LOGOS_UPDATE_REEXEC=1
        # Pass cli_changed_files through the re-exec so post-update hooks
        # (compose regen, monitoring rebuild) can still fire in the new process.
        export LOGOS_UPDATE_REEXEC_CHANGED_FILES="$cli_changed_files"
        exec "$reexec_entry" update node
    fi

    # If we re-exec'd, restore the cli-updated state so post-update hooks fire.
    if [[ -n "${LOGOS_UPDATE_REEXEC:-}" && "$cli_updated" != "true" ]]; then
        cli_updated=true
        cli_changed_files="${LOGOS_UPDATE_REEXEC_CHANGED_FILES:-}"
    fi

    # ── Node update ───────────────────────────────────────────────────
    if [[ "$update_node" == "true" ]]; then
        log_step "Checking for node updates..."

        local current_version="$LOGOS_NODE_VERSION"
        fetch_latest_versions || die "Failed to fetch release information"

        if [[ "$LOGOS_NODE_VERSION" != "$current_version" ]]; then
            echo ""
            print_separator
            log_info "Update available:"
            log_info "  Current: ${BOLD}${current_version}${RESET}"
            log_info "  Latest:  ${BOLD}${LOGOS_NODE_VERSION}${RESET}"
            print_separator
            echo ""

            # Breaking-change releases (e.g. genesis reset) require wiping local
            # data and regenerating user_config.yaml. Divert to migration flow.
            if is_breaking_version "$LOGOS_NODE_VERSION"; then
                log_warn "${BOLD}Release ${LOGOS_NODE_VERSION} contains breaking changes${RESET} (new genesis block)."
                log_info "Migrating requires wiping local chain data and regenerating your config."
                log_info "Your current ${BOLD}user_config.yaml${RESET} will be backed up first."
                echo ""
                if confirm "Proceed with breaking-change migration to ${LOGOS_NODE_VERSION}?" "n"; then
                    save_setting "LOGOS_NODE_VERSION" "$LOGOS_NODE_VERSION"
                    generate_compose_file
                    source "$LOGOS_NODE_LIB/cmd_reset.sh"
                    _perform_migration "update" "true"
                    return 0
                else
                    log_info "Update cancelled — run later with: ${BOLD}logosup update${RESET}"
                    log_info "Or trigger the migration manually with: ${BOLD}logosup reset${RESET}"
                    return 0
                fi
            fi

            if confirm "Update to ${LOGOS_NODE_VERSION}?"; then
                local was_running=false
                if docker_is_running; then
                    was_running=true
                    log_step "Stopping current node..."
                    docker_down
                    log_success "Node stopped"
                fi

                save_setting "LOGOS_NODE_VERSION" "$LOGOS_NODE_VERSION"

                generate_compose_file
                docker_build || die "Failed to build updated Docker image"

                log_success "Node updated to ${LOGOS_NODE_VERSION}"

                if [[ "$was_running" == "true" ]]; then
                    if confirm "Restart the node?"; then
                        source "$LOGOS_NODE_LIB/cmd_start.sh"
                        cmd_start
                    else
                        log_info "Node stopped. Start manually with: logosup start"
                    fi
                fi
            else
                log_info "Update cancelled"
            fi
        else
            log_success "Node is already at the latest version (${current_version})"
        fi
    fi

    # ── Post-update: check if compose files need to be regenerated ───
    if [[ "$cli_updated" == "true" ]]; then
        # Node compose schema may have changed (e.g. logging caps, new env, etc).
        # Regen if lib/docker.sh or the Dockerfile dir changed — the on-disk
        # compose is fully derived from these.
        if echo "$cli_changed_files" | grep -qE '^(lib/docker\.sh|docker/)'; then
            local node_compose="$LOGOS_NODE_DIR/docker-compose.yml"
            if [[ -f "$node_compose" ]]; then
                echo ""
                log_info "Node compose schema changed — regenerating docker-compose.yml"
                generate_compose_file
                if docker_is_running; then
                    if confirm "Recreate the container now to apply the new compose?"; then
                        log_step "Recreating node container..."
                        docker_down
                        source "$LOGOS_NODE_LIB/cmd_start.sh"
                        cmd_start
                    else
                        log_info "Apply later with: ${BOLD}logosup stop && logosup start${RESET}"
                    fi
                fi
            fi
        fi

        local monitoring_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"

        if [[ -f "$monitoring_compose" ]] && echo "$cli_changed_files" | grep -qE '^(monitoring/|lib/monitoring\.sh)'; then
            source "$LOGOS_NODE_LIB/monitoring.sh"

            echo ""
            log_info "Monitoring files were updated:"
            echo "$cli_changed_files" | grep -E '^(monitoring/|lib/monitoring\.sh)' | while IFS= read -r f; do
                echo -e "  ${DIM}$f${RESET}"
            done
            echo ""

            if confirm "Rebuild monitoring stack?"; then
                generate_monitoring_compose_file
                if monitoring_is_running; then
                    monitoring_build || log_warn "Monitoring build failed"
                    monitoring_up
                    log_success "Monitoring stack updated"
                else
                    log_success "Monitoring compose regenerated (start with: logosup monitor start)"
                fi
            fi
        fi

        if docker_is_running; then
            log_info "Restart the node to apply changes: ${BOLD}logosup stop && logosup start${RESET}"
        fi
    fi
}
