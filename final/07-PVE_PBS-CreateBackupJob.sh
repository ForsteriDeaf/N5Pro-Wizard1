#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[INFO] Wrapper de compatibilidade: 07 -> 06-PVE_PBS-CreateBackupJob.sh"
exec bash "${SCRIPT_DIR}/06-PVE_PBS-CreateBackupJob.sh" "$@"
