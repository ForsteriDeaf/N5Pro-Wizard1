#!/usr/bin/env bash
set -e

# ===========================================================
# 01-PVE_Host-PostInstall.sh
# N5 Pro - Proxmox VE 9 / Debian 13 (trixie)
# ===========================================================
# Objetivo:
# - preparar o host Proxmox de forma limpa
# - corrigir repositórios
# - atualizar o sistema
# - opcionalmente remover local-lvm e expandir root
# - criar o storage NVMe-Containers
# - ativar IOMMU para passthrough
# - instalar ferramentas base
# - criar o comando visual n5pro
# - criar o launcher n5pro-post
# - gravar /etc/n5pro.conf
#
# Filosofia:
# - pouca magia
# - passos explícitos
# - mensagens ricas e úteis
# - compatível com estrutura híbrida gist/github
# ===========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
 # shellcheck disable=SC1091
 source "${SCRIPT_DIR}/lib/common.sh"
elif [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
 # shellcheck disable=SC1091
 source "${SCRIPT_DIR}/common.sh"
else
 RED="\033[38;5;196m"
 GREEN="\033[38;5;10m"
 YELLOW="\033[38;5;11m"
 CYAN="\033[38;5;14m"
 RESET="\033[0m"
 BOLD="\033[1m"
 LINE="==========================================================="
 info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
 ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
 warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
 die(){ echo -e "${RED}[ERRO]${RESET} $*"; exit 1; }
 print_header(){ echo -e "$LINE"; echo -e "${GREEN}${BOLD} $*${RESET}"; echo -e "$LINE"; }
 print_step(){ echo -e "\n${YELLOW}[$1] $2${RESET}"; }
 backup_file(){ local f="$1"; [[ -f "$f" ]] || return 0; local d="/root/.script-backups"; local r="${f#/}"; local dst="${d}/${r}.bak.$(date +%Y%m%d-%H%M%S)"; mkdir -p "$(dirname "$dst")"; cp -a "$f" "$dst"; }
 confirm(){ local prompt="$1"; local reply; read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" reply; [[ "${reply,,}" =~ ^y(es)?$ ]]; }
 require_cmds(){ local cmd; for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || die "Comando em falta: ${cmd}"; done; }
fi

print_header "N5 Pro - Proxmox VE 9 Host Post-Install"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
command -v pveversion >/dev/null 2>&1 || die "Isto não parece ser um host Proxmox."
require_cmds lsblk sgdisk wipefs pvcreate vgcreate lvcreate findmnt curl wget apt pvesm

# ===========================================================
# Config base
# ===========================================================
# Define este valor manualmente quando fores publicar a versão
# final no teu gist / repo raw.
N5PRO_REPO_BASE="https://raw.githubusercontent.com/ForsteriDeaf/N5Pro-Wizard1/main/final"

PVE_IP="${PVE_IP:-192.168.50.99}"
UNRAID_IP="${UNRAID_IP:-192.168.50.100}"
PBS_IP="${PBS_IP:-192.168.50.110}"
GATEWAY="${GATEWAY:-192.168.50.1}"
BRIDGE="${BRIDGE:-vmbr0}"

UNRAID_MAC="${UNRAID_MAC:-BC:24:11:05:01:00}"
PBS_MAC="${PBS_MAC:-BC:24:11:05:01:10}"

UNRAID_VMID="${UNRAID_VMID:-100}"
PBS_VMID="${PBS_VMID:-110}"

UNRAID_CORES="${UNRAID_CORES:-8}"
UNRAID_MEMORY="${UNRAID_MEMORY:-16384}"
PBS_CORES="${PBS_CORES:-4}"
PBS_MEMORY="${PBS_MEMORY:-8192}"
PBS_SYSTEM_DISK_GB="${PBS_SYSTEM_DISK_GB:-32}"
PBS_ISO_FILE="${PBS_ISO_FILE:-proxmox-backup-server_4.1-1.iso}"

VM_STORAGE="${VM_STORAGE:-NVMe-Containers}"
ISO_STORAGE="${ISO_STORAGE:-local}"

UNRAID_SATA_PCI="${UNRAID_SATA_PCI:-0000:c1:00.0}"
UNRAID_NVME_PCI="${UNRAID_NVME_PCI:-0000:c3:00.0}"
UNRAID_USB_ID="${UNRAID_USB_ID:-04e8:6300}"
PBS_USB_BACKUP_ID="${PBS_USB_BACKUP_ID:-skip}"

PBS_DATASTORE="${PBS_DATASTORE:-usb-temp}"
PBS_DATASTORE_MOUNT="${PBS_DATASTORE_MOUNT:-/mnt/datastore}"
PBS_DATASTORE_FS="${PBS_DATASTORE_FS:-ext4}"
PBS_BACKUP_DEVICE="${PBS_BACKUP_DEVICE:-/dev/sdb}"

ENABLE_IOMMU="${ENABLE_IOMMU:-true}"
REMOVE_LOCAL_LVM_DEFAULT="${REMOVE_LOCAL_LVM_DEFAULT:-false}"
CREATE_NVME_CONTAINERS_DEFAULT="${CREATE_NVME_CONTAINERS_DEFAULT:-true}"

disable_repo_file() {
 local f="$1"
 [[ -e "$f" ]] || return 0
 mv "$f" "${f}.disabled"
 info "Desativado: $f"
}

detect_bootloader() {
 if [[ -d /sys/firmware/efi ]] && command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -f /etc/kernel/cmdline ]]; then
  echo "systemd-boot"
 else
  echo "grub"
 fi
}

