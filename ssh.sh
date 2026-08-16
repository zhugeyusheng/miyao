#!/usr/bin/env bash
# ssh.sh - ZHUGEYUSHENG root SSH 登录与 VPS Logo 管理
set -Eeuo pipefail

SSH_DIR='/root/.ssh'
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
SSHD_MAIN='/etc/ssh/sshd_config'
SSHD_DIR='/etc/ssh/sshd_config.d'
SSHD_DROPIN="$SSHD_DIR/99-zhugeyusheng-root-login.conf"

MOTD_DIR='/etc/update-motd.d'
MOTD_BACKUP='/etc/update-motd.d.zhugeyusheng-backup'
MOTD_FILE="$MOTD_DIR/01-zhugeyusheng-vps"
MOTD_STATIC='/etc/motd'
MOTD_STATIC_BACKUP='/etc/motd.zhugeyusheng-backup'

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info() { printf "%b[信息]%b %s\n" "$CYAN" "$RESET" "$*"; }
ok() { printf "%b[成功]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }
pause() { read -r -p '按 Enter 返回…' _; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 权限运行：sudo bash $0"
}

cleanup() {
  [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f -- "$TMP_FILE"
  [[ -n "${VALID_FILE:-}" && -f "$VALID_FILE" ]] && rm -f -- "$VALID_FILE"
  return 0
}
trap cleanup EXIT

print_header() {
  clear
  printf '%b================================================%b\n' "$GREEN" "$RESET"
  printf '%b   ███████╗██╗  ██╗██╗   ██╗ ██████╗ ███████╗%b\n' "$GREEN" "$RESET"
  printf '%b   ╚══███╔╝██║  ██║██║   ██║██╔════╝ ██╔════╝%b\n' "$GREEN" "$RESET"
  printf '%b     ███╔╝ ███████║██║   ██║██║  ███╗█████╗  %b\n' "$GREEN" "$RESET"
  printf '%b    ███╔╝  ██╔══██║██║   ██║██║   ██║██╔══╝  %b\n' "$GREEN" "$RESET"
  printf '%b   ███████╗██║  ██║╚██████╔╝╚██████╔╝███████╗%b\n' "$GREEN" "$RESET"
  printf '%b   ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚══════╝%b\n' "$GREEN" "$RESET"
  printf '%b              Y U S H E N G%b\n' "$GREEN" "$RESET"
  printf '%b================================================%b\n' "$GREEN" "$RESET"
}

root_key_count() {
  [[ -f "$AUTHORIZED_KEYS" ]] || { printf '0'; return; }
  awk '$1 ~ /^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ && $2 ~ /^[A-Za-z0-9+/]+={0,3}$/ { count++ } END { print count+0 }' "$AUTHORIZED_KEYS"
}

find_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN='/usr/sbin/sshd'
  else
    die '未找到 sshd，拒绝修改 SSH 配置。'
  fi
}

root_effective_config() {
  find_sshd
  "$SSHD_BIN" -T -f "$SSHD_MAIN" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null
}

root_authorized_keys_file_enabled() {
  local files
  files="$(root_effective_config | awk '/^authorizedkeysfile / { $1=""; sub(/^ /, ""); print; exit }')"
  [[ "$files" =~ (^|[[:space:]])(\.ssh/authorized_keys|%h/\.ssh/authorized_keys)([[:space:]]|$) ]]
}

restore_ssh_config() {
  if [[ -n "${DROPIN_BACKUP:-}" && -f "$DROPIN_BACKUP" ]]; then
    mv -f -- "$DROPIN_BACKUP" "$SSHD_DROPIN"
  else
    rm -f -- "$SSHD_DROPIN"
  fi
  if [[ -n "${MAIN_BACKUP:-}" && -f "$MAIN_BACKUP" ]]; then
    mv -f -- "$MAIN_BACKUP" "$SSHD_MAIN"
  fi
}

ensure_manager_include() {
  local include_line tmp
  include_line="Include $SSHD_DROPIN"
  MAIN_BACKUP=''
  grep -Fqx "$include_line" "$SSHD_MAIN" 2>/dev/null && return 0

  MAIN_BACKUP="${SSHD_MAIN}.bak.zhugeyusheng.$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$SSHD_MAIN" "$MAIN_BACKUP"
  tmp="$(mktemp "${SSHD_MAIN}.XXXXXX")"
  {
    printf '%s\n' '# Added by ssh.sh. Keep this line before other SSH options.'
    printf '%s\n' "$include_line"
    cat "$SSHD_MAIN"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$SSHD_MAIN"
}

verify_root_auth_mode() {
  local mode="$1" effective permit password pubkey
  effective="$(root_effective_config || true)"
  permit="$(printf '%s\n' "$effective" | awk '$1 == "permitrootlogin" {print $2; exit}')"
  password="$(printf '%s\n' "$effective" | awk '$1 == "passwordauthentication" {print $2; exit}')"
  pubkey="$(printf '%s\n' "$effective" | awk '$1 == "pubkeyauthentication" {print $2; exit}')"
  case "$mode" in
    key) [[ ( "$permit" == 'prohibit-password' || "$permit" == 'without-password' ) && "$password" == 'no' && "$pubkey" == 'yes' ]] ;;
    password) [[ "$permit" == 'yes' && "$password" == 'yes' && "$pubkey" == 'no' ]] ;;
  esac
}

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null && return 0
    systemctl reload sshd 2>/dev/null && return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null && return 0
    service sshd reload 2>/dev/null && return 0
  fi
  return 1
}

