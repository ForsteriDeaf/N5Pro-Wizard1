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
print_header "PBS VM - Post Install + Datastore Externo"

[[ "$EUID" -eq 0 ]] || die "Corre este script como root."
require_cmds apt-get lsblk gdisk parted wipefs blkid findmnt proxmox-backup-manager

detect_data_disk(){
 lsblk -dpno NAME,TYPE,SIZE,MODEL | awk '$2=="disk" {print $1" "$3" "$4" "$5" "$6}'
}

list_usb_disks() {
 lsblk -dpno NAME,SIZE,MODEL,TRAN | awk '$4=="usb" {print $1"|"$2"|"$3}'
}

select_usb_disk_menu() {
 local lines=()
 local i=1
 mapfile -t lines < <(list_usb_disks)
 echo "0) introduzir manualmente"
 echo "1) skip"
 if [[ ${#lines[@]} -gt 0 ]]; then
  for entry in "${lines[@]}"; do
   IFS='|' read -r name size model <<<"$entry"
   echo "$((i+1))) ${name} (${size} ${model})"
   i=$((i+1))
  done
 fi
 local choice
 read -rp "Escolha do disco USB: " choice
 if [[ -z "$choice" || "$choice" == "1" ]]; then
  echo "skip"
  return
 fi
 if [[ "$choice" == "0" ]]; then
  read -rp "Introduz o disco manualmente (ex: /dev/sdb): " manual
  echo "$manual"
  return
 fi
 local idx=$((choice-2))
 if [[ $idx -ge 0 && $idx -lt ${#lines[@]} ]]; then
  IFS='|' read -r name _ <<<"${lines[$idx]}"
  echo "$name"
 else
  echo "skip"
 fi
}

get_uuid(){
 blkid -s UUID -o value "$1" 2>/dev/null || true
}

print_step "STEP 0" "Nota de compatibilidade"
info "A estrutura antiga usava PBS sobre NFS do Unraid."
info "Nesta versão, a forma foi preservada, mas o backend correto é disco externo direto na PBS VM."
echo "  Modelo antigo : PBS VM -> NFS -> Unraid -> datastore"
echo "  Modelo atual  : PBS VM -> disco externo direto -> datastore PBS"

print_step "STEP 1" "Repos e pacotes base"
mkdir -p /etc/apt/sources.list.d
for f in /etc/apt/sources.list.d/*; do
 [[ -e "$f" ]] || continue
 if grep -q 'enterprise.proxmox.com' "$f" 2>/dev/null; then
  mv "$f" "${f}.disabled"
  info "Desativado: $f"
 fi
done

cat >/etc/apt/sources.list.d/pbs-no-subscription.sources <<'EOF2'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF2

apt-get update
apt-get install -y nano curl wget lsblk gdisk parted e2fsprogs xfsprogs smartmontools usbutils
ok "Pacotes instalados."

print_step "STEP 2" "Deteção dos discos disponíveis"
echo "Discos atualmente visíveis na PBS VM:"
detect_data_disk || true
echo
info "Discos USB detetados:"
list_usb_disks | sed 's/|/ /g' || true
SELECTED_USB="$(select_usb_disk_menu)"
if [[ "$SELECTED_USB" == "skip" || -z "$SELECTED_USB" ]]; then
 DATA_DISK="$(ask_default "Disco do datastore PBS" "${PBS_BACKUP_DEVICE}")"
else
 DATA_DISK="$SELECTED_USB"
 info "Disco USB escolhido: ${DATA_DISK}"
fi
DATA_PART="${DATA_DISK}1"
MOUNTPOINT="$(ask_default "Mountpoint do datastore" "${PBS_DATASTORE_MOUNT}")"
DATASTORE_NAME="$(ask_default "Nome do datastore PBS" "${PBS_DATASTORE}")"
DATASTORE_PATH="${MOUNTPOINT}/${DATASTORE_NAME}"
FS_TYPE="$(ask_default "Filesystem para o disco externo (ext4/xfs)" "${PBS_DATASTORE_FS}")"

[[ -b "${DATA_DISK}" ]] || die "Disco inválido: ${DATA_DISK}"

print_step "STEP 3" "Resumo final"
echo "Disco       : ${DATA_DISK}"
echo "Partição    : ${DATA_PART}"
echo "Mountpoint  : ${MOUNTPOINT}"
echo "Datastore   : ${DATASTORE_NAME}"
echo "Path final  : ${DATASTORE_PATH}"
echo "Filesystem  : ${FS_TYPE}"
echo
confirm "Confirmas continuar e preparar este disco?" || die "Operação cancelada."
if proxmox-backup-manager datastore list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${DATASTORE_NAME}"; then
 warn "Datastore ${DATASTORE_NAME} já existe."
 if ! confirm "Queres recriar/preparar o disco mesmo assim?"; then
  info "Nada a fazer no datastore existente."
  exit 0
 fi
fi

print_step "STEP 4" "Preparar disco externo"
wipefs -a "${DATA_DISK}"
sgdisk --zap-all "${DATA_DISK}"
parted -s "${DATA_DISK}" mklabel gpt
parted -s "${DATA_DISK}" mkpart primary 1MiB 100%
partprobe "${DATA_DISK}"
sleep 2

if [[ "${FS_TYPE}" == "xfs" ]]; then
 mkfs.xfs -f "${DATA_PART}"
else
 mkfs.ext4 -F "${DATA_PART}"
fi
ok "Disco preparado."

print_step "STEP 5" "Configurar fstab e mountpoint"
mkdir -p "${MOUNTPOINT}"
UUID="$(get_uuid "${DATA_PART}")"
[[ -n "${UUID}" ]] || die "Não foi possível obter UUID de ${DATA_PART}"

backup_file /etc/fstab
grep -Ev "^[^#]*[[:space:]]+${MOUNTPOINT}[[:space:]]" /etc/fstab > /tmp/fstab.pbs 2>/dev/null || true
echo "UUID=${UUID} ${MOUNTPOINT} ${FS_TYPE} defaults,noatime 0 2" >> /tmp/fstab.pbs
cat /tmp/fstab.pbs > /etc/fstab
rm -f /tmp/fstab.pbs

systemctl daemon-reload
mount "${MOUNTPOINT}"
findmnt "${MOUNTPOINT}" >/dev/null 2>&1 || die "Falha ao montar ${MOUNTPOINT}"
ok "Mountpoint configurado."

print_step "STEP 6" "Criar datastore PBS"
mkdir -p "${DATASTORE_PATH}"
touch "${DATASTORE_PATH}/.write-test"
rm -f "${DATASTORE_PATH}/.write-test"

if ! proxmox-backup-manager datastore list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${DATASTORE_NAME}"; then
 proxmox-backup-manager datastore create "${DATASTORE_NAME}" "${DATASTORE_PATH}"
 ok "Datastore criado."
else
 warn "Datastore ${DATASTORE_NAME} já existe."
fi

print_step "STEP 7" "Estado final"
findmnt "${MOUNTPOINT}" || true
df -h "${MOUNTPOINT}" || true
lsblk -f || true
proxmox-backup-manager datastore list || true

print_step "STEP 8" "Notas operacionais"
info "Modelo atual:"
echo " - PBS NÃO usa NFS do Unraid"
echo " - PBS grava diretamente no disco externo"
echo " - Agora podes usar um USB provisório"
echo " - Mais tarde podes migrar para o Samsung T7"
echo
info "Teste recomendado de escrita:"
echo " dd if=/dev/zero of=${DATASTORE_PATH}/testfile bs=1G count=2 oflag=direct status=progress"
echo " rm -f ${DATASTORE_PATH}/testfile"

echo -e "\n$LINE"
echo -e "${GREEN}${BOLD}✅ PBS VM finalizada com sucesso.${RESET}"
echo -e "${GREEN}${BOLD}Depois voltar à PVE e correr o script 05${RESET}"
echo -e "$LINE"
