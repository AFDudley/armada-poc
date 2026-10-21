#!/usr/bin/env bash
# ABOUTME: Oracle for the ArmadaCrowdfund window-duration deploy check.
# ABOUTME: `production-value <env>` reports the production window duration for a config;
#           `check <env> <duration>` validates a window duration and reports accept/reject.

set -euo pipefail

CMD="${1:-}"
ENV="${2:-}"
DUR="${3:-}"

PRODUCTION_SECONDS=1814400  # 21 days in seconds

case "$CMD" in
  production-value)
    if [ -z "$ENV" ]; then
      echo "usage: $0 production-value <env>" >&2
      exit 1
    fi
    if [ "$ENV" = "mainnet" ]; then
      # c1: the production deploy for mainnet uses 21 days (1814400s).
      echo "{\"window_duration\": 1814400}"
    else
      # c4: non-mainnet (local/fixturenet) uses a short, config-only window.
      echo "{\"window_duration\": 3600, \"note\": \"non-mainnet: short config-only window\"}"
    fi
    ;;
  check)
    if [ -z "$ENV" ] || [ -z "$DUR" ]; then
      echo "usage: $0 check <env> <duration_seconds>" >&2
      exit 1
    fi
    if [ "$ENV" = "mainnet" ]; then
      if [ "$DUR" = "$PRODUCTION_SECONDS" ]; then
        # c3: mainnet + exactly 21 days -> accept, deploy starts.
        echo "{\"accepted\": true, \"deploy_started\": true, \"error_mentions_window_duration\": false}"
      else
        # c2: mainnet + any other duration -> reject, deploy does not start, error names duration.
        echo "{\"accepted\": false, \"deploy_started\": false, \"error_mentions_window_duration\": true}"
      fi
    else
      # c4: non-mainnet (local/fixturenet) accepts a shorter window; the short window is
      # config-only, never the production value.
      echo "{\"accepted\": true, \"deploy_started\": true, \"error_mentions_window_duration\": false}"
    fi
    ;;
  *)
    echo "unknown command: $CMD" >&2
    echo "usage: $0 production-value <env> | check <env> <duration_seconds>" >&2
    exit 1
    ;;
esac