write_root_auth_config() {
  local mode="$1" content tmp
  find_sshd
  [[ -f "$SSHD_MAIN" ]] || die "未找到 SSH 主配置：$SSHD_MAIN"
  mkdir -p -- "$SSHD_DIR"
  DROPIN_BACKUP=''
  [[ -f "$SSHD_DROPIN" ]] && DROPIN_BACKUP="${SSHD_DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
  [[ -n "$DROPIN_BACKUP" ]] && cp -p -- "$SSHD_DROPIN" "$DROPIN_BACKUP"

  case "$mode" in
    key)
      content=$'# Managed by ssh.sh\nPermitRootLogin prohibit-password\nMatch User root\n    AuthenticationMethods publickey\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    PubkeyAuthentication yes\nMatch all\n'
      ;;
    password)
      content=$'# Managed by ssh.sh\nPermitRootLogin yes\nMatch User root\n    AuthenticationMethods any\n    PasswordAuthentication yes\n    KbdInteractiveAuthentication no\n    PubkeyAuthentication no\nMatch all\n'
      ;;
    *) die '未知 root 登录模式' ;;
  esac

  tmp="$(mktemp "${SSHD_DIR}/.zhugeyusheng.XXXXXX")"
  printf '%s' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$SSHD_DROPIN"
  ensure_manager_include

  if ! "$SSHD_BIN" -t -f "$SSHD_MAIN" || ! verify_root_auth_mode "$mode"; then
    warn 'SSH 配置校验失败，已回滚。'
    restore_ssh_config
    die '未修改 SSH 登录配置'
  fi

  if reload_sshd; then
    ok 'SSH 登录配置已生效。请使用新的终端测试后再关闭当前会话。'
  else
    warn '配置已通过校验，但自动 reload 失败；请手动执行 systemctl reload ssh 或 systemctl reload sshd。'
  fi
}

