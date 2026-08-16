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

ACME_HOME='/root/.acme.sh'
CERT_BASE='/etc/ssl/zhugeyusheng'

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
  [[ -n "${MIGRATION_TMP_DIR:-}" && -d "$MIGRATION_TMP_DIR" ]] && rm -rf -- "$MIGRATION_TMP_DIR"
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

set_script_shortcut() {
  local key="$1" lower upper rc_file tmp begin end
  [[ "$key" =~ ^[A-Za-z]$ ]] || return 1
  lower="${key,,}"
  upper="${key^^}"
  rc_file='/root/.bashrc'
  begin='# >>> ZHUGEYUSHENG SSH 快捷键 >>>'
  end='# <<< ZHUGEYUSHENG SSH 快捷键 <<<'
  touch "$rc_file"
  tmp="$(mktemp)"

  # 只替换本脚本创建的区块，不影响用户其余 .bashrc 配置。
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
}

ensure_default_script_shortcut() {
  local begin='# >>> ZHUGEYUSHENG SSH 快捷键 >>>'
  DEFAULT_SHORTCUT_CREATED=0
  if ! grep -Fqx "$begin" /root/.bashrc 2>/dev/null; then
    set_script_shortcut s || die '无法设置默认脚本快捷键。'
    DEFAULT_SHORTCUT_CREATED=1
  fi
}

