#!/usr/bin/env bash
# DESCRIPTION: Base-layer wallet — balance, transfer, and transaction lookup

cmd_wallet() {
    detect_platform
    check_docker

    source "$LOGOS_NODE_LIB/wallet.sh"

    local subcmd="${1:-help}"
    shift 2>/dev/null || true

    case "$subcmd" in
        balance)            _wallet_balance "$@" ;;
        transfer|send)      _wallet_transfer "$@" ;;
        tx|transaction)     _wallet_tx "$@" ;;
        -h|--help|help)     _wallet_help ;;
        *)
            log_error "Unknown wallet subcommand: $subcmd"
            _wallet_help
            return 1
            ;;
    esac
}

_wallet_help() {
    echo ""
    log_step "Base-layer wallet"
    echo ""
    log_info "${BOLD}Usage:${RESET}"
    log_info "  logosup wallet balance [<key>]              Show balance for one or all keys"
    log_info "  logosup wallet transfer <to_pk> <amount>    Send funds to a recipient"
    log_info "                            [--from <key>]       Explicit funding key"
    log_info "                            [--change <key>]     Where leftover change goes (defaults to --from)"
    log_info "                            [--yes]              Skip confirmation"
    log_info "  logosup wallet tx <tx_hash>                 Look up a transaction"
    echo ""
    log_info "${BOLD}Examples:${RESET}"
    log_info "  logosup wallet balance"
    log_info "  logosup wallet transfer 8a3b7f...c2d1 100"
    log_info "  logosup wallet send 8a3b7f...c2d1 100 --from 793055d1..."
    log_info "  logosup wallet tx 0x4d8e2a..."
    echo ""
    log_dim "All cryptography happens inside the node. The CLI is a thin HTTP wrapper."
    echo ""
}

_is_hex64() {
    [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]
}

_is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

_wallet_balance() {
    local target_key="${1:-}"

    log_step "Wallet balance"
    echo ""

    local keys leader_pk
    leader_pk="$(get_wallet_leader_pk 2>/dev/null)"

    if [[ -n "$target_key" ]]; then
        # Allow user to pass either the full 64-hex key or just enough of a
        # prefix to disambiguate — match against known_keys.
        if _is_hex64 "$target_key"; then
            keys="$target_key"
        else
            keys="$(get_wallet_keys 2>/dev/null | grep -i "^${target_key}" || true)"
            if [[ -z "$keys" ]]; then
                log_error "No known_key matches: $target_key"
                log_info "List your keys: ${BOLD}logosup keys${RESET}"
                return 1
            fi
        fi
    else
        # LeaderFunding first, then the rest — same ordering as logosup status.
        keys="$(get_wallet_keys_prioritized 2>/dev/null)" || true
        if [[ -z "$keys" ]]; then
            log_warn "No wallet keys found. Run ${BOLD}logosup install${RESET} first."
            return 1
        fi
    fi

    local total=0
    local any_ok=false
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        # Note: do NOT use `$(wallet_get_balance ...)` — that runs in a subshell
        # and the WALLET_* globals wouldn't propagate back. Call bare, read globals.
        wallet_get_balance "$key"

        # Annotate with the semantic role (LeaderFunding, VaucherMaster, ...)
        # from keystore.yaml. Highlight the LeaderFunding row.
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
            local balance note_count
            balance="$(echo "$WALLET_BODY" | sed -E 's/.*"balance":([0-9]+).*/\1/')"
            # Count notes by counting the entries inside "notes":{...}
            note_count="$(echo "$WALLET_BODY" | grep -oE '"notes":\{[^}]*\}' | grep -oE '"[0-9a-f]{64}":' | wc -l | tr -d ' ')"
            log_info "${role_tag}${key_str}  balance: ${BOLD}${balance}${RESET}  notes: ${note_count}"
            if [[ "$balance" =~ ^[0-9]+$ ]]; then
                total=$((total + balance))
                any_ok=true
            fi
            # If the user asked for a single key, dump per-note breakdown
            if [[ -n "$target_key" ]]; then
                echo "$WALLET_BODY" | grep -oE '"[0-9a-f]{64}":[0-9]+' \
                    | while IFS= read -r entry; do
                        local nid nval
                        nid="$(echo "$entry" | sed -E 's/^"([0-9a-f]{64})":.*/\1/')"
                        nval="$(echo "$entry" | sed -E 's/.*:([0-9]+)$/\1/')"
                        log_dim "    note ${nid}  ${nval}"
                    done
            fi
        elif echo "$WALLET_BODY" | grep -qiE "not (be )?found"; then
            # 0.1.x: "not found". 0.2.0: "The requested address could not be
            # found in the wallet". Both mean the wallet knows the key but
            # hasn't seen inbound funds.
            log_info "${role_tag}${key_str}  balance: ${BOLD}0${RESET} ${DIM}(no funds received yet)${RESET}"
        else
            local err
            err="$(wallet_squash_body "$WALLET_BODY" 120 "$WALLET_HTTP_CODE")"
            log_info "${role_tag}${key_str}  balance: ${DIM}error (HTTP ${WALLET_HTTP_CODE}): ${err}${RESET}"
            if [[ "$WALLET_HTTP_CODE" == "408" ]]; then
                log_dim "    (timeout — node may be busy; retry, or check ${BOLD}logosup logs${RESET})"
            fi
        fi
    done <<< "$keys"

    if $any_ok && [[ -z "$target_key" ]]; then
        echo ""
        log_info "Total: ${BOLD}${total}${RESET}"
    fi
    if [[ -z "$target_key" && -n "$leader_pk" ]]; then
        echo ""
        log_dim "★ = LeaderFunding — fund this key at ${LOGOS_FAUCET_URL} to participate in consensus"
    fi
    echo ""
}

