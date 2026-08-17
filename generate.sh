#!/usr/bin/env bash

set -euo pipefail

nginx_ip_conf_dir="${nginx_ip_conf_dir:-/etc/nginx/conf.d}"
sleep_secs="0"
# How many backups to keep per config file (default 5). Set $backup_keep to override.
backup_keep="${backup_keep:-5}"

for cmd in curl sed mv chmod rm cmp mktemp awk date ls xargs sed; do
    command -v "$cmd" >/dev/null || { echo >&2 "Error: $cmd not found. Please make sure it's installed and try again."; exit 1; }
done

declare -A CDN_NAME CDN_IP_HEADER REQUESTED_CDN

CDN_NAME["cf"]="Cloudflare"
CDN_IP_HEADER["cf"]="CF-Connecting-IP"

CDN_NAME["fastly"]="Fastly"
CDN_IP_HEADER["fastly"]="Fastly-Client-IP"

# TEMP FILES cleanup
declare -a TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

fetch_ip_list() {
    local out="$1"
    : > "$out"
    case $2 in
    "cf")
        for file in ips-v4 ips-v6; do
            curl --compressed -sLo- "https://www.cloudflare.com/$file" >> "$out"
            echo '' >> "$out"
        done
        ;;
    "fastly")
        curl --compressed -sLo- https://api.fastly.com/public-ip-list | \
            awk -F'[]["'] '{for(i=1;i<=NF;i++) if ($i ~ /.*\/.* /) print $i}' | \
            sed 's/,\|"//g' >> "$out"
        ;;
    esac
}

help() {
    echo >&2
    echo >&2 "This tool generates an nginx config file that sets the correct client IP address based on CDN provider IP ranges and the corresponding header."
    echo >&2 ""
    echo >&2 "Usage:"
    echo >&2 ""
    echo >&2 "$0 [--cron] <CDN> [[CDN] [CDN]]"
    echo >&2 ""
    echo >&2 "Supported CDN:"
    echo >&2 ""
    for cdn in "${!CDN_NAME[@]}"; do
        echo >&2 "- $cdn (${CDN_NAME[$cdn]}, using http header ${CDN_IP_HEADER[$cdn]})"
    done
}

for arg in "$@"; do
    case $arg in
    "-h"|"--help")
        help
        exit
        ;;
    "--cron")
        sleep_secs="$((RANDOM % 900))"
        continue
        ;;
    esac

    # Test whether CDN_NAME has an element for this arg.
    if [ -z "${CDN_NAME[$arg]+x}" ]; then
        echo >&2 "\"$arg\" is not in the supported CDN list nor the supported argument, skipped..."
        continue
    fi
    REQUESTED_CDN[$arg]=1
done