install_script_shortcut() {
  local key lower upper
  print_header
  echo '             脚本调出快捷键'
  echo '------------------------------------------------'
  echo '默认快捷键为 s / S；此处可修改为其他单个英文字母。'
  read -r -p '请输入新的英文字母快捷键：' key
  if ! set_script_shortcut "$key"; then
    warn '只能输入一个英文字母。'
    pause
    return
  fi
  lower="${key,,}"
  upper="${key^^}"
  ok "快捷键已修改：输入 $lower 或 $upper 即可调出脚本。"
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

domain_is_valid() {
  local domain="$1"
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

port_80_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR > 1 && $4 ~ /:80$/ { found=1 } END { exit !found }'
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '$4 ~ /:80$/ { found=1 } END { exit !found }'
    return
  fi
  return 1
}

install_acme_sh() {
  local installer
  [[ -x "$ACME_HOME/acme.sh" ]] && return 0
  info '正在安装 acme.sh（用于申请和自动续期证书）。'
  installer="$(mktemp)"
  TMP_FILE="$installer"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --silent --show-error --connect-timeout 10 --max-time 60 https://get.acme.sh -o "$installer" || die 'acme.sh 下载失败，请检查网络连接。'
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=60 -O "$installer" https://get.acme.sh || die 'acme.sh 下载失败，请检查网络连接。'
  else
    die '系统中未找到 curl 或 wget，无法安装 acme.sh。'
  fi
  sh "$installer" || die 'acme.sh 安装失败。'
  rm -f -- "$installer"
  TMP_FILE=''
  [[ -x "$ACME_HOME/acme.sh" ]] || die 'acme.sh 安装后未找到可执行文件。'
}

request_domain_certificate() {
  local domain cert_dir reload_cmd resolved
  print_header
  echo '               域名证书申请'
  echo '------------------------------------------------'
  echo "使用 Let's Encrypt 的 HTTP-01 standalone 验证。"
  echo '申请前请确认：域名 A/AAAA 记录指向本机，且公网 80 端口可访问。'
  read -r -p '请输入域名（例如 example.com）：' domain
  domain="${domain,,}"
  domain="${domain%.}"
  if ! domain_is_valid "$domain"; then
    warn '域名格式无效；仅支持普通域名，不支持通配符证书。'
    pause
    return
  fi

  if port_80_in_use; then
    warn '检测到 80 端口正在被占用。为避免中断现有网站，本功能不会停止服务。'
    info '请先停止占用 80 端口的服务后重试，或改用 Webroot/DNS 验证方式。'
    pause
    return
  fi

  resolved=''
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  fi
  if [[ -n "$resolved" ]]; then
    info "检测到域名解析：$resolved"
  else
    warn '未能在本机查询到该域名的 A 记录；若 DNS 刚变更，可稍后重试。'
  fi

  cert_dir="$CERT_BASE/$domain"
  read -r -p "续期后重载命令（可留空；例如 systemctl reload nginx）：" reload_cmd
  install_acme_sh
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null || die "无法设置 Let's Encrypt 为证书颁发机构。"
  info "正在为 $domain 申请 ECC 证书…"
  if ! "$ACME_HOME/acme.sh" --issue --standalone -d "$domain" --keylength ec-256; then
    warn '证书申请失败。请检查 DNS 是否指向本机、防火墙/安全组是否放行 80 端口，以及 80 端口是否空闲。'
    pause
    return
  fi

  mkdir -p -- "$cert_dir"
  chmod 700 "$cert_dir"
  if [[ -n "$reload_cmd" ]]; then
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
      --key-file "$cert_dir/privkey.pem" \
      --fullchain-file "$cert_dir/fullchain.pem" \
      --reloadcmd "$reload_cmd" || die '证书已签发，但部署失败。'
  else
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
      --key-file "$cert_dir/privkey.pem" \
      --fullchain-file "$cert_dir/fullchain.pem" || die '证书已签发，但部署失败。'
  fi
  chmod 600 "$cert_dir/privkey.pem"
  chmod 644 "$cert_dir/fullchain.pem"
  ok '域名证书申请并部署完成，acme.sh 已自动配置续期任务。'
  echo "私钥：$cert_dir/privkey.pem"
  echo "完整证书链：$cert_dir/fullchain.pem"
  [[ -n "$reload_cmd" ]] || info '未设置续期后的重载命令；请在 Web 服务中引用证书后，按需重新申请并设置该命令。'
  pause
}

view_domain_status() {
  local domain resolved cert_dir http_status
  print_header
  echo '               查看域名情况'
  echo '------------------------------------------------'
  read -r -p '请输入域名（例如 example.com）：' domain
  domain="${domain,,}"
  domain="${domain%.}"
  if ! domain_is_valid "$domain"; then
    warn '域名格式无效。'
    pause
    return
  fi

  echo "域名：$domain"
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [[ -n "$resolved" ]]; then
      ok "DNS 解析：$resolved"
    else
      warn 'DNS 解析：本机未查询到 A 记录。'
    fi
  else
    warn '未安装 getent，无法查询 DNS 解析。'
  fi

  if port_80_in_use; then
    info '本机 80 端口：正在被服务占用。'
  else
    info '本机 80 端口：当前未检测到监听服务。'
  fi

  if command -v curl >/dev/null 2>&1; then
    http_status="$(curl -IL --silent --show-error --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "http://$domain" 2>/dev/null || true)"
    if [[ "$http_status" =~ ^[1-5][0-9][0-9]$ ]]; then
      ok "HTTP 连通性：收到 HTTP $http_status 响应。"
    else
      warn 'HTTP 连通性：未收到有效响应，请检查 DNS、防火墙和 Web 服务。'
    fi
  else
    warn '未安装 curl，跳过 HTTP 连通性检查。'
  fi

  cert_dir="$CERT_BASE/$domain"
  if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
    ok "已部署证书：$cert_dir"
    if command -v openssl >/dev/null 2>&1; then
      openssl x509 -in "$cert_dir/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null || \
        warn '证书文件无法被 OpenSSL 读取。'
    else
      warn '未安装 openssl，无法读取证书详情。'
    fi
  else
    warn "未在 $cert_dir 找到已部署的证书。"
  fi
  pause
}

domain_certificate_menu() {
  local choice
  while true; do
    print_header
    echo '               域名证书管理'
    echo '------------------------------------------------'
    echo '1. 域名证书申请'
    echo '2. 查看域名情况'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) request_domain_certificate ;;
      2) view_domain_status ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

base64_one_line() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

