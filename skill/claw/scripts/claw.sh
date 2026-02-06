#!/usr/bin/env bash
# Claw CLI - Bounded spending authority for AI agents
# Usage: claw.sh <command> [args]

set -e

# ============ Configuration ============

CONFIG_FILE="${HOME}/.config/claw/config.json"
DEFAULT_RPC="https://sepolia.base.org"
DEFAULT_CONTRACT="0x1e9Bc36Ec1beA19FD8959D496216116a8Fe76bA2"

# Load config
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        PRIVATE_KEY="${CLAW_PRIVATE_KEY:-$(jq -r '.private_key // empty' "$CONFIG_FILE" 2>/dev/null)}"
        RPC_URL="${CLAW_RPC_URL:-$(jq -r '.rpc_url // empty' "$CONFIG_FILE" 2>/dev/null)}"
        CONTRACT="${CLAW_CONTRACT:-$(jq -r '.claw_contract // empty' "$CONFIG_FILE" 2>/dev/null)}"
    fi
    
    PRIVATE_KEY="${PRIVATE_KEY:-$CLAW_PRIVATE_KEY}"
    RPC_URL="${RPC_URL:-$CLAW_RPC_URL}"
    RPC_URL="${RPC_URL:-$DEFAULT_RPC}"
    CONTRACT="${CONTRACT:-$CLAW_CONTRACT}"
    CONTRACT="${CONTRACT:-$DEFAULT_CONTRACT}"
}

# Get wallet address from private key
get_address() {
    if [[ -z "$PRIVATE_KEY" ]]; then
        echo "Error: No private key configured" >&2
        echo "Set CLAW_PRIVATE_KEY or add to ~/.config/claw/config.json" >&2
        exit 1
    fi
    cast wallet address "$PRIVATE_KEY" 2>/dev/null
}

# ============ Commands ============

cmd_status() {
    local token_id="$1"
    if [[ -z "$token_id" ]]; then
        echo "Usage: claw status <token_id>"
        exit 1
    fi
    
    echo "🦞 Claw #$token_id Status"
    echo "========================"
    
    # Get claw data: (maxSpend, spent, expiry, funder, burned)
    local data
    data=$(cast call "$CONTRACT" "claws(uint256)(uint256,uint256,uint256,address,bool)" "$token_id" --rpc-url "$RPC_URL" 2>/dev/null)
    
    if [[ -z "$data" ]]; then
        echo "Error: Could not fetch Claw data"
        exit 1
    fi
    
    # Parse the response (5 lines) - strip bracketed notation from cast output
    local max_spend spent expiry funder burned
    max_spend=$(echo "$data" | sed -n '1p' | awk '{print $1}')
    spent=$(echo "$data" | sed -n '2p' | awk '{print $1}')
    expiry=$(echo "$data" | sed -n '3p' | awk '{print $1}')
    funder=$(echo "$data" | sed -n '4p' | awk '{print $1}')
    burned=$(echo "$data" | sed -n '5p' | awk '{print $1}')
    
    # Convert from wei (6 decimals for USDC)
    local max_usd spent_usd remaining_usd
    max_usd=$(echo "scale=2; $max_spend / 1000000" | bc)
    spent_usd=$(echo "scale=2; $spent / 1000000" | bc)
    remaining_usd=$(echo "scale=2; ($max_spend - $spent) / 1000000" | bc)
    
    # Get owner
    local owner
    owner=$(cast call "$CONTRACT" "ownerOf(uint256)(address)" "$token_id" --rpc-url "$RPC_URL" 2>/dev/null || echo "Unknown")
    
    echo "Max Spend:  \$$max_usd USDC"
    echo "Spent:      \$$spent_usd USDC"
    echo "Remaining:  \$$remaining_usd USDC"
    echo ""
    echo "Owner:      $owner"
    echo "Funder:     $funder"
    
    if [[ "$expiry" == "0" ]]; then
        echo "Expiry:     None"
    else
        local expiry_date
        expiry_date=$(date -r "$expiry" 2>/dev/null || date -d "@$expiry" 2>/dev/null || echo "$expiry")
        echo "Expiry:     $expiry_date"
    fi
    
    if [[ "$burned" == "true" ]]; then
        echo "Status:     🔥 BURNED"
    else
        echo "Status:     ✅ Active"
    fi
}

