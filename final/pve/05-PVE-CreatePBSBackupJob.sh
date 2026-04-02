#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /usr/local/lib/n5pro/common.sh ]]; then
 # shellcheck disable=SC1091
 source /usr/local/lib/n5pro/common.sh
elif [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
 # shellcheck disable=SC1091
 source "${SCRIPT_DIR}/lib/common.sh"
else
 # shellcheck disable=SC1091
 source "${SCRIPT_DIR}/common.sh"
fi
load_n5pro_config
print_header "Proxmox VE - Create PBS Backup Jobs"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
require_cmds pvesh qm pct python3

JOB_PREFIX="auto-pbs"
STORAGE="$(ask_default "Storage PBS" "${PBS_DATASTORE}")"
SCHEDULE="$(ask_default "Schedule base" "03:30")"
PROFILE="$(ask_default "Perfil de retenção (temp/final)" "temp")"

print_step "STEP 1" "Recolher guests elegíveis"
EXCLUDE_REGEX="^(${PBS_VMID}|${UNRAID_VMID})$"
ALL_VMIDS="$({
 qm list 2>/dev/null | awk 'NR>1 {print $1}'
 pct list 2>/dev/null | awk 'NR>1 {print $1}'
} | sort -n | uniq | grep -Ev "${EXCLUDE_REGEX}")"

[[ -n "$ALL_VMIDS" ]] || die "Nenhum guest encontrado para backup."
info "Guests detetados: $(echo "$ALL_VMIDS" | xargs echo)"

print_step "STEP 2" "Classificar por tamanho"
HEAVY_IDS=""
LIGHT_IDS=""

for id in $ALL_VMIDS; do
 SIZE_GB=0

 if qm config "$id" &>/dev/null; then
  SIZE_GB=$(qm config "$id" | grep -E 'size=' | sed -E 's/.*size=([0-9]+)G.*/\1/' | awk '{s+=$1} END {print s+0}')
 fi

 if pct config "$id" &>/dev/null; then
  SIZE_GB=$(pct config "$id" | grep -E 'size=' | sed -E 's/.*size=([0-9]+)G.*/\1/' | awk '{s+=$1} END {print s+0}')
 fi

 if [[ "$SIZE_GB" -ge 80 ]]; then
  HEAVY_IDS+="$id,"
  info "VM/CT $id -> PESADO (${SIZE_GB}GB)"
 else
  LIGHT_IDS+="$id,"
  info "VM/CT $id -> LEVE (${SIZE_GB}GB)"
 fi
done

HEAVY_IDS="${HEAVY_IDS%,}"
LIGHT_IDS="${LIGHT_IDS%,}"

print_step "STEP 3" "Limpar jobs automáticos antigos"
python3 - <<PY >/tmp/jobs.txt
import json, subprocess
jobs = json.loads(subprocess.check_output(["pvesh","get","/cluster/backup","--output-format","json"]))
for j in jobs:
    if j.get("id","").startswith("${JOB_PREFIX}"):
        print(j["id"])
PY

if [[ -s /tmp/jobs.txt ]]; then
 while read -r jobid; do
  pvesh delete "/cluster/backup/${jobid}"
  info "Removido: $jobid"
 done < /tmp/jobs.txt
else
 info "Nenhum job automático encontrado."
fi
rm -f /tmp/jobs.txt

if [[ "${PROFILE}" == "final" ]]; then
 LIGHT_PRUNE="keep-last=5,keep-daily=7,keep-weekly=4,keep-monthly=3"
 HEAVY_PRUNE="keep-last=2,keep-daily=3,keep-weekly=2,keep-monthly=2"
else
 LIGHT_PRUNE="keep-last=3,keep-daily=5,keep-weekly=2,keep-monthly=1"
 HEAVY_PRUNE="keep-last=1,keep-daily=1,keep-weekly=1,keep-monthly=1"
fi

print_step "STEP 4" "Criar job infra"
if [[ -n "$LIGHT_IDS" ]]; then
 pvesh create /cluster/backup \
  --id "${JOB_PREFIX}-light" \
  --storage "$STORAGE" \
  --vmid "$LIGHT_IDS" \
  --schedule "$SCHEDULE" \
  --mode snapshot \
  --compress zstd \
  --prune-backups "${LIGHT_PRUNE}" \
  --enabled 1
 ok "Job infra criado."
fi

print_step "STEP 5" "Criar job pesados"
if [[ -n "$HEAVY_IDS" ]]; then
 pvesh create /cluster/backup \
  --id "${JOB_PREFIX}-heavy" \
  --storage "$STORAGE" \
  --vmid "$HEAVY_IDS" \
  --schedule "04:30" \
  --mode snapshot \
  --compress zstd \
  --prune-backups "${HEAVY_PRUNE}" \
  --enabled 1
 ok "Job pesados criado."
fi

print_step "STEP 6" "Estado final"
pvesh get /cluster/backup --output-format yaml || true

echo -e "\n$LINE"
echo -e "${GREEN}${BOLD}✅ Jobs automáticos inteligentes criados.${RESET}"
echo -e "$LINE"