wordpress_migration() {
  local wp_root old_url new_url target_host target_port target_user target_path target web_user
  local db_name db_user db_pass db_host work_dir stamp bundle_name bundle_file remote_script
  local export_file meta_file archive_file ssh_opts=() scp_opts=()

  print_header
  echo '              WordPress 网站搬家'
  echo '------------------------------------------------'
  warn '请保持当前 SSH 会话连接，搬家完成并测试成功后再修改 DNS。'
  echo '本功能会迁移 WordPress 文件和数据库，并可安全替换序列化数据中的旧域名。'
  echo '目标 VPS 需已安装：OpenSSH、tar、MySQL/MariaDB 客户端与服务端。'
  echo '------------------------------------------------'

  require_command wp
  require_command ssh
  require_command scp
  require_command tar
  require_command base64

  read -r -e -p '源站 WordPress 目录（例如 /var/www/example.com）：' wp_root
  wp_root="${wp_root%/}"
  [[ "$wp_root" == /* && -f "$wp_root/wp-config.php" ]] || { warn '目录无效或未找到 wp-config.php。'; pause; return; }
  if ! wp core is-installed --path="$wp_root" --allow-root >/dev/null 2>&1; then
    warn 'WP-CLI 无法确认该目录是已安装的 WordPress 网站。'
    pause
    return
  fi

  old_url="$(wp option get home --path="$wp_root" --allow-root 2>/dev/null || true)"
  [[ -n "$old_url" ]] || { warn '无法读取 WordPress 旧网址。'; pause; return; }
  echo "检测到当前网站地址：$old_url"
  read -r -p '新网站地址（保留原域名可直接回车，例如 https://new.example.com）：' new_url
  new_url="${new_url:-$old_url}"
  [[ "$new_url" =~ ^https?://[^[:space:]/]+/?$ ]] || { warn '新网站地址格式无效，请输入 http://域名 或 https://域名。'; pause; return; }
  new_url="${new_url%/}"
  old_url="${old_url%/}"

  read -r -p '目标 VPS 地址（IPv4 或域名）：' target_host
  [[ "$target_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { warn '目标 VPS 地址格式无效。'; pause; return; }
  read -r -p '目标 VPS SSH 端口 [22]：' target_port
  target_port="${target_port:-22}"
  [[ "$target_port" =~ ^[0-9]+$ ]] && (( target_port >= 1 && target_port <= 65535 )) || { warn 'SSH 端口无效。'; pause; return; }
  read -r -p '目标 VPS SSH 用户 [root]：' target_user
  target_user="${target_user:-root}"
  [[ "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn 'SSH 用户名格式无效。'; pause; return; }
  read -r -e -p '目标网站目录（例如 /var/www/example.com）：' target_path
  target_path="${target_path%/}"
  [[ "$target_path" =~ ^/[A-Za-z0-9._/-]+$ && "$target_path" != '/' ]] || { warn '目标目录必须是安全的绝对路径，且不能为根目录。'; pause; return; }
  read -r -p '目标网站文件所属用户 [www-data]：' web_user
  web_user="${web_user:-www-data}"
  [[ "$web_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn '文件所属用户名格式无效。'; pause; return; }

  db_name="$(wp config get DB_NAME --path="$wp_root" --allow-root 2>/dev/null || true)"
  db_user="$(wp config get DB_USER --path="$wp_root" --allow-root 2>/dev/null || true)"
  db_pass="$(wp config get DB_PASSWORD --path="$wp_root" --allow-root 2>/dev/null || true)"
  db_host="$(wp config get DB_HOST --path="$wp_root" --allow-root 2>/dev/null || true)"
  [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]] || { warn '数据库名包含不支持的字符，无法自动迁移。'; pause; return; }
  [[ "$db_user" =~ ^[A-Za-z0-9_]+$ ]] || { warn '数据库用户名包含不支持的字符，无法自动迁移。'; pause; return; }
  [[ "$db_pass" != *$'\n'* && "$db_pass" != *$'\r'* ]] || { warn '数据库密码包含换行符，无法安全自动迁移。'; pause; return; }
  case "$db_host" in
    localhost|127.0.0.1|localhost:*) ;;
    *) warn "当前 DB_HOST=$db_host，不是本机数据库；自动建库模式不适用。"; pause; return ;;
  esac

  target="$target_user@$target_host"
  ssh_opts=(-p "$target_port" -o ConnectTimeout=10 -o ServerAliveInterval=15)
  scp_opts=(-P "$target_port" -o ConnectTimeout=10)
  info "正在测试目标 VPS SSH 连接：$target"
  if ! ssh "${ssh_opts[@]}" "$target" 'test "$(id -u)" -eq 0' ; then
    warn '目标连接失败，或目标 SSH 用户不是 root。请先配置 SSH 登录。'
    pause
    return
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  work_dir="$(mktemp -d)"
  MIGRATION_TMP_DIR="$work_dir"
  export_file="$work_dir/database.sql"
  meta_file="$work_dir/migration.meta"
  archive_file="$work_dir/wordpress-files.tar.gz"
  bundle_name="wordpress-migration-$stamp.tar.gz"
  bundle_file="$work_dir/$bundle_name"
  remote_script="$work_dir/deploy-wordpress-$stamp.sh"

  info '正在导出 WordPress 数据库…'
  if [[ "$old_url" == "$new_url" ]]; then
    wp db export "$export_file" --path="$wp_root" --allow-root --quiet || die '数据库导出失败。'
  else
    info "正在将数据库中的域名从 $old_url 安全替换为 $new_url（不会修改源站）…"
    wp search-replace "$old_url" "$new_url" --all-tables-with-prefix --precise \
      --export="$export_file" --path="$wp_root" --allow-root --quiet || die '数据库导出或域名替换失败。'
  fi

  info '正在打包 WordPress 文件…'
  tar -C "$wp_root" -czf "$archive_file" . || die '网站文件打包失败。'
  {
    printf 'DB_NAME_B64=%s\n' "$(base64_one_line "$db_name")"
    printf 'DB_USER_B64=%s\n' "$(base64_one_line "$db_user")"
    printf 'DB_PASS_B64=%s\n' "$(base64_one_line "$db_pass")"
    printf 'TARGET_PATH_B64=%s\n' "$(base64_one_line "$target_path")"
    printf 'WEB_USER_B64=%s\n' "$(base64_one_line "$web_user")"
    printf 'OLD_URL_B64=%s\n' "$(base64_one_line "$old_url")"
    printf 'NEW_URL_B64=%s\n' "$(base64_one_line "$new_url")"
  } > "$meta_file"
  chmod 600 "$meta_file"
  tar -C "$work_dir" -czf "$bundle_file" wordpress-files.tar.gz database.sql migration.meta || die '迁移包生成失败。'

  cat > "$remote_script" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
bundle="$1"
script_path="${BASH_SOURCE[0]}"
work_dir=''
cleanup_remote() {
  [[ -n "$work_dir" && -d "$work_dir" ]] && rm -rf -- "$work_dir"
  [[ -f "$bundle" ]] && rm -f -- "$bundle"
  [[ -f "$script_path" ]] && rm -f -- "$script_path"
  return 0
}
trap cleanup_remote EXIT
command -v tar >/dev/null 2>&1 || { echo '[错误] 目标 VPS 缺少 tar。' >&2; exit 1; }
command -v mysql >/dev/null 2>&1 || { echo '[错误] 目标 VPS 缺少 mysql 客户端。' >&2; exit 1; }
command -v php >/dev/null 2>&1 || { echo '[错误] 目标 VPS 缺少 PHP CLI。' >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo '[错误] 目标 VPS 缺少 base64。' >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo '[错误] 目标 VPS 缺少 gzip。' >&2; exit 1; }
work_dir="$(mktemp -d)"
tar -xzf "$bundle" -C "$work_dir"
# shellcheck disable=SC1090
source "$work_dir/migration.meta"
decode() { printf '%s' "$1" | base64 -d; }
db_name="$(decode "$DB_NAME_B64")"
db_user="$(decode "$DB_USER_B64")"
db_pass="$(decode "$DB_PASS_B64")"
target_path="$(decode "$TARGET_PATH_B64")"
web_user="$(decode "$WEB_USER_B64")"
old_url="$(decode "$OLD_URL_B64")"
new_url="$(decode "$NEW_URL_B64")"
[[ "$db_name" =~ ^[A-Za-z0-9_]+$ && "$db_user" =~ ^[A-Za-z0-9_]+$ ]] || { echo '[错误] 数据库标识符无效。' >&2; exit 1; }
[[ "$target_path" =~ ^/[A-Za-z0-9._/-]+$ && "$target_path" != '/' ]] || { echo '[错误] 目标路径无效。' >&2; exit 1; }
id "$web_user" >/dev/null 2>&1 || { echo "[错误] 目标 VPS 不存在用户：$web_user" >&2; exit 1; }
mysql -e 'SELECT 1' >/dev/null 2>&1 || { echo '[错误] 无法以系统 root 身份管理 MySQL/MariaDB，请先配置本机 root socket 登录。' >&2; exit 1; }
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="/root/wp-migration-backups/$stamp"
mkdir -p -- "$backup_dir"
if [[ -d "$target_path" && -n "$(find "$target_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "[信息] 备份目标网站现有文件到：$backup_dir/site-files.tar.gz"
  tar -C "$target_path" -czf "$backup_dir/site-files.tar.gz" .
fi
if mysql -NBe "SHOW DATABASES LIKE '$db_name'" | grep -Fxq "$db_name"; then
  command -v mysqldump >/dev/null 2>&1 || { echo '[错误] 数据库已存在，但目标 VPS 缺少 mysqldump，无法安全备份。' >&2; exit 1; }
  echo "[信息] 备份目标数据库到：$backup_dir/database.sql.gz"
  mysqldump --single-transaction --default-character-set=utf8mb4 "$db_name" | gzip > "$backup_dir/database.sql.gz"
fi
sql_pass="${db_pass//\\/\\\\}"
sql_pass="${sql_pass//\'/\'\'}"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$sql_pass';
ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$sql_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';
CREATE USER IF NOT EXISTS '$db_user'@'127.0.0.1' IDENTIFIED BY '$sql_pass';
ALTER USER '$db_user'@'127.0.0.1' IDENTIFIED BY '$sql_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
mkdir -p -- "$target_path"
find "$target_path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
tar -xzf "$work_dir/wordpress-files.tar.gz" -C "$target_path"
mysql --default-character-set=utf8mb4 "$db_name" < "$work_dir/database.sql"
if [[ "$old_url" != "$new_url" ]]; then
  php -r '$p=$argv[1]; $old=$argv[2]; $new=$argv[3]; $s=file_get_contents($p); if ($s === false) exit(1); if (file_put_contents($p, str_replace($old, $new, $s)) === false) exit(1);' "$target_path/wp-config.php" "$old_url" "$new_url"
fi
chown -R "$web_user:$web_user" "$target_path"
find "$target_path" -type d -exec chmod 755 {} +
find "$target_path" -type f -exec chmod 644 {} +
chmod 640 "$target_path/wp-config.php"
echo '[成功] WordPress 文件与数据库已迁移。'
echo "[信息] 目标目录：$target_path"
echo "[信息] 网站地址：$new_url"
echo "[信息] 覆盖前备份：$backup_dir"
echo '[提示] 请配置 Nginx/Apache 虚拟主机与 HTTPS，测试无误后再修改 DNS。'
REMOTE_SCRIPT
  chmod 700 "$remote_script"

  echo '------------------------------------------------'
  echo "源目录：$wp_root"
  echo "目标：$target:$target_path"
  echo "域名：$old_url -> $new_url"
  warn '目标目录和同名数据库如已存在，将先备份，再由迁移内容覆盖。'
  read -r -p '确认开始传输并部署？请输入 YES：' confirm
  [[ "$confirm" == 'YES' ]] || { info '已取消网站搬家。'; rm -rf -- "$work_dir"; MIGRATION_TMP_DIR=''; pause; return; }

  info '正在上传迁移包和部署脚本…'
  scp "${scp_opts[@]}" "$bundle_file" "$remote_script" "$target:/tmp/" || die '上传迁移文件失败。'
  info '正在目标 VPS 上备份现有内容并部署 WordPress…'
  if ssh "${ssh_opts[@]}" -t "$target" "bash '/tmp/$(basename "$remote_script")' '/tmp/$bundle_name'"; then
    ok 'WordPress 网站搬家完成。'
    info '请先通过 hosts 文件或临时解析测试后台、文章、图片、插件和固定链接。'
    info '确认无误后再修改 DNS，并为新域名配置 HTTPS。'
  else
    warn '目标 VPS 部署失败。目标端若已开始覆盖，请检查 /root/wp-migration-backups 下的备份。'
  fi
  rm -rf -- "$work_dir"
  MIGRATION_TMP_DIR=''
  pause
}

website_migration_menu() {
  local choice
  while true; do
    print_header
    echo '                网站搬家'
    echo '------------------------------------------------'
    echo '1. WordPress 网站迁移到另一台 VPS'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) wordpress_migration ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}
main_menu() {
  require_root
  ensure_default_script_shortcut
  while true; do
    print_header
    if [[ ${DEFAULT_SHORTCUT_CREATED:-0} -eq 1 ]]; then
      ok '已设置默认快捷键：s / S（重新连接 SSH 或执行 source /root/.bashrc 后生效）'
      DEFAULT_SHORTCUT_CREATED=0
    fi
    echo '1. root 登录模式'
    echo '2. Logo 改变'
    echo '3. 主机用户名更改'
    echo '4. 脚本调出快捷键'
    echo '5. 域名证书管理'
    echo '6. 网站搬家'
    echo '0. 退出'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) root_login_menu ;;
      2) logo_change_menu ;;
      3) change_hostname ;;
      4) install_script_shortcut ;;
      5) domain_certificate_menu ;;
      6) website_migration_menu ;;
      0) clear; exit 0 ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

main_menu