cmd_list() {
    local address
    address=$(get_address)
    
    echo "🦞 Claws owned by $address"
    echo "================================"
    
    # Get balance (number of Claws owned)
    local balance
    balance=$(cast call "$CONTRACT" "balanceOf(address)(uint256)" "$address" --rpc-url "$RPC_URL" 2>/dev/null)
    
    if [[ "$balance" == "0" ]]; then
        echo "No Claws found."
        echo ""
        echo "Ask your human to mint you one!"
        exit 0
    fi
    
    echo "Found $balance Claw(s):"
    echo ""
    
    # Iterate through owned tokens
    for ((i=0; i<balance; i++)); do
        local token_id
        token_id=$(cast call "$CONTRACT" "tokenOfOwnerByIndex(address,uint256)(uint256)" "$address" "$i" --rpc-url "$RPC_URL" 2>/dev/null)
        
        # Get claw data
        local data max_spend spent
        data=$(cast call "$CONTRACT" "claws(uint256)(uint256,uint256,uint256,address,bool)" "$token_id" --rpc-url "$RPC_URL" 2>/dev/null)
        max_spend=$(echo "$data" | sed -n '1p' | awk '{print $1}')
        spent=$(echo "$data" | sed -n '2p' | awk '{print $1}')
        
        local max_usd spent_usd remaining_usd
        max_usd=$(echo "scale=2; $max_spend / 1000000" | bc)
        spent_usd=$(echo "scale=2; $spent / 1000000" | bc)
        remaining_usd=$(echo "scale=2; ($max_spend - $spent) / 1000000" | bc)
        
        echo "  Claw #$token_id: \$$remaining_usd remaining (of \$$max_usd)"
    done
}

cmd_balance() {
    local token_id="$1"
    if [[ -z "$token_id" ]]; then
        echo "Usage: claw balance <token_id>"
        exit 1
    fi
    
    local data max_spend spent
    data=$(cast call "$CONTRACT" "claws(uint256)(uint256,uint256,uint256,address,bool)" "$token_id" --rpc-url "$RPC_URL" 2>/dev/null)
    max_spend=$(echo "$data" | sed -n '1p' | awk '{print $1}')
    spent=$(echo "$data" | sed -n '2p' | awk '{print $1}')
    
    local remaining_usd
    remaining_usd=$(echo "scale=2; ($max_spend - $spent) / 1000000" | bc)
    
    echo "\$$remaining_usd"
}

cmd_spend() {
    local token_id="$1"
    local recipient="$2"
    local amount="$3"
    
    if [[ -z "$token_id" || -z "$recipient" || -z "$amount" ]]; then
        echo "Usage: claw spend <token_id> <recipient> <amount>"
        echo "  amount: in USDC (e.g., 10.50)"
        exit 1
    fi
    
    if [[ -z "$PRIVATE_KEY" ]]; then
        echo "Error: No private key configured" >&2
        exit 1
    fi
    
    # Convert amount to 6 decimals
    local amount_wei
    amount_wei=$(echo "$amount * 1000000" | bc | cut -d'.' -f1)
    
    echo "🦞 Spending from Claw #$token_id"
    echo "  To:     $recipient"
    echo "  Amount: \$$amount USDC"
    echo ""
    
    # Check current balance first
    local data max_spend spent remaining
    data=$(cast call "$CONTRACT" "claws(uint256)(uint256,uint256,uint256,address,bool)" "$token_id" --rpc-url "$RPC_URL" 2>/dev/null)
    max_spend=$(echo "$data" | sed -n '1p' | awk '{print $1}')
    spent=$(echo "$data" | sed -n '2p' | awk '{print $1}')
    remaining=$((max_spend - spent))
    
    if [[ "$amount_wei" -gt "$remaining" ]]; then
        local remaining_usd
        remaining_usd=$(echo "scale=2; $remaining / 1000000" | bc)
        echo "❌ Error: Insufficient balance"
        echo "   Requested: \$$amount"
        echo "   Available: \$$remaining_usd"
        exit 1
    fi
    
    # Execute spend
    echo "Sending transaction..."
    local tx_hash
    tx_hash=$(cast send "$CONTRACT" \
        "spend(uint256,address,uint256)" \
        "$token_id" "$recipient" "$amount_wei" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL" \
        --json 2>/dev/null | jq -r '.transactionHash')
    
    if [[ -n "$tx_hash" && "$tx_hash" != "null" ]]; then
        local new_remaining_usd
        new_remaining_usd=$(echo "scale=2; ($remaining - $amount_wei) / 1000000" | bc)
        echo ""
        echo "✅ Spent \$$amount USDC"
        echo "   Tx: $tx_hash"
        echo "   Remaining: \$$new_remaining_usd"
    else
        echo "❌ Transaction failed"
        exit 1
    fi
}

cmd_help() {
    echo "🦞 Claw CLI - Bounded Spending Authority for AI Agents"
    echo ""
    echo "Usage: claw <command> [args]"
    echo ""
    echo "Commands:"
    echo "  status <id>              Show detailed Claw status"
    echo "  list                     List all your Claws"
    echo "  balance <id>             Quick balance check"
    echo "  spend <id> <to> <amt>    Spend USDC from a Claw"
    echo "  help                     Show this help"
    echo ""
    echo "Configuration:"
    echo "  Set CLAW_PRIVATE_KEY env var, or create ~/.config/claw/config.json"
    echo ""
    echo "Examples:"
    echo "  claw list"
    echo "  claw status 1"
    echo "  claw spend 1 0x123... 25.00"
    echo ""
    echo "Contract: $DEFAULT_CONTRACT (Base Sepolia)"
}

# ============ Main ============

load_config

case "${1:-help}" in
    status)  cmd_status "$2" ;;
    list)    cmd_list ;;
    balance) cmd_balance "$2" ;;
    spend)   cmd_spend "$2" "$3" "$4" ;;
    help|*)  cmd_help ;;
esac
