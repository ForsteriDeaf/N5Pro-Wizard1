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
