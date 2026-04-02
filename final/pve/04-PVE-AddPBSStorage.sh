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
print_header "Proxmox VE - Add PBS Storage"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
require_cmds pvesm openssl

if pvesm status | awk 'NR>1 && $1=="pbs" && $3=="active" {found=1} END{exit !found}'; then
 warn "Storage 'pbs' já existe e está ativo."
 info "Se já vês backups no Proxmox, este passo pode ser redundante."
 if ! confirm "Queres continuar mesmo assim?"; then
  info "STEP 05 ignorado por opção do utilizador."
  exit 0
 fi
fi

STORAGE_ID="$(ask_default "Storage ID" "${PBS_DATASTORE}")"
PBS_HOST="$(ask_default "IP do PBS" "${PBS_IP}")"
PBS_PORT="$(ask_default "Porta PBS" "8007")"
DATASTORE="$(ask_default "Nome do datastore" "${PBS_DATASTORE}")"
USERNAME="$(ask_default "Username PBS" "root@pam")"

if pvesm status | awk -v sid="$STORAGE_ID" 'NR>1 && $1==sid {found=1} END{exit !found}'; then
 warn "Storage ${STORAGE_ID} já existe."
 warn "Remove primeiro no GUI ou em /etc/pve/storage.cfg."
 exit 0
fi

echo
read -r -s -p "$(echo -e "${CYAN}Password de ${USERNAME}: ${RESET}")" PASSWORD
echo

print_step "STEP 1" "Obter fingerprint do PBS"
FINGERPRINT="$(
 echo | openssl s_client -connect "${PBS_HOST}:${PBS_PORT}" 2>/dev/null \
 | openssl x509 -noout -fingerprint -sha256 \
 | cut -d'=' -f2
)"

[[ -n "$FINGERPRINT" ]] || die "Não foi possível obter fingerprint do PBS."
info "Fingerprint: ${FINGERPRINT}"

print_step "STEP 2" "Adicionar storage PBS ao Proxmox"
pvesm add pbs "$STORAGE_ID" \
 --server "$PBS_HOST" \
 --port "$PBS_PORT" \
 --datastore "$DATASTORE" \
 --username "$USERNAME" \
 --password "$PASSWORD" \
 --fingerprint "$FINGERPRINT" \
 --content backup

ok "Storage PBS adicionado."

print_step "STEP 3" "Verificação final"
pvesm status | grep -E "^${STORAGE_ID}[[:space:]]|^Name" || true

echo -e "\n$LINE"
echo -e "${GREEN}${BOLD}✅ PBS ligado ao Proxmox com sucesso.${RESET}"
echo -e "${GREEN}${BOLD}Depois correr o script 06 dentro da PVE${RESET}"
echo -e "$LINE"
