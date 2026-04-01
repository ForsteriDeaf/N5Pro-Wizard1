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
print_header "N5 Pro - Create PBS VM (ordem nova: PBS antes do Unraid)"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
require_cmds qm pvesm wget awk grep sed lsusb ssh scp ping sshpass

vm_exists(){ qm status "$1" >/dev/null 2>&1; }
detect_bridge(){ grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null && { echo vmbr0; return; }; awk '/^auto vmbr/ {print $2; exit}' /etc/network/interfaces 2>/dev/null; }
detect_storage(){ pvesm status | awk 'NR>1 {print $1}' | grep -qx "${VM_STORAGE}" && { echo "${VM_STORAGE}"; return; }; pvesm status | awk 'NR>1 && $2=="lvmthin" {print $1; exit}'; }
detect_iso_storage(){ if pvesm status | awk 'NR>1 {print $1}' | grep -qx 'local'; then echo "local"; else pvesm status | awk 'NR>1 {print $1; exit}'; fi; }
detect_pbs_usb(){ lsusb | awk '/Samsung|Mass Storage|USB DISK|Portable SSD/ {print $6; exit}'; }

list_pbs_isos() {
 local iso_dir="/var/lib/vz/template/iso"
 [[ -d "$iso_dir" ]] || return 0
 find "$iso_dir" -maxdepth 1 -type f \( -iname 'proxmox-backup-server*.iso' -o -iname 'pbs*.iso' \) -printf '%f\n' 2>/dev/null | sort
}