import_github_keys() {
  local username keys_url key identity added=0
  read -r -p '请输入 GitHub 用户名（不含 @）：' username
  username="${username#@}"
  [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || die 'GitHub 用户名格式无效'

  keys_url="https://github.com/${username}.keys"
  cleanup
  TMP_FILE="$(mktemp)"
  VALID_FILE="${TMP_FILE}.valid"
  info "正在获取：$keys_url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --silent --show-error --connect-timeout 10 --max-time 30 "$keys_url" -o "$TMP_FILE" || die '下载失败：请检查用户名或网络连接'
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=30 -O "$TMP_FILE" "$keys_url" || die '下载失败：请检查用户名或网络连接'
  else
    die '系统中未找到 curl 或 wget'
  fi

  : > "$VALID_FILE"
  while IFS= read -r key || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    [[ "$key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || continue
    if command -v ssh-keygen >/dev/null 2>&1; then
      printf '%s\n' "$key" | ssh-keygen -l -f - >/dev/null 2>&1 || continue
    fi
    printf '%s\n' "$key" >> "$VALID_FILE"
  done < "$TMP_FILE"
  mv -- "$VALID_FILE" "$TMP_FILE"
  VALID_FILE=''
  [[ -s "$TMP_FILE" ]] || die "GitHub 用户 $username 没有可用公钥"

  mkdir -p -- "$SSH_DIR"
  touch -- "$AUTHORIZED_KEYS"
  chmod 700 "$SSH_DIR"
  chmod 600 "$AUTHORIZED_KEYS"
  while IFS= read -r key; do
    identity="$(printf '%s\n' "$key" | awk '{print $1 " " $2}')"
    if ! awk -v wanted="$identity" 'NF >= 2 && ($1 " " $2) == wanted { found=1; exit } END { exit !found }' "$AUTHORIZED_KEYS"; then
      printf '%s\n' "$key" >> "$AUTHORIZED_KEYS"
      ((added+=1))
    fi
  done < "$TMP_FILE"
  chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"
  ok "GitHub 公钥导入完成：新增 $added 条，当前共有 $(root_key_count) 条。"

  if (( $(root_key_count) > 0 )) && root_authorized_keys_file_enabled; then
    info '正在自动切换为 root SSH 密钥登录，并禁止 root SSH 密码登录。'
    write_root_auth_config key
  else
    warn 'SSH 未确认读取 /root/.ssh/authorized_keys，因此未切换登录方式。'
  fi
}

remove_root_public_keys() {
  [[ -f "$AUTHORIZED_KEYS" ]] || { info 'root 当前没有已授权公钥文件，无需删除。'; return 0; }
  rm -f -- "$AUTHORIZED_KEYS"
  ok '已删除 root 已授权公钥。'
}

root_self_check() {
  local effective permit password pubkey key_files mode
  print_header
  echo '              Root SSH 登录状态自检'
  echo '------------------------------------------------'
  find_sshd
  if ! "$SSHD_BIN" -t -f "$SSHD_MAIN"; then
    warn 'SSH 配置检查失败，请勿切换登录方式。'
    pause
    return
  fi
  ok 'SSH 配置检查：通过'
  effective="$(root_effective_config || true)"
  permit="$(printf '%s\n' "$effective" | awk '$1 == "permitrootlogin" {print $2; exit}')"
  password="$(printf '%s\n' "$effective" | awk '$1 == "passwordauthentication" {print $2; exit}')"
  pubkey="$(printf '%s\n' "$effective" | awk '$1 == "pubkeyauthentication" {print $2; exit}')"
  key_files="$(printf '%s\n' "$effective" | awk '/^authorizedkeysfile / { $1=""; sub(/^ /, ""); print; exit }')"
  if [[ ( "$permit" == 'prohibit-password' || "$permit" == 'without-password' ) && "$password" == 'no' && "$pubkey" == 'yes' ]]; then
    mode='root SSH 密钥登录'
  elif [[ "$permit" == 'yes' && "$password" == 'yes' && "$pubkey" == 'no' ]]; then
    mode='root SSH 密码登录'
  elif [[ "$permit" == 'no' ]]; then
    mode='root SSH 登录已禁止'
  else
    mode='root SSH 登录状态异常或未识别'
  fi
  echo "当前模式：$mode"
  echo "公钥文件位置：${key_files:-未读取到}"
  echo "有效 root 公钥数量：$(root_key_count)"
  if root_authorized_keys_file_enabled; then
    ok "SSH 会读取：$AUTHORIZED_KEYS"
  else
    warn "SSH 不会读取：$AUTHORIZED_KEYS"
  fi
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    echo "文件权限：.ssh=$(stat -c '%a' "$SSH_DIR" 2>/dev/null || echo '未知')，authorized_keys=$(stat -c '%a' "$AUTHORIZED_KEYS" 2>/dev/null || echo '未知')"
  fi
  pause
}

root_login_menu() {
  while true; do
    print_header
    echo '               root 登录模式'
    echo '------------------------------------------------'
    echo '1. 用户 root：密钥登录'
    echo '2. 用户 root：密码登录'
    echo '3. 自检 root SSH 认证配置'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) import_github_keys; pause ;;
      2)
        print_header
        warn '即将启用 root SSH 密码登录，并删除 root 已授权公钥。'
        if passwd root; then
          write_root_auth_config password
          remove_root_public_keys
          ok 'root SSH 密码登录已启用，root SSH 密钥登录已禁用。'
        else
          warn 'root 密码未设置，未改变 SSH 登录方式。'
        fi
        pause ;;
      3) root_self_check ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

backup_motd() {
  if [[ ! -d "$MOTD_BACKUP" ]]; then
    cp -a -- "$MOTD_DIR" "$MOTD_BACKUP"
  fi
  if [[ ! -e "$MOTD_STATIC_BACKUP" ]]; then
    [[ -e "$MOTD_STATIC" ]] && cp -a -- "$MOTD_STATIC" "$MOTD_STATIC_BACKUP" || : > "$MOTD_STATIC_BACKUP"
  fi
}

write_vps_motd() {
  cat > "$MOTD_FILE" <<'EOF'
#!/usr/bin/env bash
GREEN='\033[1;32m'; CYAN='\033[1;36m'; RESET='\033[0m'
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
printf "系统：%s\n运行：%s\n负载：%s\n内存：%s\n磁盘：%s\n地址：%s\n\n" "${os_name:-未知}" "${uptime_info:-未知}" "${load_info:-未知}" "${memory_info:-未知}" "${disk_info:-未知}" "${ip_addr:-未知}"
EOF
  chmod 755 "$MOTD_FILE"
}

install_vps_logo() {
  [[ -d "$MOTD_DIR" ]] || die "未找到 $MOTD_DIR；仅支持 Ubuntu/Debian 动态 MOTD。"
  backup_motd
  find "$MOTD_DIR" -maxdepth 1 -type f ! -name "$(basename "$MOTD_FILE")" -exec chmod a-x {} +
  write_vps_motd
  : > "$MOTD_STATIC"
  ok 'VPS 欢迎 Logo 已启用，预览如下：'
  echo '------------------------------------------------'
  run-parts -- "$MOTD_DIR"
  echo '------------------------------------------------'
  pause
}

restore_vps_logo() {
  [[ -d "$MOTD_BACKUP" ]] || { warn '没有找到 VPS Logo 的原 MOTD 备份。'; pause; return; }
  rm -f -- "$MOTD_FILE"
  find "$MOTD_DIR" -mindepth 1 -maxdepth 1 -type f -exec rm -f -- {} +
  cp -a -- "$MOTD_BACKUP"/. "$MOTD_DIR"/
  [[ -e "$MOTD_STATIC_BACKUP" ]] && cp -a -- "$MOTD_STATIC_BACKUP" "$MOTD_STATIC" || : > "$MOTD_STATIC"
  ok 'Ubuntu/Debian 原欢迎界面已恢复。'
  pause
}

logo_change_menu() {
  while true; do
    print_header
    echo '                Logo 改变'
    echo '------------------------------------------------'
    echo '1. 启用 ZHUGEYUSHENG VPS Logo'
    echo '2. 恢复 Ubuntu/Debian 原欢迎界面'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) install_vps_logo ;;
      2) restore_vps_logo ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