detect_cpu_vendor() {
 if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  echo "amd"
 elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
  echo "intel"
 else
  echo "unknown"
 fi
}

print_step "STEP 1" "Configurar repositórios limpos"
mkdir -p /etc/apt/sources.list.d

disable_repo_file /etc/apt/sources.list.d/pve-enterprise.list
disable_repo_file /etc/apt/sources.list.d/pve-enterprise.sources
disable_repo_file /etc/apt/sources.list.d/ceph.list
disable_repo_file /etc/apt/sources.list.d/ceph.sources

rm -f /etc/apt/sources.list.d/pve-no-subscription.list
rm -f /etc/apt/sources.list.d/pve-no-subscription.sources

if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
 backup_file /etc/apt/sources.list.d/debian.sources
 cat >/etc/apt/sources.list.d/debian.sources <<'EOF2'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF2
 echo -n > /etc/apt/sources.list
 info "debian.sources atualizado."
fi

cat >/etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF2'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF2

ok "Repositórios configurados."

print_step "STEP 2" "Atualizar sistema"
apt update
apt dist-upgrade -y
ok "Sistema atualizado."

print_step "STEP 3" "Remover local-lvm e expandir root (opcional)"
REMOVE_LVM_REPLY="n"
[[ "${REMOVE_LOCAL_LVM_DEFAULT}" == "true" ]] && REMOVE_LVM_REPLY="y"
read -rp "$(echo -e "${YELLOW}Queres remover local-lvm agora? [default=${REMOVE_LVM_REPLY}] [y/N]: ${RESET}")" REMOVE_LVM
REMOVE_LVM="${REMOVE_LVM:-$REMOVE_LVM_REPLY}"

if [[ "${REMOVE_LVM,,}" =~ ^y(es)?$ ]]; then
 pvesm remove local-lvm 2>/dev/null || true
 lvremove -f /dev/pve/data 2>/dev/null || true
 lvextend -l +100%FREE /dev/pve/root || true

 FS="$(findmnt -n -o FSTYPE /)"
 ROOT_SRC="$(findmnt -n -o SOURCE /)"

 if [[ "$FS" == "xfs" ]]; then
  xfs_growfs /
 elif [[ "$FS" == "ext4" || "$FS" == "ext3" || "$FS" == "ext2" ]]; then
  resize2fs "$ROOT_SRC" || true
 else
  warn "Filesystem do root não suportado automaticamente: ${FS}"
  info "Origem do root: ${ROOT_SRC}"
 fi

 ok "local-lvm removido e root expandido."
else
 info "local-lvm mantido."
fi

print_step "STEP 4" "Criar NVMe-Containers (LVM Thin Pool)"
if [[ "${CREATE_NVME_CONTAINERS_DEFAULT}" != "true" ]]; then
 warn "CREATE_NVME_CONTAINERS_DEFAULT=false -> passo ignorado por configuração."
