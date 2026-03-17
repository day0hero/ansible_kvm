#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 -r <registry_url> -u <user> -p <password> -f <pull-secret.json> [-o <output.json>]"
    echo
    echo "Merges quay mirror-registry credentials into an existing pull secret."
    echo
    echo "  -r  Registry URL (e.g. bastion.ocp.rhuk.local:8443)"
    echo "  -u  Registry username"
    echo "  -p  Registry password"
    echo "  -f  Path to existing pull-secret.json"
    echo "  -o  Output file (default: merged-pull-secret.json)"
    exit 1
}

OUTPUT="merged-pull-secret.json"

while getopts "r:u:p:f:o:h" opt; do
    case $opt in
        r) REGISTRY="$OPTARG" ;;
        u) USER="$OPTARG" ;;
        p) PASS="$OPTARG" ;;
        f) PULL_SECRET="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        h|*) usage ;;
    esac
done

if [[ -z "${REGISTRY:-}" || -z "${USER:-}" || -z "${PASS:-}" || -z "${PULL_SECRET:-}" ]]; then
    usage
fi

if [[ ! -f "$PULL_SECRET" ]]; then
    echo "Error: pull secret file not found: $PULL_SECRET"
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required"; exit 1; }

AUTH=$(echo -n "${USER}:${PASS}" | base64 -w0)

jq --arg reg "$REGISTRY" --arg auth "$AUTH" \
    '.auths[$reg] = {"auth": $auth}' \
    "$PULL_SECRET" > "$OUTPUT"

echo "Merged pull secret written to: $OUTPUT"
echo "Registry: $REGISTRY"
