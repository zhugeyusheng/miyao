#!/usr/bin/env bash
# setup-vps-motd.sh - 安装或恢复 ZHUGEYUSHENG VPS 欢迎界面（Ubuntu/Debian）
set -Eeuo pipefail

MOTD_DIR='/etc/update-motd.d'
BACKUP_DIR='/etc/update-motd.d.codex-backup'
CUSTOM_FILE="$MOTD_DIR/01-zhugeyusheng-vps"
STATIC_MOTD='/etc/motd'
STATIC_MOTD_BACKUP='/etc/motd.codex-backup'

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
}

backup_original_motd() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    cp -a -- "$MOTD_DIR" "$BACKUP_DIR"
    ok "已备份动态 MOTD：$BACKUP_DIR"
  else
    info "检测到已有动态 MOTD 备份，不覆盖：$BACKUP_DIR"
  fi

  if [[ ! -e "$STATIC_MOTD_BACKUP" ]]; then
    if [[ -e "$STATIC_MOTD" ]]; then
      cp -a -- "$STATIC_MOTD" "$STATIC_MOTD_BACKUP"
    else
      : > "$STATIC_MOTD_BACKUP"
    fi
    ok "已备份静态 MOTD：$STATIC_MOTD_BACKUP"
  else
    info "检测到已有静态 MOTD 备份，不覆盖：$STATIC_MOTD_BACKUP"
  fi
}

write_custom_motd() {
  cat > "$CUSTOM_FILE" <<'EOF'
#!/usr/bin/env bash

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

host_name=$(hostname 2>/dev/null || printf 'VPS')
os_name=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
uptime_info=$(uptime -p 2>/dev/null | sed 's/^up //' || true)
load_info=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || true)
memory_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}' || true)
disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (已用 " $5 ")"}' || true)
ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || true)

printf "%b" "$GREEN"
cat <<'LOGO'
  ███████╗██╗  ██╗██╗   ██╗ ██████╗ ███████╗
  ╚══███╔╝██║  ██║██║   ██║██╔════╝ ██╔════╝
    ███╔╝ ███████║██║   ██║██║  ███╗█████╗
   ███╔╝  ██╔══██║██║   ██║██║   ██║██╔══╝
  ███████╗██║  ██║╚██████╔╝╚██████╔╝███████╗
  ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚══════╝
                 Y U S H E N G
LOGO
printf "%b\n" "$RESET"
printf "%b主机：%s%b\n" "$CYAN" "$host_name" "$RESET"
printf "系统：%s\n" "${os_name:-未知}"
printf "运行：%s\n" "${uptime_info:-未知}"
printf "负载：%s\n" "${load_info:-未知}"
printf "内存：%s\n" "${memory_info:-未知}"
printf "磁盘：%s\n" "${disk_info:-未知}"
printf "地址：%s\n\n" "${ip_addr:-未知}"
EOF
  chmod 755 "$CUSTOM_FILE"
}

install_motd() {
  [[ -d "$MOTD_DIR" ]] || die "未找到 $MOTD_DIR；该脚本用于 Ubuntu/Debian 的动态 MOTD。"
  backup_original_motd

  # 禁用系统原有动态欢迎模块，但不删除，restore 时可完整恢复。
  find "$MOTD_DIR" -maxdepth 1 -type f ! -name "$(basename "$CUSTOM_FILE")" -exec chmod a-x {} +
  write_custom_motd
  : > "$STATIC_MOTD"

  echo
  ok '安装完成，预览如下：'
  echo '----------------------------------------'
  run-parts -- "$MOTD_DIR"
  echo '----------------------------------------'
  info '重新 SSH 登录即可看到新欢迎界面。'
}

restore_motd() {
  [[ -d "$BACKUP_DIR" ]] || die "没有找到动态 MOTD 备份：$BACKUP_DIR"

  rm -f -- "$CUSTOM_FILE"
  find "$MOTD_DIR" -mindepth 1 -maxdepth 1 -type f -exec rm -f -- {} +
  cp -a -- "$BACKUP_DIR"/. "$MOTD_DIR"/

  if [[ -e "$STATIC_MOTD_BACKUP" ]]; then
    cp -a -- "$STATIC_MOTD_BACKUP" "$STATIC_MOTD"
  else
    : > "$STATIC_MOTD"
  fi
  ok 'Ubuntu/Debian 原欢迎界面已恢复。'
}

require_root
case "${1:-install}" in
  install) install_motd ;;
  restore) restore_motd ;;
  *) die "用法：sudo bash $0 [install|restore]" ;;
esac