else
 echo -e "${BLUE}Discos NVMe disponíveis:${RESET}"

 mapfile -t NVME_DISKS < <(lsblk -d -n -o NAME,SIZE,MODEL | awk '$1 ~ /^nvme/')
 [[ ${#NVME_DISKS[@]} -gt 0 ]] || die "Nenhum disco NVMe encontrado."

 for i in "${!NVME_DISKS[@]}"; do
  echo "[$i] ${NVME_DISKS[$i]}"
 done

 read -rp "$(echo -e "${CYAN}Seleciona o índice do NVMe para ${VM_STORAGE}: ${RESET}")" DISK_INDEX
 DISK_NAME=$(echo "${NVME_DISKS[$DISK_INDEX]}" | awk '{print $1}')
 DISK="/dev/${DISK_NAME}"

 [[ -b "$DISK" ]] || die "Disco inválido: ${DISK}"

 echo -e "${YELLOW}O disco selecionado é: ${DISK}${RESET}"
 confirm "Confirmas apagar este disco para ${VM_STORAGE}?" || die "Operação cancelada."

 pvesm remove "${VM_STORAGE}" 2>/dev/null || true
 lvremove -f "${VM_STORAGE}/thin-pool" 2>/dev/null || true
 vgremove -f "${VM_STORAGE}" 2>/dev/null || true
 pvremove -ff "$DISK" 2>/dev/null || true
 wipefs -a "$DISK"
 sgdisk --zap-all "$DISK"

 pvcreate "$DISK"
 vgcreate "${VM_STORAGE}" "$DISK"
 lvcreate -l 100%FREE -T "${VM_STORAGE}/thin-pool" --chunksize 128K --zero n
 pvesm add lvmthin "${VM_STORAGE}" --vgname "${VM_STORAGE}" --thinpool thin-pool

 ok "${VM_STORAGE} criado em ${DISK}."
fi

print_step "STEP 5" "Ativar IOMMU"
if [[ "${ENABLE_IOMMU}" == "true" ]]; then
 BOOTLOADER="$(detect_bootloader)"
 CPU_VENDOR="$(detect_cpu_vendor)"

 info "Bootloader detetado: ${BOOTLOADER}"
 info "CPU detetado: ${CPU_VENDOR}"

 if [[ "$CPU_VENDOR" == "intel" ]]; then
  IOMMU_ARGS="intel_iommu=on iommu=pt"
 elif [[ "$CPU_VENDOR" == "amd" ]]; then
  IOMMU_ARGS="amd_iommu=on iommu=pt"
 else
  IOMMU_ARGS="iommu=pt"
 fi

 if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  backup_file /etc/kernel/cmdline
  if ! grep -Eq 'iommu=pt|intel_iommu=on|amd_iommu=on' /etc/kernel/cmdline; then
   sed -i "s/$/ ${IOMMU_ARGS}/" /etc/kernel/cmdline
   info "Parâmetros IOMMU adicionados a /etc/kernel/cmdline"
  else
   info "Parâmetros de IOMMU já estavam presentes."
  fi
  proxmox-boot-tool refresh || true
 else
  backup_file /etc/default/grub
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
   if ! grep -Eq 'iommu=pt|intel_iommu=on|amd_iommu=on' /etc/default/grub; then
    sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"/\1 ${IOMMU_ARGS}\"/" /etc/default/grub
   fi
  else
   echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet ${IOMMU_ARGS}\"" >> /etc/default/grub
  fi
  update-grub || true
 fi

 cat >/etc/modules-load.d/vfio.conf <<'EOF2'
vfio
vfio_iommu_type1
vfio_pci
EOF2

 update-initramfs -u -k all || true
 ok "IOMMU preparada."
else
 warn "ENABLE_IOMMU=false -> passo ignorado."
fi

print_step "STEP 5.1" "Confirmar timezone"
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ -n "$CURRENT_TZ" ]]; then
 info "Timezone atual detetado: ${CURRENT_TZ}"
 read -rp "$(echo -e "${YELLOW}Manter este timezone? [Y/n]: ${RESET}")" KEEP_TZ
 if [[ ! "${KEEP_TZ,,}" =~ ^n(o)?$ ]]; then
  ok "Timezone mantido: ${CURRENT_TZ}"
 else
  read -rp "$(echo -e "${CYAN}Introduz o timezone pretendido (ex: Europe/Lisbon, Atlantic/Azores): ${RESET}")" NEW_TZ
  if timedatectl list-timezones | grep -qx "$NEW_TZ"; then
   timedatectl set-timezone "$NEW_TZ"
   ok "Timezone alterado para: ${NEW_TZ}"
  else
   die "Timezone inválido: ${NEW_TZ}"
  fi
 fi
else
 warn "Não foi possível detetar o timezone atual."
fi

print_step "STEP 6" "Instalar firmware e ferramentas essenciais"
apt install -y \
 amd64-microcode \
 pve-firmware \
 fastfetch \
 btop \
 iotop \
 iftop \
 htop \
 unzip \
 zip \
 dos2unix \
 etherwake \
 nvme-cli \
 pciutils \
 usbutils \
 curl \
 wget \
 git \
 jq \
 tree \
 vim \
 nano \
 mc \
 lsof \
 rsync \
 nfs-common \
 smartmontools \
 sshpass \
 ethtool
ok "Ferramentas instaladas."

print_step "STEP 7" "Configurar Bash com cores"
backup_file ~/.bashrc
cat <<'EOF2' > ~/.bashrc
export TERM=xterm-256color
PS1='\[\033[38;5;196m\]\u\[\033[38;5;10m\]@\[\033[38;5;11m\]\h\[\033[00m\]:\[\033[38;5;21m\]\w\[\033[38;5;11m\]\$\[\033[00m\] '
alias ll='ls -la --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias btop='btop --utf-force'
EOF2
ok "Bash configurado."

print_step "STEP 8" "Gravar /etc/n5pro.conf"
cat >/etc/n5pro.conf <<EOF2
N5PRO_REPO_BASE="${N5PRO_REPO_BASE}"
PVE_IP="${PVE_IP}"
UNRAID_IP="${UNRAID_IP}"
PBS_IP="${PBS_IP}"
GATEWAY="${GATEWAY}"
BRIDGE="${BRIDGE}"
UNRAID_MAC="${UNRAID_MAC}"
PBS_MAC="${PBS_MAC}"
UNRAID_VMID="${UNRAID_VMID}"
PBS_VMID="${PBS_VMID}"
UNRAID_CORES="${UNRAID_CORES}"
UNRAID_MEMORY="${UNRAID_MEMORY}"
PBS_CORES="${PBS_CORES}"
PBS_MEMORY="${PBS_MEMORY}"
PBS_SYSTEM_DISK_GB="${PBS_SYSTEM_DISK_GB}"
PBS_ISO_FILE="${PBS_ISO_FILE}"
VM_STORAGE="${VM_STORAGE}"
ISO_STORAGE="${ISO_STORAGE}"
UNRAID_SATA_PCI="${UNRAID_SATA_PCI}"
UNRAID_NVME_PCI="${UNRAID_NVME_PCI}"
UNRAID_USB_ID="${UNRAID_USB_ID}"
PBS_USB_BACKUP_ID="${PBS_USB_BACKUP_ID}"
PBS_DATASTORE="${PBS_DATASTORE}"
PBS_DATASTORE_MOUNT="${PBS_DATASTORE_MOUNT}"
PBS_DATASTORE_FS="${PBS_DATASTORE_FS}"
PBS_BACKUP_DEVICE="${PBS_BACKUP_DEVICE}"
ENABLE_IOMMU="${ENABLE_IOMMU}"
REMOVE_LOCAL_LVM_DEFAULT="${REMOVE_LOCAL_LVM_DEFAULT}"
CREATE_NVME_CONTAINERS_DEFAULT="${CREATE_NVME_CONTAINERS_DEFAULT}"
EOF2
chmod 600 /etc/n5pro.conf
ok "/etc/n5pro.conf criado/atualizado."

print_step "STEP 8.1" "Instalar common.sh local"
mkdir -p /usr/local/lib/n5pro
cat >/usr/local/lib/n5pro/common.sh <<'EOF2'
#!/usr/bin/env bash
# ===========================================================
# common.sh
# Helpers partilhados para o N5 Pro Homelab Wizard
# ===========================================================

RED="\033[38;5;196m"
GREEN="\033[38;5;10m"
YELLOW="\033[38;5;11m"
BLUE="\033[38;5;21m"
MAGENTA="\033[38;5;13m"
CYAN="\033[38;5;14m"
RESET="\033[0m"
BOLD="\033[1m"
LINE="==========================================================="

info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die(){ echo -e "${RED}[ERRO]${RESET} $*"; exit 1; }

print_header(){
 echo -e "$LINE"
 echo -e "${GREEN}${BOLD} $*${RESET}"
 echo -e "$LINE"
}

print_step(){
 echo -e "\n${YELLOW}[$1] $2${RESET}"
}

backup_file(){
 local f="$1"
 [[ -f "$f" ]] || return 0
 local d="/root/.script-backups"
 local r="${f#/}"
 local dst="${d}/${r}.bak.$(date +%Y%m%d-%H%M%S)"
 mkdir -p "$(dirname "$dst")"
 cp -a "$f" "$dst"
}

ask_default(){
 local prompt="$1"
 local default="$2"
 local reply
 read -rp "$(echo -e "${CYAN}${prompt} [${default}]: ${RESET}")" reply
 echo "${reply:-$default}"
}

confirm(){
 local prompt="$1"
 local reply
 read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" reply
 [[ "${reply,,}" =~ ^y(es)?$ ]]
}

require_cmds(){
 local cmd
 for cmd in "$@"; do
  command -v "$cmd" >/dev/null 2>&1 || die "Comando em falta: ${cmd}"
 done
}

load_n5pro_config(){
 if [[ -f /etc/n5pro.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/n5pro.conf
 else
  die "Configuração não encontrada: /etc/n5pro.conf"
 fi
}

hybrid_source_common(){
 local script_dir
 script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
 if [[ -f /usr/local/lib/n5pro/common.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/lib/n5pro/common.sh
 elif [[ -f "${script_dir}/lib/common.sh" ]]; then
  # shellcheck disable=SC1091
  source "${script_dir}/lib/common.sh"
 elif [[ -f "${script_dir}/common.sh" ]]; then
  # shellcheck disable=SC1091
  source "${script_dir}/common.sh"
 else
  echo "[ERRO] common.sh não encontrado." >&2
  exit 1
 fi
}
EOF2
chmod 644 /usr/local/lib/n5pro/common.sh
ok "common.sh local instalado em /usr/local/lib/n5pro/common.sh"

print_step "STEP 9" "Criar script n5pro visual"
cat <<'EOF2' > /usr/local/bin/n5pro
#!/usr/bin/env bash
LINE="==========================================================="
echo -e "$LINE"
echo -e "\033[38;5;196m N5Pro Proxmox Visual Status \033[0m"
echo -e "$LINE"
[[ -f /etc/n5pro.conf ]] && source /etc/n5pro.conf
echo "[CHECK] Repo base..."; echo "${N5PRO_REPO_BASE:-não configurado}"
echo "[CHECK] Hostname..."; hostname
echo "[CHECK] Versão Proxmox..."; pveversion
echo "[CHECK] Root filesystem..."; findmnt /
echo "[CHECK] Storages..."; pvesm status || true
echo "[CHECK] NVMe-Containers..."; vgs ${VM_STORAGE:-NVMe-Containers} 2>/dev/null || echo "[WARN] ${VM_STORAGE:-NVMe-Containers} não encontrado"
echo "[CHECK] IOMMU..."; grep -Eq 'iommu=pt|intel_iommu=on|amd_iommu=on' /proc/cmdline && echo "[OK] IOMMU ativa" || echo "[WARN] IOMMU desativada"
echo "[CHECK] Timezone..."; timedatectl | sed -n '1,6p'
echo "[CHECK] VMs..."; qm list || true
echo "[CHECK] CTs..."; pct list || true
echo -e "$LINE"
echo "[OK] Status visual completo!"
echo -e "$LINE"
EOF2
chmod +x /usr/local/bin/n5pro
ok "n5pro instalado."

print_step "STEP 10" "Criar launcher n5pro-post"
cat <<'EOF2' > /usr/local/bin/n5pro-post
#!/usr/bin/env bash
set -e
[[ -f /etc/n5pro.conf ]] || { echo "[ERRO] /etc/n5pro.conf não encontrado"; exit 1; }
source /etc/n5pro.conf
DRY_RUN="false"

repo_check(){ [[ -n "${N5PRO_REPO_BASE:-}" ]]; }

run_remote(){
 local script_name="$1"
 if ! repo_check; then
  echo "[ERRO] N5PRO_REPO_BASE não está definido corretamente em /etc/n5pro.conf"
  exit 1
 fi
 if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] bash <(curl -fsSL \"${N5PRO_REPO_BASE}/${script_name}\")"
 else
  bash <(curl -fsSL "${N5PRO_REPO_BASE}/${script_name}")
 fi
}

detect_mode(){
 if command -v pveversion >/dev/null 2>&1; then
  echo "PVE"
 elif command -v proxmox-backup-manager >/dev/null 2>&1; then
  echo "PBS"
 else
  echo "UNKNOWN"
 fi
}

wizard_pve_core() {
 clear
 echo "==========================================================="
 echo " N5Pro Wizard - PVE / Core"
 echo "==========================================================="
 echo "Este modo faz:"
 echo " 1) Validar ISO do PBS"
 echo " 2) 02-PBServer_PVE-CreateVM.sh"
 echo " 3) 03-Unraid-NAS_PVE-CreateVM.sh"
 echo "==========================================================="

 ISO_FOUND=""
 if command -v pvesm >/dev/null 2>&1; then
  ISO_FOUND="$(pvesm list local 2>/dev/null | awk 'NR>1 {print $1}' | grep -i 'proxmox-backup-server.*\\.iso\\|pbs.*\\.iso' | head -n1 || true)"
 fi

 if [[ -n "$ISO_FOUND" ]]; then
  echo "[OK] ISO PBS encontrado em local:iso -> ${ISO_FOUND}"
 else
  echo "[WARN] ISO do Proxmox Backup Server NÃO encontrado em local:iso"
  echo "Coloca o ISO em:"
  echo " Datacenter -> pve -> local -> ISO Images"
  echo
  read -rp "Continuar mesmo assim? [y/N]: " ans_iso
  [[ "${ans_iso,,}" =~ ^y(es)?$ ]] || return 0
 fi

 echo
 read -rp "Queres continuar? [y/N]: " ans
 [[ "${ans,,}" =~ ^y(es)?$ ]] || return 0

 run_remote "02-PBServer_PVE-CreateVM.sh"
 run_remote "03-Unraid-NAS_PVE-CreateVM.sh"

 echo
 echo "==========================================================="
 echo " Próximos passos manuais"
 echo "==========================================================="
 echo " - O script 02 cria a PBS, ajuda na instalação e remove a ISO depois"
 echo " - Instalar / arrancar o Unraid"
 echo " - Entrar na PBS e correr: n5pro-post"
 echo "==========================================================="
 read -rp "Enter para continuar..." _
}


pbs_wizard(){
 clear
 echo "==========================================================="
 echo " N5Pro Wizard - PBS"
 echo "==========================================================="
 echo "Este modo faz:"
 echo " 1) 04-PBServer_PBS-PostInstall.sh"
 echo "==========================================================="
 read -rp "Queres continuar? [y/N]: " ans
 [[ "${ans,,}" =~ ^y(es)?$ ]] || return 0
 run_remote "04-PBServer_PBS-PostInstall.sh"
 echo
 echo "==========================================================="
 echo " Próximos passos"
 echo "==========================================================="
 echo " - Voltar à PVE"
 echo " - Correr: n5pro-post"
 echo " - Escolher finalizar PBS no Proxmox"
 echo "==========================================================="
 read -rp "Enter para continuar..." _
}

pve_wizard_finalize(){
 clear
 echo "==========================================================="
 echo " N5Pro Wizard - PVE / Finalize"
 echo "==========================================================="
 echo "Este modo faz:"
 echo " 1) 05-PVE_PBS-AddStorage.sh"
 echo " 2) 06-PVE_PBS-CreateBackupJob.sh"
 echo "==========================================================="
 read -rp "Queres continuar? [y/N]: " ans
 [[ "${ans,,}" =~ ^y(es)?$ ]] || return 0
 run_remote "05-PVE_PBS-AddStorage.sh"
 run_remote "06-PVE_PBS-CreateBackupJob.sh"
 read -rp "Enter para continuar..." _
}

while true; do
 MODE="$(detect_mode)"
 clear
 echo "==========================================================="
 echo " N5Pro Post Menu - Wizard"
 echo "==========================================================="
 echo "Host      : $(hostname)"
 echo "Modo      : ${MODE}"
 echo "Repo base : ${N5PRO_REPO_BASE}"
 echo "Dry-run   : ${DRY_RUN}"
 echo "==========================================================="
 if [[ "${MODE}" == "PVE" ]]; then
  echo "1) Ver estado do host (n5pro)"
  echo "2) Alternar dry-run"
  echo "3) Wizard: criar PBS VM + Unraid VM"
  echo "4) Wizard: adicionar PBS + criar jobs"
  echo "5) Manual: 02-PBServer_PVE-CreateVM.sh"
  echo "6) Manual: 03-Unraid-NAS_PVE-CreateVM.sh"
  echo "7) Manual: 05-PVE_PBS-AddStorage.sh"
  echo "8) Manual: 06-PVE_PBS-CreateBackupJob.sh"
  echo "9) Mostrar /etc/n5pro.conf"
  echo "0) Sair"
  read -rp "Escolha: " opt
  case "$opt" in
   1) n5pro; read -rp "Enter para continuar..." _ ;;
   2) [[ "$DRY_RUN" == "true" ]] && DRY_RUN="false" || DRY_RUN="true" ;;
   3) pve_wizard_core ;;
   4) pve_wizard_finalize ;;
   5) run_remote "02-PBServer_PVE-CreateVM.sh"; read -rp "Enter para continuar..." _ ;;
   6) run_remote "03-Unraid-NAS_PVE-CreateVM.sh"; read -rp "Enter para continuar..." _ ;;
   7) run_remote "05-PVE_PBS-AddStorage.sh"; read -rp "Enter para continuar..." _ ;;
   8) run_remote "06-PVE_PBS-CreateBackupJob.sh"; read -rp "Enter para continuar..." _ ;;
   9) cat /etc/n5pro.conf; read -rp "Enter para continuar..." _ ;;
   0) exit 0 ;;
  esac
 elif [[ "${MODE}" == "PBS" ]]; then
  echo "1) Alternar dry-run"
  echo "2) Wizard: preparar datastore PBS"
  echo "3) Manual: 04-PBServer_PBS-PostInstall.sh"
  echo "4) Mostrar datastores PBS"
  echo "5) Mostrar /etc/n5pro.conf"
  echo "0) Sair"
  read -rp "Escolha: " opt
  case "$opt" in
   1) [[ "$DRY_RUN" == "true" ]] && DRY_RUN="false" || DRY_RUN="true" ;;
   2) pbs_wizard ;;
   3) run_remote "04-PBServer_PBS-PostInstall.sh"; read -rp "Enter para continuar..." _ ;;
   4) proxmox-backup-manager datastore list || true; read -rp "Enter para continuar..." _ ;;
   5) cat /etc/n5pro.conf; read -rp "Enter para continuar..." _ ;;
   0) exit 0 ;;
  esac
 else
  echo "Ambiente não reconhecido."
  exit 1
 fi
done
EOF2
chmod +x /usr/local/bin/n5pro-post
ok "n5pro-post instalado."

echo -e "\n$LINE"
echo -e "${GREEN}${BOLD}✅ Post-install concluído.${RESET}"
echo -e "${CYAN}Repo base guardado em /etc/n5pro.conf:${RESET} ${N5PRO_REPO_BASE}"
echo -e "${YELLOW}${BOLD}REBOOT NOW antes do passo seguinte.${RESET}"
echo -e "${GREEN}Depois do reboot, corre: n5pro${RESET}"
echo -e "${GREEN}Depois usa: n5pro-post${RESET}"
echo -e "$LINE"