ensure_pbs_iso() {
 local iso_dir="/var/lib/vz/template/iso"
 local default_iso="$1"
 local selected_iso="$default_iso"

 mkdir -p "$iso_dir"

 if [[ -f "${iso_dir}/${selected_iso}" ]]; then
  echo "$selected_iso"
  return 0
 fi

 mapfile -t AVAILABLE_ISOS < <(list_pbs_isos)
 if [[ ${#AVAILABLE_ISOS[@]} -gt 0 ]]; then
  warn "O ISO ${selected_iso} não existe."
  info "ISO(s) PBS encontrados em local:iso:"
  for iso in "${AVAILABLE_ISOS[@]}"; do
   echo " - $iso"
  done
  selected_iso="$(ask_default "Nome do ISO PBS" "${AVAILABLE_ISOS[0]}")"
  if [[ -f "${iso_dir}/${selected_iso}" ]]; then
   echo "$selected_iso"
   return 0
  fi
 fi

 if confirm "Queres fazer download automático do ISO PBS"; then
  local download_url
  download_url="$(ask_default "URL do ISO PBS" "https://download.proxmox.com/iso/proxmox-backup-server_4.1-1.iso")"
  info "A descarregar ISO para ${iso_dir}/${default_iso}..."
  wget --no-check-certificate -O "${iso_dir}/${default_iso}" "$download_url" >&2
  [[ -f "${iso_dir}/${default_iso}" ]] && { echo "$default_iso"; return 0; }
 fi

 die "Não foi possível garantir um ISO PBS válido em local:iso."
}

validate_storage(){ pvesm status | awk 'NR>1 {print $1}' | grep -qx "$1" || die "Storage inválido: $1"; }
validate_usb_if_needed(){ [[ "$1" == "skip" || -z "$1" ]] && return 0; lsusb | awk '{print $6}' | grep -qx "$1" || die "USB inválido: $1"; }

wait_for_pbs_online() {
 local host="$1"
 local tries=90
 info "A aguardar PBS ficar online em ${host}..."
 until ping -c1 -W1 "$host" >/dev/null 2>&1; do
  tries=$((tries-1))
  [[ $tries -le 0 ]] && die "PBS não respondeu a ping em ${host}."
  sleep 2
 done
 ok "PBS responde em ${host}."
}

inject_n5pro_tools_into_pbs() {
 local host="$1"
 local password="$2"
 local local_post="/usr/local/bin/n5pro-post"
 local local_common="/usr/local/lib/n5pro/common.sh"
 local local_conf="/etc/n5pro.conf"
 [[ -n "$password" ]] || { warn "Password PBS não fornecida; salto a injeção automática."; return 0; }
 [[ -f "$local_post" ]] || { warn "n5pro-post não encontrado em ${local_post}; salto a injeção."; return 0; }
 [[ -f "$local_common" ]] || { warn "common.sh não encontrado em ${local_common}; salto a injeção."; return 0; }
 [[ -f "$local_conf" ]] || { warn "/etc/n5pro.conf não encontrado; salto a injeção."; return 0; }
 info "A preparar diretórios na PBS..."
 sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${host}" "mkdir -p /usr/local/bin /usr/local/lib/n5pro" >/dev/null 2>&1 || { warn "Falha a preparar diretórios na PBS."; return 0; }
 info "A copiar n5pro-post, common.sh e /etc/n5pro.conf para a PBS..."
 sshpass -p "$password" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$local_post" root@"${host}":/usr/local/bin/n5pro-post >/dev/null 2>&1 || { warn "Falha ao copiar n5pro-post."; return 0; }
 sshpass -p "$password" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$local_common" root@"${host}":/usr/local/lib/n5pro/common.sh >/dev/null 2>&1 || { warn "Falha ao copiar common.sh."; return 0; }
 sshpass -p "$password" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$local_conf" root@"${host}":/etc/n5pro.conf >/dev/null 2>&1 || { warn "Falha ao copiar /etc/n5pro.conf."; return 0; }
 sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${host}" "chmod +x /usr/local/bin/n5pro-post && chmod 644 /usr/local/lib/n5pro/common.sh && chmod 600 /etc/n5pro.conf" >/dev/null 2>&1 || { warn "Falha a ajustar permissões na PBS."; return 0; }
 ok "n5pro-post disponível dentro da PBS."
}

print_step "STEP 1" "Deteção automática"
DEFAULT_BRIDGE="$(detect_bridge)"
DEFAULT_STORAGE="$(detect_storage)"
DEFAULT_ISO_STORAGE="$(detect_iso_storage)"
DEFAULT_USB="$(detect_pbs_usb)"

info "Bridge detetada       : ${DEFAULT_BRIDGE:-não encontrado}"
info "Storage VM detetado   : ${DEFAULT_STORAGE:-não encontrado}"
info "Storage ISO detetado  : ${DEFAULT_ISO_STORAGE:-não encontrado}"
info "USB externo detetado  : ${DEFAULT_USB:-não encontrado}"

VMID="$(ask_default "VMID da VM PBS" "${PBS_VMID}")"
NAME="$(ask_default "Nome da VM" "PBServer")"
CORES="$(ask_default "Número de cores" "${PBS_CORES}")"
MEMORY="$(ask_default "RAM em MB" "${PBS_MEMORY}")"
DISK_SIZE="$(ask_default "Tamanho do disco (GB)" "${PBS_SYSTEM_DISK_GB}")"
BRIDGE_SEL="$(ask_default "Bridge de rede" "${DEFAULT_BRIDGE:-vmbr0}")"
STORAGE="$(ask_default "Storage para disco EFI/VM" "${DEFAULT_STORAGE:-${VM_STORAGE}}")"
ISO_STORAGE_SEL="$(ask_default "Storage onde está o ISO" "${DEFAULT_ISO_STORAGE:-${ISO_STORAGE}}")"
ISO_FILE="$(ask_default "Nome do ISO PBS" "${PBS_ISO_FILE}")"
MACADDR="$(ask_default "MAC Address" "${PBS_MAC}")"
USB_BACKUP_ID="$(ask_default "USB externo para PBS (ou skip)" "${PBS_USB_BACKUP_ID:-skip}")"

[[ "${ISO_STORAGE_SEL}" == "local" ]] && ISO_FILE="$(ensure_pbs_iso "$ISO_FILE")"

vm_exists "${VMID}" && die "O VMID ${VMID} já existe."
validate_storage "${STORAGE}"
validate_usb_if_needed "${USB_BACKUP_ID}"

print_step "STEP 2" "Resumo final da VM PBS"
echo "VMID         : ${VMID}"
echo "Nome         : ${NAME}"
echo "Cores        : ${CORES}"
echo "RAM (MB)     : ${MEMORY}"
echo "Disco (GB)   : ${DISK_SIZE}"
echo "Bridge       : ${BRIDGE_SEL}"
echo "Storage VM   : ${STORAGE}"
echo "ISO Storage  : ${ISO_STORAGE_SEL}"
echo "ISO File     : ${ISO_FILE}"
echo "MAC Address  : ${MACADDR}"
echo "IP esperado  : ${PBS_IP} (via DHCP reservation no router)"
echo "USB externo  : ${USB_BACKUP_ID}"
echo
confirm "Criar a PBS VM com estes parâmetros" || die "Operação cancelada."

print_step "STEP 3" "Criar VM"
qm create "${VMID}" \
 --name "${NAME}" \
 --machine q35 \
 --bios ovmf \
 --ostype l26 \
 --cpu host \
 --cores "${CORES}" \
 --sockets 1 \
 --memory "${MEMORY}" \
 --balloon 0 \
 --agent 1 \
 --onboot 1 \
 --scsihw virtio-scsi-single \
 --net0 virtio="${MACADDR}",bridge="${BRIDGE_SEL}" \
 --serial0 socket \
 --vga std

qm set "${VMID}" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
qm set "${VMID}" --scsi0 "${STORAGE}:${DISK_SIZE}"
qm set "${VMID}" --ide2 "${ISO_STORAGE_SEL}:iso/${ISO_FILE},media=cdrom"
qm set "${VMID}" --boot order='ide2;scsi0'
ok "ISO PBS associado: ${ISO_STORAGE_SEL}:iso/${ISO_FILE}"
ok "Boot order definido para ide2;scsi0"

if [[ -n "${USB_BACKUP_ID}" && "${USB_BACKUP_ID}" != "skip" ]]; then
 qm set "${VMID}" --usb0 "host=${USB_BACKUP_ID}"
 ok "Disco externo USB associado à PBS: ${USB_BACKUP_ID}"
else
 warn "Nenhum disco externo USB foi associado agora à PBS."
 info "Podes associá-lo mais tarde no hardware da VM."
fi


ok "PBS VM criada."

print_step "STEP 4" "Configuração final da VM PBS"
qm config "${VMID}"

print_step "STEP 5" "Instalação assistida do PBS"
info "A VM PBS será arrancada agora para instalares o sistema pelo ISO."
qm start "${VMID}" || true
echo "Instalação manual recomendada:"
echo " - Filesystem: ZFS (RAID0)"
echo " - Restante configuração: default"
echo " - Hostname : pbs.forsteri.n5pro"
echo " - IP       : ${PBS_IP}"
echo " - Gateway  : ${GATEWAY}"
echo
echo "Quando terminares a instalação no instalador do PBS:"
echo " 1. deixa o instalador concluir"
echo " 2. volta aqui e carrega ENTER"
echo
read -rp "ENTER quando o PBS já estiver instalado e pronto para reinício..." _
info "A parar a VM PBS para remover a ISO..."
qm stop "${VMID}" --skiplock 1 || true
sleep 3
info "A remover a ISO do hardware..."
qm set "${VMID}" --delete ide2 || true
info "A arrancar novamente a VM PBS já sem ISO..."
qm start "${VMID}" || true
wait_for_pbs_online "${PBS_IP}"
echo
read -r -s -p "$(echo -e "${CYAN}Password root da PBS para injetar n5pro-post (ENTER para saltar): ${RESET}")" PBS_ROOT_PASSWORD
echo
inject_n5pro_tools_into_pbs "${PBS_IP}" "${PBS_ROOT_PASSWORD}"

echo -e "
$LINE"
echo -e "${GREEN}${BOLD}✅ PBS VM pronta.${RESET}"
echo -e "${CYAN}Resumo operacional:${RESET}"
echo "1. A instalação do PBS deve ter sido feita com:"
echo " - Filesystem: ZFS (RAID0)"
echo " - Hostname  : pbs.forsteri.n5pro"
echo " - IP        : ${PBS_IP}"
echo "2. A ISO foi removida automaticamente do hardware."
echo "3. A VM PBS foi arrancada novamente."
echo "4. Se a password foi fornecida, o n5pro-post foi injetado automaticamente na PBS."
echo -e "${GREEN}${BOLD}Depois segue para criar / validar o Unraid (script 03) e mais tarde corre o script 04 dentro da PBS VM.${RESET}"
echo -e "$LINE"