# Check whether any CDN was requested
if [ ${#REQUESTED_CDN[@]} -eq 0 ]; then
    echo >&2
    echo >&2 "No valid CDN found!"
    help
    exit 1
fi

sleep "$sleep_secs"
echo "Start nginx real client ip config generation..."

mkdir -p "$nginx_ip_conf_dir"

# Validate a single IP or CIDR (IPv4 or IPv6).
is_valid_ip_or_cidr() {
    local item="$1"

    # IPv6 (contains ':')
    if [[ "$item" == *:* ]]; then
        if [[ "$item" =~ ^([0-9A-Fa-f:]+)(/([0-9]{1,3}))?$ ]]; then
            local mask="${BASH_REMATCH[3]:-}"
            if [[ -n "$mask" ]]; then
                if (( mask < 0 || mask > 128 )); then
                    return 1
                fi
            fi
            return 0
        fi
        return 1
    fi

    # IPv4
    if [[ "$item" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
        local ip="${BASH_REMATCH[1]}"
        local mask="${BASH_REMATCH[3]:-}"
        IFS=. read -r o1 o2 o3 o4 <<< "$ip"
        for o in "$o1" "$o2" "$o3" "$o4"; do
            # Ensure numeric and 0-255
            if ! [[ "$o" =~ ^[0-9]+$ ]]; then return 1; fi
            if (( o < 0 || o > 255 )); then
                return 1
            fi
        done
        if [[ -n "$mask" ]]; then
            if (( mask < 0 || mask > 32 )); then
                return 1
            fi
        fi
        return 0
    fi

    return 1
}

validate_ips_file() {
    local file="$1"
    local ok=0

    # Extract the raw addresses from lines like: set_real_ip_from 1.2.3.0/24;
    while IFS= read -r addr; do
        # skip blank lines
        [ -z "$addr" ] && continue
        # strip leading/trailing whitespace
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"

        # Expect lines that begin with set_real_ip_from and end with ;
        if [[ "$addr" =~ ^set_real_ip_from[[:space:]]+([^;]+);[[:space:]]*$ ]]; then
            local candidate="${BASH_REMATCH[1]}"
            if is_valid_ip_or_cidr "$candidate"; then
                ok=1
                continue
            else
                echo "Invalid IP/CIDR detected: '$candidate'" >&2
                return 1
            fi
        else
            # If there are lines that aren't in expected form, reject
            echo "Unexpected line in generated file: '$addr'" >&2
            return 1
        fi
    done < "$file"

    # If at least one valid address was found, pass
    if [ "$ok" -eq 1 ]; then
        return 0
    fi

    echo "No valid IP ranges found in $file" >&2
    return 1
}

prune_old_backups() {
    local conf="$1"
    local keep="$2"

    # Use ls -1t to list backups sorted newest first, then remove everything after the first $keep
    # The pattern is conf.bak.*
    # If no backups exist, ls will fail; redirect errors to /dev/null
    local pattern="${conf}.bak.*"
    # shellcheck disable=SC2086
    local list
    list=$(ls -1t $pattern 2>/dev/null || true)
    if [ -z "$list" ]; then
        return 0
    fi

    # Print older backups (from keep+1 to end)
    local older
    older=$(printf '%s
' "$list" | sed -n "$((keep+1)),\$p")
    if [ -n "$older" ]; then
        echo "Pruning old backups for $conf (keeping $keep):"
        printf '%s
' "$older" | xargs -r rm -f
    fi
}

for cdn in "${!REQUESTED_CDN[@]}"; do
    nginx_ip_conf="$nginx_ip_conf_dir/${CDN_NAME[$cdn],,}-set-real-ip.conf"
    echo
    echo "Config target: $nginx_ip_conf"
    echo
    echo "Fetching ${CDN_NAME[$cdn]} IP addresses..."

    # Create a temporary file (kept in TMPDIR) to prepare the new config
    tmpfile="$(mktemp)"
    TEMP_FILES+=("$tmpfile")

    fetch_ip_list "$tmpfile" "$cdn"

    echo "Generating nginx configuration file..."
    # Prepend header lines and prefix each address with set_real_ip_from ...;
    # Use a temp-work file so sed in-place isn't modifying previous state
    {
        echo "real_ip_header ${CDN_IP_HEADER[$cdn]};"
        echo "real_ip_recursive on;"
        sed -e 's/^/set_real_ip_from /g' -e 's/$/;/g' "$tmpfile"
    } > "${tmpfile}.out"
    mv -f "${tmpfile}.out" "$tmpfile"

    # Validate the generated file
    if ! validate_ips_file "$tmpfile"; then
        echo "Validation failed for ${CDN_NAME[$cdn]} IP list; skipping update for $nginx_ip_conf" >&2
        rm -f "$tmpfile"
        # remove tmpfile from tracking
        TEMP_FILES=("${TEMP_FILES[@]/$tmpfile}")
        continue
    fi

    chmod 644 "$tmpfile"

    if ! [ -e "$nginx_ip_conf" ]; then
        # No existing config: install new file
        mv -f "$tmpfile" "$nginx_ip_conf"
        chmod 644 "$nginx_ip_conf"
        echo "Nginx configuration for ${CDN_NAME[$cdn]} IP addresses added successfully: $nginx_ip_conf"
    elif cmp -s "$tmpfile" "$nginx_ip_conf"; then
        echo "No changes detected. We have nothing to do for ${CDN_NAME[$cdn]}."
        rm -f "$tmpfile"
        TEMP_FILES=("${TEMP_FILES[@]/$tmpfile}")
    else
        echo "${CDN_NAME[$cdn]} IP addresses config have changed. Updating nginx configuration..."
        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
        backup="${nginx_ip_conf}.bak.${timestamp}"
        # Keep previous config as a timestamped backup
        mv -f "$nginx_ip_conf" "$backup"
        mv -f "$tmpfile" "$nginx_ip_conf"
        chmod 644 "$nginx_ip_conf"
        echo "Previous config saved to $backup"
        # Prune older backups beyond $backup_keep
        prune_old_backups "$nginx_ip_conf" "$backup_keep"
        echo "Nginx configuration for ${CDN_NAME[$cdn]} IP addresses updated successfully."
        TEMP_FILES=("${TEMP_FILES[@]/$tmpfile}")
    fi
done
