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
print_header "N5 Pro - Create Unraid-NAS VM (ordem nova: depois da PBS)"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
require_cmds qm pvesm lspci lsusb awk grep

vm_exists(){ qm status "$1" >/dev/null 2>&1; }

detect_bridge() {
 grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null && { echo "vmbr0"; return; }
 awk '/^auto vmbr/ {print $2; exit}' /etc/network/interfaces 2>/dev/null
}

detect_image_storage() {
 if pvesm status | awk 'NR>1 {print $1}' | grep -qx "${VM_STORAGE}"; then
  echo "${VM_STORAGE}"
  return
 fi
 pvesm status | awk 'NR>1 && $2=="lvmthin" {print $1; exit}'
}

detect_sata_controller() {
 lspci -Dnn | awk '/SATA controller/ && /JMicron|ASM|ASMedia|Marvell|AHCI/ {print $1; exit}'
}

detect_nvme_controller() {
 lspci -Dnn | awk '
 /Non-Volatile memory controller/ && /Lexar/ {print $1; found=1; exit}
 END {if (!found) exit 0}
 '
}

detect_unraid_usb() {
 lsusb | awk '/Flash Drive|Mass Storage|USB DISK|Samsung/ {print $6; exit}'
}

show_relevant_devices() {
 echo -e "${BLUE}PCI relevantes:${RESET}"
 lspci -Dnn | grep -E 'SATA controller|Non-Volatile memory controller|Ethernet controller' || true
 echo
 echo -e "${BLUE}USB relevantes:${RESET}"
 lsusb || true
 echo
}

validate_storage() {
 pvesm status | awk 'NR>1 {print $1}' | grep -qx "$1" || die "Storage inválido: $1"
}

validate_pci() {
 lspci -Dnn | awk '{print $1}' | grep -qx "$2" || die "PCI inválido para $1: $2"
}

validate_usb() {
 lsusb | awk '{print $6}' | grep -qx "$1" || die "USB inválido: $1"
}

print_step "STEP 1" "Validar IOMMU"
if grep -Eiq 'iommu=pt|intel_iommu=on|amd_iommu=on' /proc/cmdline; then
 ok "IOMMU ativa."
else
 die "IOMMU não está ativa em /proc/cmdline. Corre primeiro o script 01, reinicia e tenta de novo."
fi

print_step "STEP 2" "Deteção automática do hardware"
DEFAULT_BRIDGE="$(detect_bridge)"
DEFAULT_STORAGE="$(detect_image_storage)"
DEFAULT_SATA="$(detect_sata_controller)"
DEFAULT_NVME="$(detect_nvme_controller)"
DEFAULT_USB="$(detect_unraid_usb)"

show_relevant_devices
info "Bridge detetada       : ${DEFAULT_BRIDGE:-não encontrado}"
info "Storage detetado      : ${DEFAULT_STORAGE:-não encontrado}"
info "SATA controller       : ${DEFAULT_SATA:-não encontrado}"
info "NVMe passthrough      : ${DEFAULT_NVME:-não encontrado}"
info "USB Unraid            : ${DEFAULT_USB:-não encontrado}"

VMID="$(ask_default "VMID da VM" "${UNRAID_VMID}")"
NAME="$(ask_default "Nome da VM" "Unraid-NAS")"
CORES="$(ask_default "Número de cores" "${UNRAID_CORES}")"
MEMORY="$(ask_default "RAM em MB" "${UNRAID_MEMORY}")"
BRIDGE_SEL="$(ask_default "Bridge de rede" "${DEFAULT_BRIDGE:-vmbr0}")"
STORAGE="$(ask_default "Storage para EFI/config" "${DEFAULT_STORAGE:-${VM_STORAGE}}")"
SATA_PCI="$(ask_default "PCI do SATA controller (discos dados/parity)" "${DEFAULT_SATA:-${UNRAID_SATA_PCI}}")"
NVME_PCI="$(ask_default "PCI do NVMe para boot/cache Unraid" "${DEFAULT_NVME:-${UNRAID_NVME_PCI}}")"
USB_ID="$(ask_default "USB vendor:product da pen Unraid" "${DEFAULT_USB:-${UNRAID_USB_ID}}")"
MACADDR="$(ask_default "MAC address da VM" "${UNRAID_MAC}")"

vm_exists "${VMID}" && die "VMID ${VMID} já existe."
validate_storage "${STORAGE}"
validate_pci "SATA controller" "${SATA_PCI}"
validate_pci "NVMe passthrough" "${NVME_PCI}"
validate_usb "${USB_ID}"

print_step "STEP 3" "Resumo final"
show_relevant_devices
echo -e "${MAGENTA}${BOLD}Configuração final da VM:${RESET}"
echo "VMID            : ${VMID}"
echo "Nome            : ${NAME}"
echo "Cores           : ${CORES}"
echo "RAM (MB)        : ${MEMORY}"
echo "Bridge          : ${BRIDGE_SEL}"
echo "MAC Address     : ${MACADDR}"
echo "IP esperado     : ${UNRAID_IP} (via DHCP reservation no router)"
echo "Storage EFI     : ${STORAGE}"
echo "SATA controller : ${SATA_PCI}"
echo "NVMe passthrough: ${NVME_PCI}"
echo "USB Unraid      : ${USB_ID}"
echo
confirm "Criar a VM Unraid-NAS com estes parâmetros" || die "Operação cancelada."

print_step "STEP 4" "Criar VM base"
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
 --agent 0 \
 --onboot 1 \
 --scsihw virtio-scsi-single \
 --net0 virtio="${MACADDR}",bridge="${BRIDGE_SEL}" \
 --serial0 socket \
 --vga vmware

qm set "${VMID}" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
ok "VM base criada."

print_step "STEP 5" "Associar passthrough"
qm set "${VMID}" --hostpci0 "${SATA_PCI},pcie=1"
ok "SATA controller associado: ${SATA_PCI}"

qm set "${VMID}" --hostpci1 "${NVME_PCI},pcie=1"
ok "NVMe associado: ${NVME_PCI}"

qm set "${VMID}" --usb0 "host=${USB_ID}"
ok "Pen Unraid associada: ${USB_ID}"

qm set "${VMID}" --boot order='hostpci1;usb0'
ok "Ordem de boot definida para NVMe passthrough primeiro e USB como fallback."

print_step "STEP 6" "Configuração final"
qm config "${VMID}"

echo -e "\n$LINE"
echo -e "${GREEN}${BOLD}✅ VM Unraid-NAS criada com sucesso.${RESET}"
echo -e "${CYAN}Próximos passos:${RESET}"
echo "1. Abrir a consola da Unraid VM no Proxmox."
echo "2. Confirmar que o Unraid arranca pelo NVMe passthrough (cache/boot novo do Unraid 7.3)."
echo "3. A pen USB fica associada sobretudo para licença e fallback de arranque."
echo "4. Arrancar o Unraid."
echo "5. Confirmar no router ASUS a lease/reserva:"
echo " - MAC: ${MACADDR}"
echo " - IP : ${UNRAID_IP}"
echo "6. Criar/confirmar as shares lógicas principais:"
echo " - apps   (novo naming; substitui referências antigas como pool_appdata)"
echo " - domains"
echo " - system"
echo " - isos"
echo " - storage_1tb"
echo " - storage_3tb"
echo " - storage_4tb"
echo -e "${GREEN}${BOLD}Depois instala / valida o Unraid e, quando a PBS estiver pronta, corre o script 04 dentro da PBS VM.${RESET}"
echo -e "$LINE"