_wallet_transfer() {
    local recipient="" amount="" from_key="" change_key="" skip_confirm=false

    # Parse positional + flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)        from_key="${2:-}"; shift 2 ;;
            --change)      change_key="${2:-}"; shift 2 ;;
            -y|--yes)      skip_confirm=true; shift ;;
            -h|--help)     _wallet_help; return 0 ;;
            -*)
                log_error "Unknown flag: $1"
                return 1 ;;
            *)
                if [[ -z "$recipient" ]]; then
                    recipient="$1"
                elif [[ -z "$amount" ]]; then
                    amount="$1"
                else
                    log_error "Unexpected argument: $1"
                    return 1
                fi
                shift ;;
        esac
    done

    if [[ -z "$recipient" || -z "$amount" ]]; then
        log_error "Usage: logosup wallet transfer <to_pk> <amount> [--from <key>] [--change <key>] [--yes]"
        return 1
    fi

    if ! _is_hex64 "$recipient"; then
        log_error "Recipient must be a 64-character hex public key"
        return 1
    fi

    if ! _is_positive_int "$amount"; then
        log_error "Amount must be a positive integer"
        return 1
    fi

    log_step "Preparing transfer"

    # Fetch tip — also doubles as a "node reachable + synced enough to be useful" check.
    local tip
    tip="$(wallet_get_tip)" || true
    if [[ -z "$tip" ]]; then
        log_error "Could not fetch chain tip from ${BOLD}$(wallet_api_url)/cryptarchia/info${RESET}"
        log_info "Make sure the node is running and reachable: ${BOLD}logosup status${RESET}"
        return 1
    fi

    # Pick funding key
    if [[ -z "$from_key" ]]; then
        from_key="$(wallet_pick_funding_key "$amount")" || true
        if [[ -z "$from_key" ]]; then
            log_error "Insufficient balance — no single key holds at least $amount"
            log_info "Current balances:"
            _wallet_balance
            return 1
        fi
    else
        if ! _is_hex64 "$from_key"; then
            log_error "--from must be a 64-character hex public key"
            return 1
        fi
        # Verify it has enough balance before submitting (bare call, read globals)
        wallet_get_balance "$from_key"
        if [[ "$WALLET_HTTP_CODE" != "200" ]]; then
            log_error "Could not check balance for --from key (HTTP $WALLET_HTTP_CODE)"
            log_info "$(wallet_squash_body "$WALLET_BODY" 120 "$WALLET_HTTP_CODE")"
            return 1
        fi
        local bal
        bal="$(echo "$WALLET_BODY" | sed -E 's/.*"balance":([0-9]+).*/\1/')"
        if [[ ! "$bal" =~ ^[0-9]+$ ]] || (( bal < amount )); then
            log_error "Insufficient balance: --from key has $bal, transferring $amount"
            return 1
        fi
    fi

    # Default change key = funding key (change returns to the sender unless
    # the operator explicitly redirects it with --change).
    if [[ -z "$change_key" ]]; then
        change_key="$from_key"
    elif ! _is_hex64 "$change_key"; then
        log_error "--change must be a 64-character hex public key"
        return 1
    fi

    echo ""
    log_info "From:      ${DIM}${from_key}${RESET}"
    log_info "To:        ${DIM}${recipient}${RESET}"
    log_info "Amount:    ${BOLD}${amount}${RESET}"
    log_info "Change to: ${DIM}${change_key}${RESET}"
    log_dim "Tip:       ${tip}"
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        if ! confirm "Submit transfer?" "y"; then
            log_info "Transfer cancelled"
            return 0
        fi
    fi

    log_step "Submitting..."
    wallet_post_transfer "$tip" "$change_key" "$from_key" "$recipient" "$amount"

    if [[ "$WALLET_HTTP_CODE" == "201" || "$WALLET_HTTP_CODE" == "200" ]]; then
        local tx_hash
        tx_hash="$(echo "$WALLET_BODY" | sed -E 's/.*"hash":"([^"]+)".*/\1/')"
        echo ""
        log_success "Transaction submitted to mempool"
        log_info "Hash:   ${BOLD}${tx_hash}${RESET}"
        log_info "Lookup: ${BOLD}logosup wallet tx ${tx_hash}${RESET}"
        if [[ -n "${LOGOS_DASHBOARD_URL:-}" ]]; then
            local base="${LOGOS_DASHBOARD_URL%/}"
            log_info "Explorer: ${base}/explorer/   ${DIM}(uses a different id scheme; can't be auto-linked)${RESET}"
        fi
        echo ""
        log_dim "Confirmation = your ${BOLD}wallet balance${RESET}${DIM} updates: the recipient gets"
        log_dim "a new note, change goes back to the funding/--change key."
        log_dim ""
        log_dim "Note: the public testnet explorer computes its own SHA-256-of-JSON id,"
        log_dim "independent from the node's TxHash above (see logos-blockchain-block-"
        log_dim "explorer-template#15) — pasting the hash into the explorer URL won't"
        log_dim "find your tx. Best success signal is the balance change above."
        echo ""
    else
        log_error "Transfer failed (HTTP ${WALLET_HTTP_CODE})"
        log_info "$(wallet_squash_body "$WALLET_BODY" 240 "$WALLET_HTTP_CODE")"
        if [[ "$WALLET_HTTP_CODE" == "408" ]]; then
            log_dim "Timeout — the node may be busy. Retry, or check ${BOLD}logosup logs${RESET}"
        fi
        return 1
    fi
}

_wallet_tx() {
    local hash="${1:-}"
    if [[ -z "$hash" ]]; then
        log_error "Usage: logosup wallet tx <tx_hash>"
        return 1
    fi
    # Strip 0x prefix if present
    hash="${hash#0x}"
    if ! _is_hex64 "$hash"; then
        log_error "tx_hash must be a 64-character hex value"
        return 1
    fi

    log_step "Transaction lookup"
    wallet_get_tx "$hash"

    if [[ "$WALLET_HTTP_CODE" == "200" && -n "$WALLET_BODY" ]]; then
        echo ""
        log_info "Hash: ${DIM}${hash}${RESET}"
        # Best-effort field extraction; fall back to raw body
        local height slot
        height="$(echo "$WALLET_BODY" | sed -nE 's/.*"height":([0-9]+).*/\1/p' | head -1)"
        slot="$(echo "$WALLET_BODY" | sed -nE 's/.*"slot":([0-9]+).*/\1/p' | head -1)"
        [[ -n "$height" ]] && log_info "Height: ${BOLD}${height}${RESET}"
        [[ -n "$slot" ]]   && log_info "Slot:   ${BOLD}${slot}${RESET}"
        echo ""
        log_dim "Raw response:"
        echo "$WALLET_BODY"
        echo ""
    elif [[ "$WALLET_HTTP_CODE" == "404" ]] || echo "$WALLET_BODY" | grep -qi "not found"; then
        log_warn "Transaction not found"
        log_dim "  • Tx may not be in a block yet (still in mempool)"
        log_dim "  • Or running on logos-blockchain v0.1.2 — the /cryptarchia/transaction/<id>"
        log_dim "    endpoint was added after that release (in 0.1.3). Upgrade when 0.1.3 lands."
        log_dim "  • Or the hash is wrong (typo, or you're using the explorer's SHA-256-of-JSON id"
        log_dim "    instead of the canonical TxHash returned by ${BOLD}wallet transfer${RESET}${DIM})."
        log_dim "If your ${BOLD}wallet balance${RESET}${DIM} reflects the change, the transfer landed."
    else
        log_error "Lookup failed (HTTP ${WALLET_HTTP_CODE})"
        log_info "$(wallet_squash_body "$WALLET_BODY" 240 "$WALLET_HTTP_CODE")"
        return 1
    fi
}