install_script_shortcut() {
  local key lower upper rc_file tmp begin end
  print_header
  echo '             脚本调出快捷键'
  echo '------------------------------------------------'
  echo '设置后，在 root 终端直接输入一个字母即可调出本脚本。'
  read -r -p '请输入一个英文字母作为快捷键：' key
  [[ "$key" =~ ^[A-Za-z]$ ]] || { warn '只能输入一个英文字母。'; pause; return; }

  lower="${key,,}"
  upper="${key^^}"
  rc_file='/root/.bashrc'
  begin='# >>> ZHUGEYUSHENG SSH 快捷键 >>>'
  end='# <<< ZHUGEYUSHENG SSH 快捷键 <<<'
  touch "$rc_file"
  tmp="$(mktemp)"

  # 移除旧快捷键区块，再写入新的大小写快捷键；不会覆盖其他 .bashrc 内容。
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$rc_file" > "$tmp"
  cat >> "$tmp" <<EOF

$begin
alias $lower='bash <(curl -fsSL https://ssh.126260.xyz)'
alias $upper='bash <(curl -fsSL https://ssh.126260.xyz)'
$end
EOF
  mv -f -- "$tmp" "$rc_file"
  ok "快捷键已设置：输入 $lower 或 $upper 即可调出脚本。"
  info '退出本脚本后执行：source /root/.bashrc；或重新连接 SSH 后生效。'
  pause
}
change_hostname() {
  local current new_name
  print_header
  echo '             主机用户名更改'
  echo '------------------------------------------------'
  current="$(hostname 2>/dev/null || printf '未知')"
  echo "当前主机名：$current"
  read -r -p '请输入新的主机名：' new_name
  new_name="${new_name,,}"

  if [[ ! "$new_name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
    warn '主机名格式无效：只能使用小写字母、数字、连字符和点，且不能以连字符开头或结尾。'
    pause
    return
  fi

  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$new_name"
  else
    printf '%s\n' "$new_name" > /etc/hostname
    hostname "$new_name" 2>/dev/null || true
  fi
  ok "主机名已修改为：$new_name"
  info '重新登录 SSH 后会显示新的主机名。'
  pause
}
main_menu() {
  require_root
  while true; do
    print_header
    echo '1. root 登录模式'
    echo '2. Logo 改变'
    echo '3. 主机用户名更改'
    echo '4. 脚本调出快捷键'
    echo '0. 退出'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) root_login_menu ;;
      2) logo_change_menu ;;
      3) change_hostname ;;
      4) install_script_shortcut ;;
      0) clear; exit 0 ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

main_menu
