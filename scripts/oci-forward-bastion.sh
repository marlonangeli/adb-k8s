#!/usr/bin/env bash
set -euo pipefail

BASTION_ID=""
TARGET_IP=""
TARGET_PORT=""
LOCAL_PORT="8080"
SSH_KEY="${HOME}/.ssh/oci-bastion"
DISPLAY_NAME="oci-bastion-forward"
PRINT_ONLY="false"
CLEANUP_SESSION="true"
SSH_CONNECT_RETRIES="10"
SSH_CONNECT_RETRY_DELAY_SECONDS="3"

usage() {
  cat <<'EOF'
Usage:
  oci-bastion-forward.sh \
    --bastion-id <bastion-ocid> \
    --target-ip <private-ip> \
    --target-port <port> \
    [--local-port <port>] \
    [--ssh-key <path>] \
    [--display-name <name>] \
    [--print-only] \
    [--cleanup-session=false]

Example:
  ./oci-bastion-forward.sh \
    --bastion-id ocid1.bastion.oc1.sa-saopaulo-1... \
    --target-ip <private-service-ip> \
    --target-port 80 \
    --local-port 8080
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bastion-id)
      BASTION_ID="$2"
      shift 2
      ;;
    --target-ip)
      TARGET_IP="$2"
      shift 2
      ;;
    --target-port)
      TARGET_PORT="$2"
      shift 2
      ;;
    --local-port)
      LOCAL_PORT="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --display-name)
      DISPLAY_NAME="$2"
      shift 2
      ;;
    --print-only)
      PRINT_ONLY="true"
      shift
      ;;
    --cleanup-session)
      CLEANUP_SESSION="true"
      shift
      ;;
    --cleanup-session=false)
      CLEANUP_SESSION="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require oci
require jq
require ssh
require ssh-keygen

if [[ -z "$BASTION_ID" || -z "$TARGET_IP" || -z "$TARGET_PORT" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 1
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
    echo "Local port already in use: ${LOCAL_PORT}" >&2
    exit 6
  fi
fi

SSH_PUBLIC_KEY="${SSH_KEY}.pub"

mkdir -p "$(dirname "$SSH_KEY")"

if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$DISPLAY_NAME"
fi

chmod 600 "$SSH_KEY"

ssh-keygen -y -f "$SSH_KEY" > "$SSH_PUBLIC_KEY"
chmod 644 "$SSH_PUBLIC_KEY"

echo "Using SSH key fingerprint:" >&2
ssh-keygen -lf "$SSH_PUBLIC_KEY" >&2

SESSION_ID="$(
  oci bastion session create-port-forwarding \
    --bastion-id "$BASTION_ID" \
    --target-private-ip "$TARGET_IP" \
    --target-port "$TARGET_PORT" \
    --ssh-public-key-file "$SSH_PUBLIC_KEY" \
    --display-name "$DISPLAY_NAME" \
    | jq -r '.data.id'
)"

if [[ -z "$SESSION_ID" || "$SESSION_ID" == "null" ]]; then
  echo "Failed to create bastion session." >&2
  exit 2
fi

echo "Created bastion session: $SESSION_ID" >&2

cleanup() {
  if [[ "$CLEANUP_SESSION" == "true" ]]; then
    oci bastion session delete --session-id "$SESSION_ID" --force >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

for _ in {1..60}; do
  STATE="$(
    oci bastion session get --session-id "$SESSION_ID" \
      | jq -r '.data."lifecycle-state"'
  )"

  case "$STATE" in
    ACTIVE)
      break
      ;;
    FAILED|DELETED|DELETING)
      echo "Bastion session entered invalid state: $STATE" >&2
      exit 3
      ;;
  esac

  sleep 2
done

if [[ "${STATE:-}" != "ACTIVE" ]]; then
  echo "Timed out waiting for bastion session to become ACTIVE." >&2
  exit 4
fi

SSH_COMMAND="$(
  oci bastion session get --session-id "$SESSION_ID" \
    | jq -r '.data."ssh-metadata".command'
)"

if [[ -z "$SSH_COMMAND" || "$SSH_COMMAND" == "null" ]]; then
  echo "Could not read OCI SSH metadata command." >&2
  exit 5
fi

SSH_COMMAND="${SSH_COMMAND//<privateKey>/$SSH_KEY}"
SSH_COMMAND="${SSH_COMMAND//<localPort>/$LOCAL_PORT}"

echo "Opening tunnel:" >&2
echo "$SSH_COMMAND" >&2
echo >&2
echo "Access: http://127.0.0.1:${LOCAL_PORT}" >&2

if [[ "$PRINT_ONLY" == "true" ]]; then
  printf '%s\n' "$SSH_COMMAND"
  exit 0
fi

for attempt in $(seq 1 "$SSH_CONNECT_RETRIES"); do
  set +e
  bash -lc "$SSH_COMMAND"
  SSH_EXIT_CODE=$?
  set -e

  if [[ "$SSH_EXIT_CODE" -eq 0 ]]; then
    exit 0
  fi

  if [[ "$SSH_EXIT_CODE" -eq 130 || "$SSH_EXIT_CODE" -eq 143 ]]; then
    exit "$SSH_EXIT_CODE"
  fi

  if [[ "$attempt" -eq "$SSH_CONNECT_RETRIES" ]]; then
    echo "SSH failed after ${SSH_CONNECT_RETRIES} attempts. Exit code: ${SSH_EXIT_CODE}" >&2
    exit "$SSH_EXIT_CODE"
  fi

  echo "SSH failed with exit code ${SSH_EXIT_CODE}. Retrying in ${SSH_CONNECT_RETRY_DELAY_SECONDS}s... (${attempt}/${SSH_CONNECT_RETRIES})" >&2
  sleep "$SSH_CONNECT_RETRY_DELAY_SECONDS"
done
