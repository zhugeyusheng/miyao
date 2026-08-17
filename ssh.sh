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
  local domain resolved cert_dir http_status config_file choice index
  local -a domains=() configs=()
  print_header
  echo '               查看域名情况'
  echo '------------------------------------------------'
  info '正在自动扫描 Nginx 网站域名…'
  mapfile -t configs < <(find /etc/nginx/conf.d /etc/nginx/sites-enabled /home/web/conf.d \
    -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort -u)
  for config_file in "${configs[@]}"; do
    while IFS= read -r domain; do
      [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && domains+=("$domain")
    done < <(awk '$1 == "server_name" { for (i=2; i<=NF; i++) { gsub(";", "", $i); print $i } }' "$config_file")
  done
  mapfile -t domains < <(printf '%s\n' "${domains[@]}" | awk 'NF' | sort -u)
  if (( ${#domains[@]} > 0 )); then
    echo '发现以下域名：'
    for index in "${!domains[@]}"; do
      printf '  %d. %s\n' "$((index + 1))" "${domains[$index]}"
    done
    echo '  D. 删除域名并清理缓存'
    echo '  M. 手动输入域名'
    read -r -p '请选择域名编号 [1]：' choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[Dd]$ ]]; then
      delete_domain_and_clear_cache
      return
    elif [[ "$choice" =~ ^[Mm]$ ]]; then
      read -r -p '请输入域名：' domain
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
      domain="${domains[$((choice - 1))]}"
    else
      warn '选择无效。'
      pause
      return
    fi
  else
    info '当前没有扫描到已配置的域名。'
    pause
    return
  fi
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

ensure_php_mysql_extension() {
  local php_version php_package service_name
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql' && return 0
  php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  warn "当前 PHP ${php_version:-未知版本} 缺少 MySQL 扩展，正在安装匹配版本。"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    php_package="php${php_version}-mysql"
    if apt-cache show "$php_package" >/dev/null 2>&1; then
      apt-get install -y "$php_package" || return 1
    else
      apt-get install -y php-mysql || return 1
    fi
    command -v phpenmod >/dev/null 2>&1 && phpenmod mysqli pdo_mysql >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y php-mysqlnd || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y php-mysqlnd || return 1
  else
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    for service_name in "php${php_version}-fpm" php-fpm; do
      systemctl restart "$service_name" >/dev/null 2>&1 || true
    done
  fi
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql'
}

install_wordpress_stack() {
  local need_install=0 pkg_manager='' wp_tmp='' service_name
  for cmd in nginx mysql php tar gzip base64; do
    command -v "$cmd" >/dev/null 2>&1 || need_install=1
  done
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql' || need_install=1

  if (( need_install )); then
    warn '检测到网站运行环境不完整，准备自动安装 Nginx、MySQL/MariaDB、PHP 和常用扩展。'
    if command -v apt-get >/dev/null 2>&1; then
      pkg_manager='apt'
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || die '软件源更新失败。'
      apt-get install -y nginx mariadb-server mariadb-client php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '网站环境安装失败。'
    elif command -v dnf >/dev/null 2>&1; then
      pkg_manager='dnf'
      dnf install -y nginx mariadb-server mariadb php-fpm php-mysqlnd php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '网站环境安装失败。'
    elif command -v yum >/dev/null 2>&1; then
      pkg_manager='yum'
      yum install -y nginx mariadb-server mariadb php-fpm php-mysqlnd php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '网站环境安装失败。'
    else
      die '不支持当前系统的软件包管理器；目前支持 Ubuntu/Debian 和 RHEL/CentOS/Rocky/AlmaLinux。'
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx >/dev/null 2>&1 || warn 'Nginx 自动启动失败，请稍后手动检查。'
    for service_name in mariadb mysql mysqld; do
      if systemctl list-unit-files "$service_name.service" >/dev/null 2>&1; then
        systemctl enable --now "$service_name" >/dev/null 2>&1 && break
      fi
    done
    for service_name in php-fpm php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
      if systemctl list-unit-files "$service_name.service" >/dev/null 2>&1; then
        systemctl enable --now "$service_name" >/dev/null 2>&1 || true
      fi
    done
  fi

  command -v nginx >/dev/null 2>&1 || die 'Nginx 安装后仍不可用。'
  command -v mysql >/dev/null 2>&1 || die 'MySQL/MariaDB 客户端安装后仍不可用。'
  command -v php >/dev/null 2>&1 || die 'PHP 安装后仍不可用。'
  ensure_php_mysql_extension || die "PHP MySQL 扩展未正确安装。当前 PHP：$(command -v php)；版本：$(php -v 2>/dev/null | head -n1)"

  if ! command -v wp >/dev/null 2>&1; then
    info '正在安装 WordPress 管理工具 WP-CLI…'
    wp_tmp="$(mktemp)"
    TMP_FILE="$wp_tmp"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --silent --show-error --connect-timeout 10 --max-time 120 \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$wp_tmp" || die 'WP-CLI 下载失败。'
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=120 -O "$wp_tmp" \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || die 'WP-CLI 下载失败。'
    else
      die '缺少 curl 或 wget，无法安装 WP-CLI。'
    fi
    php "$wp_tmp" --info >/dev/null 2>&1 || die '下载的 WP-CLI 文件校验失败。'
    install -m 755 "$wp_tmp" /usr/local/bin/wp || die 'WP-CLI 安装失败。'
    rm -f -- "$wp_tmp"
    TMP_FILE=''
  fi
  ok '网站运行环境检查完成。'
}

import_wordpress_package() {
  local package_file extract_dir import_file choice index
  local -a packages=()
  print_header
  echo '            导入 WordPress 迁移包'
  echo '------------------------------------------------'
  echo '脚本会自动扫描迁移包，并安装缺少的 Nginx、MySQL/MariaDB、PHP 和 WP-CLI。'
  info '正在扫描 VPS 文件系统中的 WordPress 迁移包…'
  mapfile -t packages < <(find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \
       -o -path /snap -o -path /lost+found \) -prune -o \
    -type f \( -name 'wordpress-migration-*.tar.gz' -o -name 'wordpress-migration-*.tgz' \) -print \
    2>/dev/null | sort -u)

  if (( ${#packages[@]} > 0 )); then
    echo '发现以下迁移包：'
    for index in "${!packages[@]}"; do
      printf '  %d. %s（%s）\n' "$((index + 1))" "${packages[$index]}" "$(du -h "${packages[$index]}" 2>/dev/null | awk '{print $1}')"
    done
    echo '  M. 手动输入其他路径'
    read -r -p '请选择迁移包编号 [1]：' choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[Mm]$ ]]; then
      read -r -e -p '请输入迁移包完整路径：' package_file
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#packages[@]} )); then
      package_file="${packages[$((choice - 1))]}"
    else
      warn '选择无效。'
      pause
      return
    fi
  else
    warn '没有扫描到标准命名的迁移包。'
    read -r -e -p '请输入迁移包完整路径，或按 Enter 返回：' package_file
    [[ -n "$package_file" ]] || return
  fi
  [[ -f "$package_file" ]] || { warn '没有找到迁移包文件。'; pause; return; }
  case "$package_file" in
    *.tar.gz|*.tgz) ;;
    *) warn '迁移包必须是 .tar.gz 或 .tgz 文件。'; pause; return ;;
  esac

  install_wordpress_stack
  if tar -tzf "$package_file" | awk 'BEGIN { bad=0 } /(^|\/)\.\.($|\/)|^\// { bad=1 } END { exit !bad }'; then
    warn '迁移包包含不安全路径，拒绝解压。'
    pause
    return
  fi
  extract_dir="$(mktemp -d)"
  MIGRATION_TMP_DIR="$extract_dir"
  tar -xzf "$package_file" -C "$extract_dir" || die '迁移包解压失败。'
  import_file="$(find "$extract_dir" -maxdepth 2 -type f -name import-wordpress.sh -print -quit)"
  [[ -n "$import_file" ]] || die '迁移包中没有找到 import-wordpress.sh。'
  chmod 700 "$import_file"
  if bash "$import_file"; then
    ok '迁移包导入流程执行完成。'
  else
    warn '迁移包导入失败，请根据上方错误信息检查。'
  fi
  rm -rf -- "$extract_dir"
  MIGRATION_TMP_DIR=''
  pause
}

install_migration_source_tools() {
  local missing=0
  for cmd in php mysql mysqldump tar gzip base64; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  (( missing == 0 )) && { ok '迁移包生成工具检查完成。'; return 0; }

  warn '检测到迁移包生成工具不完整，正在自动安装缺少的软件。'
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die '软件源更新失败，请检查 VPS 网络和软件源。'
    apt-get install -y php-cli mariadb-client tar gzip coreutils || die '迁移工具安装失败。'
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y php-cli mariadb tar gzip coreutils || die '迁移工具安装失败。'
  elif command -v yum >/dev/null 2>&1; then
    yum install -y php-cli mariadb tar gzip coreutils || die '迁移工具安装失败。'
  else
    die '无法自动安装：目前仅支持 Ubuntu/Debian 和 RHEL/CentOS/Rocky/AlmaLinux。'
  fi

  for cmd in php mysql mysqldump tar gzip base64; do
    command -v "$cmd" >/dev/null 2>&1 || die "自动安装后仍缺少命令：$cmd"
  done
  ok '迁移包生成所需工具已自动安装完成。'
}

wordpress_migration() {
  local wp_root output_dir stamp package_dir package_file files_archive db_dump dump_error meta_file import_script dump_bin
  local db_name db_user db_pass db_host table_prefix old_url db_host_name db_port db_socket db_error socket_candidate
  local port_candidate host_candidate container_id detected=0
  local mysql_args=() dump_args=() confirm choice index config_file arg
  local -a wp_roots=() socket_candidates=() port_candidates=() host_candidates=()

  print_header
  echo '           WordPress 离线搬家包生成'
  echo '------------------------------------------------'
  echo '本功能只在当前 VPS 生成迁移包，不会连接另一台 VPS。'
  echo '生成后请自行下载迁移包，再上传到目标 VPS 执行其中的导入脚本。'
  echo '迁移包包含：网站文件、数据库、导入工具和安全换域名功能。'
  echo '缺少 PHP、数据库客户端或压缩工具时会自动安装。'
  echo '------------------------------------------------'

  install_migration_source_tools

  info '正在扫描 VPS 文件系统中的 WordPress 网站…'
  mapfile -t wp_roots < <(find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \
       -o -path /snap -o -path /lost+found \
       -o -path '*/wp-content/cache' -o -path '*/wp-content/uploads' \) -prune -o \
    -type f -name wp-config.php -print 2>/dev/null | while IFS= read -r config_file; do dirname -- "$config_file"; done | sort -u)

  if (( ${#wp_roots[@]} > 0 )); then
    echo '发现以下 WordPress 网站目录：'
    for index in "${!wp_roots[@]}"; do
      printf '  %d. %s\n' "$((index + 1))" "${wp_roots[$index]}"
    done
    echo '  M. 手动输入其他目录'
    read -r -p '请选择网站编号 [1]：' choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[Mm]$ ]]; then
      read -r -e -p '请输入 WordPress 网站目录：' wp_root
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#wp_roots[@]} )); then
      wp_root="${wp_roots[$((choice - 1))]}"
    else
      warn '选择无效。'
      pause
      return
    fi
  else
    warn '没有自动扫描到 wp-config.php。'
    read -r -e -p '请输入 WordPress 网站目录，或按 Enter 返回：' wp_root
    [[ -n "$wp_root" ]] || return
  fi
  wp_root="${wp_root%/}"
  [[ "$wp_root" == /* && -f "$wp_root/wp-config.php" ]] || { warn '目录无效或未找到 wp-config.php。'; pause; return; }
  [[ -f "$wp_root/wp-load.php" && -d "$wp_root/wp-content" ]] || { warn '该目录包含 wp-config.php，但不是完整的 WordPress 网站目录。'; pause; return; }

  info "已选择 WordPress 网站目录：$wp_root"
  info '正在读取 wp-config.php 数据库配置…'
  mapfile -t wp_config_values < <(php -r '
    $s = file_get_contents($argv[1]);
    if ($s === false) exit(1);
    foreach (["DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"] as $name) {
      $pattern = "/define\\s*\\(\\s*[\\x27\\x22]" . preg_quote($name, "/") . "[\\x27\\x22]\\s*,\\s*[\\x27\\x22]((?:\\\\.|[^\\x27\\x22])*)[\\x27\\x22]\\s*\\)/";
      if (!preg_match($pattern, $s, $m)) exit(2);
      echo stripcslashes($m[1]), "\n";
    }
    if (!preg_match("/\\\$table_prefix\\s*=\\s*[\\x27\\x22]([A-Za-z0-9_]+)[\\x27\\x22]\\s*;/", $s, $m)) exit(3);
    echo $m[1], "\n";
  ' "$wp_root/wp-config.php") || { warn '无法解析 wp-config.php；目前支持 WordPress 标准 define 配置格式。'; pause; return; }

  (( ${#wp_config_values[@]} == 5 )) || { warn '读取到的 WordPress 数据库配置不完整。'; pause; return; }
  db_name="${wp_config_values[0]}"
  db_user="${wp_config_values[1]}"
  db_pass="${wp_config_values[2]}"
  db_host="${wp_config_values[3]}"
  table_prefix="${wp_config_values[4]}"
  [[ "$db_name" =~ ^[A-Za-z0-9_]+$ && "$db_user" =~ ^[A-Za-z0-9_]+$ && "$table_prefix" =~ ^[A-Za-z0-9_]+$ ]] || { warn '数据库名、用户名或表前缀包含不支持的字符。'; pause; return; }
  [[ "$db_pass" != *$'\n'* && "$db_pass" != *$'\r'* ]] || { warn '数据库密码包含换行符，无法安全生成迁移包。'; pause; return; }
  ok 'wp-config.php 数据库配置读取完成。'

  db_host_name="$db_host"
  db_port=''
  db_socket=''
  case "$db_host" in
    localhost:/*)
      db_host_name='localhost'
      db_socket="${db_host#localhost:}"
      mysql_args=(-u "$db_user" -S "$db_socket")
      ;;
    localhost)
      mysql_args=(-u "$db_user")
      ;;
    *:[0-9]*)
      db_host_name="${db_host%%:*}"
      db_port="${db_host##*:}"
      mysql_args=(-h "$db_host_name" -u "$db_user" -P "$db_port" --protocol=TCP)
      ;;
    *)
      mysql_args=(-h "$db_host_name" -u "$db_user")
      ;;
  esac
  mysql_args+=(--connect-timeout=5)

  db_error=''
  info "正在按配置连接数据库：$db_host（最长等待 5 秒）…"
  if db_error="$(MYSQL_PWD="$db_pass" mysql "${mysql_args[@]}" -NBe 'SELECT 1' "$db_name" 2>&1)"; then
    detected=1
    info "已按 wp-config.php 配置连接数据库：$db_host"
  fi

  # 自动扫描系统中的全部 MySQL/MariaDB Unix Socket。
  if (( detected == 0 )); then
    info '配置地址连接失败，正在快速扫描数据库 Socket…'
    mapfile -t socket_candidates < <(find /run /var/run /var/lib/mysql /tmp /www/server/mysql -maxdepth 4 -type s \
      \( -name 'mysql.sock' -o -name 'mysqld.sock' -o -name 'mariadb.sock' \) 2>/dev/null | sort -u)
    for socket_candidate in "${socket_candidates[@]}"; do
      if db_error="$(MYSQL_PWD="$db_pass" mysql -u "$db_user" -S "$socket_candidate" --connect-timeout=2 -NBe 'SELECT 1' "$db_name" 2>&1)"; then
        db_socket="$socket_candidate"
        mysql_args=(-u "$db_user" -S "$db_socket" --connect-timeout=5)
        db_error=''
        detected=1
        info "已自动发现数据库 Socket：$db_socket"
        break
      fi
    done
  fi

  # 自动扫描本机正在监听的 MySQL 常用及实际 TCP 端口。
  if (( detected == 0 )); then
    info '正在扫描本机 MySQL/MariaDB 端口（每次最多 2 秒）…'
    port_candidates=(3306 3307 3308)
    if command -v ss >/dev/null 2>&1; then
      while IFS= read -r port_candidate; do
        [[ "$port_candidate" =~ ^[0-9]+$ ]] && port_candidates+=("$port_candidate")
      done < <(ss -ltnpH 2>/dev/null | awk '/mysqld|mariadbd/ {n=split($4,a,":"); print a[n]}' | sort -nu)
    fi
    mapfile -t port_candidates < <(printf '%s\n' "${port_candidates[@]}" | awk '/^[0-9]+$/ && !seen[$0]++')
    for host_candidate in 127.0.0.1 localhost; do
      for port_candidate in "${port_candidates[@]}"; do
        if db_error="$(MYSQL_PWD="$db_pass" mysql -h "$host_candidate" -P "$port_candidate" --protocol=TCP --connect-timeout=2 -u "$db_user" -NBe 'SELECT 1' "$db_name" 2>&1)"; then
          mysql_args=(-h "$host_candidate" -P "$port_candidate" --protocol=TCP --connect-timeout=5 -u "$db_user")
          db_error=''
          detected=1
          info "已自动发现数据库 TCP 地址：$host_candidate:$port_candidate"
          break 2
        fi
      done
    done
  fi

  # WordPress 和数据库由 Docker 部署时，扫描所有运行中容器的内部 IP。
  if (( detected == 0 )) && command -v docker >/dev/null 2>&1; then
    info '正在扫描 Docker 容器数据库（每次最多 2 秒）…'
    mapfile -t host_candidates < <(docker ps -q 2>/dev/null | while IFS= read -r container_id; do
      docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$container_id" 2>/dev/null
    done | awk 'NF && !seen[$0]++')
    for host_candidate in "${host_candidates[@]}"; do
      for port_candidate in 3306 3307; do
        if db_error="$(MYSQL_PWD="$db_pass" mysql -h "$host_candidate" -P "$port_candidate" --protocol=TCP --connect-timeout=2 -u "$db_user" -NBe 'SELECT 1' "$db_name" 2>&1)"; then
          mysql_args=(-h "$host_candidate" -P "$port_candidate" --protocol=TCP --connect-timeout=5 -u "$db_user")
          db_error=''
          detected=1
          info "已自动发现 Docker 数据库：$host_candidate:$port_candidate"
          break 2
        fi
      done
    done
  fi

  if (( detected == 0 )); then
    warn '无法连接 WordPress 数据库。'
    echo "数据库名称：$db_name"
    echo "数据库用户：$db_user"
    echo "数据库地址：$db_host"
    printf '%s\n' "$db_error" >&2
    info '已自动尝试配置地址、系统 Socket、本机监听端口和 Docker 容器 IP。'
    info '也可以返回后选择列表中的另一个 WordPress 网站。'
    pause
    return
  fi
  old_url="$(MYSQL_PWD="$db_pass" mysql "${mysql_args[@]}" -NBe "SELECT option_value FROM ${table_prefix}options WHERE option_name='home' LIMIT 1" "$db_name" 2>/dev/null || true)"
  [[ -n "$old_url" ]] || old_url="$(MYSQL_PWD="$db_pass" mysql "${mysql_args[@]}" -NBe "SELECT option_value FROM ${table_prefix}options WHERE option_name='siteurl' LIMIT 1" "$db_name" 2>/dev/null || true)"
  echo "检测到网站地址：${old_url:-未读取到，导入时可手动填写}"

  read -r -e -p '迁移包保存目录 [/root]：' output_dir
  output_dir="${output_dir:-/root}"
  [[ "$output_dir" == /* ]] || { warn '保存目录必须是绝对路径。'; pause; return; }
  mkdir -p -- "$output_dir" || { warn '无法创建保存目录。'; pause; return; }

  stamp="$(date +%Y%m%d-%H%M%S)"
  package_dir="$(mktemp -d)"
  MIGRATION_TMP_DIR="$package_dir"
  files_archive="$package_dir/wordpress-files.tar.gz"
  db_dump="$package_dir/database.sql"
  dump_error="$package_dir/database-dump.stderr"
  meta_file="$package_dir/migration.meta"
  import_script="$package_dir/import-wordpress.sh"
  package_file="$output_dir/wordpress-migration-$stamp.tar.gz"

  echo '------------------------------------------------'
  echo "网站目录：$wp_root"
  echo "数据库：$db_name"
  echo "输出文件：$package_file"
  read -r -p '确认生成完整迁移包？[Y/n]：' confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || { info '已取消。'; rm -rf -- "$package_dir"; MIGRATION_TMP_DIR=''; pause; return; }

  info '正在导出数据库…'
  dump_args=()
  for arg in "${mysql_args[@]}"; do
    [[ "$arg" == --connect-timeout=* ]] || dump_args+=("$arg")
  done
  dump_bin='mysqldump'
  command -v mariadb-dump >/dev/null 2>&1 && dump_bin='mariadb-dump'
  info "数据库导出工具：$dump_bin（已禁用 tablespace 导出）"
  if ! MYSQL_PWD="$db_pass" "$dump_bin" "${dump_args[@]}" --single-transaction --quick --no-tablespaces \
    --default-character-set=utf8mb4 --triggers "$db_name" > "$db_dump" 2> "$dump_error"; then
    [[ -s "$dump_error" ]] && cat "$dump_error" >&2
    die '数据库导出失败。'
  fi
  if grep -Eqi 'PROCESS privilege|tablespaces?' "$dump_error"; then
    cat "$dump_error" >&2
    die '数据库客户端仍尝试读取 tablespace，已停止生成迁移包；请确认 VPS 使用的是最新脚本。'
  fi
  [[ -s "$dump_error" ]] && warn "数据库导出提示：$(tr '\n' ' ' < "$dump_error")"
  [[ -s "$db_dump" ]] || die '数据库导出文件为空，已停止生成迁移包。'
  grep -Eq '^(CREATE TABLE|INSERT INTO|-- Table structure for table)' "$db_dump" || \
    die '数据库导出内容不完整，已停止生成迁移包。'
  info '正在打包 WordPress 文件…'
  tar -C "$wp_root" -czf "$files_archive" . || die '网站文件打包失败。'

  {
    printf 'DB_NAME_B64=%s\n' "$(base64_one_line "$db_name")"
    printf 'DB_USER_B64=%s\n' "$(base64_one_line "$db_user")"
    printf 'DB_PASS_B64=%s\n' "$(base64_one_line "$db_pass")"
    printf 'OLD_URL_B64=%s\n' "$(base64_one_line "$old_url")"
  } > "$meta_file"
  chmod 600 "$meta_file"

  cat > "$import_script" <<'IMPORT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
GREEN='\033[1;32m'; CYAN='\033[1;36m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
info() { printf "%b[信息]%b %s\n" "$CYAN" "$RESET" "$*"; }
ok() { printf "%b[成功]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 权限运行导入脚本。'
ensure_php_mysql_extension() {
  local php_version php_package service_name
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql' && return 0
  php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  warn "当前 PHP ${php_version:-未知版本} 缺少 MySQL 扩展，正在安装匹配版本。"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    php_package="php${php_version}-mysql"
    if apt-cache show "$php_package" >/dev/null 2>&1; then
      apt-get install -y "$php_package" || return 1
    else
      apt-get install -y php-mysql || return 1
    fi
    command -v phpenmod >/dev/null 2>&1 && phpenmod mysqli pdo_mysql >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y php-mysqlnd || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y php-mysqlnd || return 1
  else
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    for service_name in "php${php_version}-fpm" php-fpm; do
      systemctl restart "$service_name" >/dev/null 2>&1 || true
    done
  fi
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql'
}
auto_install_stack() {
  local missing=0 service_name wp_tmp
  for cmd in nginx mysql php tar gzip base64; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
  php -m 2>/dev/null | grep -Eqi 'mysqli|pdo_mysql' || missing=1
  if (( missing )); then
    warn '检测到运行环境不完整，正在自动安装 Nginx、MySQL/MariaDB、PHP 和扩展…'
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || die '软件源更新失败。'
      apt-get install -y nginx mariadb-server mariadb-client php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '环境安装失败。'
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y nginx mariadb-server mariadb php-fpm php-mysqlnd php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '环境安装失败。'
    elif command -v yum >/dev/null 2>&1; then
      yum install -y nginx mariadb-server mariadb php-fpm php-mysqlnd php-cli php-curl php-gd php-mbstring php-xml php-zip curl ca-certificates tar gzip coreutils || die '环境安装失败。'
    else
      die '无法自动安装：仅支持 Ubuntu/Debian 和 RHEL/CentOS/Rocky/AlmaLinux。'
    fi
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx >/dev/null 2>&1 || warn 'Nginx 启动失败。'
    for service_name in mariadb mysql mysqld; do
      systemctl enable --now "$service_name" >/dev/null 2>&1 && break || true
    done
    for service_name in php-fpm php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
      systemctl enable --now "$service_name" >/dev/null 2>&1 || true
    done
  fi
  for cmd in nginx mysql php tar gzip base64; do command -v "$cmd" >/dev/null 2>&1 || die "安装后仍缺少命令：$cmd"; done
  ensure_php_mysql_extension || die "PHP MySQL 扩展未正确安装。当前 PHP：$(command -v php)；版本：$(php -v 2>/dev/null | head -n1)"
  if ! command -v wp >/dev/null 2>&1; then
    info '正在安装 WordPress 管理工具 WP-CLI…'
    wp_tmp="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --silent --show-error --connect-timeout 10 --max-time 120 https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$wp_tmp" || die 'WP-CLI 下载失败。'
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=120 -O "$wp_tmp" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || die 'WP-CLI 下载失败。'
    else
      die '缺少 curl 或 wget，无法安装 WP-CLI。'
    fi
    php "$wp_tmp" --info >/dev/null 2>&1 || die 'WP-CLI 文件校验失败。'
    install -m 755 "$wp_tmp" /usr/local/bin/wp || die 'WP-CLI 安装失败。'
    rm -f -- "$wp_tmp"
  fi
  ok 'Nginx、数据库、PHP 和 WP-CLI 环境检查完成。'
}
auto_install_stack
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$script_dir/migration.meta" && -f "$script_dir/database.sql" && -f "$script_dir/wordpress-files.tar.gz" ]] || die '迁移包文件不完整。'
for cmd in mysql tar base64 php gzip; do command -v "$cmd" >/dev/null 2>&1 || die "目标 VPS 缺少命令：$cmd"; done
# migration.meta 由源 VPS 脚本生成，只包含 Base64 数据。
# shellcheck disable=SC1091
source "$script_dir/migration.meta"
decode() { printf '%s' "$1" | base64 -d; }
db_name="$(decode "$DB_NAME_B64")"
db_user="$(decode "$DB_USER_B64")"
db_pass="$(decode "$DB_PASS_B64")"
old_url="$(decode "$OLD_URL_B64")"
[[ "$db_name" =~ ^[A-Za-z0-9_]+$ && "$db_user" =~ ^[A-Za-z0-9_]+$ ]] || die '迁移包中的数据库标识符无效。'
[[ "$db_pass" != *$'\n'* && "$db_pass" != *$'\r'* ]] || die '数据库密码格式不受支持。'

old_url="${old_url%/}"
echo '------------------------------------------------'
echo "原网站地址：${old_url:-未知}"
echo '1. 保留原网站域名'
echo '2. 更换为新网站域名'
read -r -p '请选择域名处理方式 [1]：' domain_choice
domain_choice="${domain_choice:-1}"
case "$domain_choice" in
  1)
    new_url="$old_url"
    ;;
  2)
    read -r -p '请输入新域名或完整网址（例如 new.example.com）：' new_url
    [[ -n "$new_url" ]] || die '新域名不能为空。'
    [[ "$new_url" =~ ^https?:// ]] || new_url="https://$new_url"
    new_url="${new_url%/}"
    [[ "$new_url" =~ ^https?://[^[:space:]/]+$ ]] || die '新网站地址格式无效。'
    ;;
  *)
    die '域名处理方式选择无效。'
    ;;
esac
site_host="$(php -r '$h=parse_url($argv[1], PHP_URL_HOST); if ($h) echo strtolower($h);' "$new_url" 2>/dev/null || true)"
if [[ "$site_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  default_target_path="/var/www/$site_host"
else
  default_target_path='/var/www/wordpress'
fi
read -r -e -p "目标网站目录 [$default_target_path]：" target_path
target_path="${target_path:-$default_target_path}"
target_path="${target_path%/}"
[[ "$target_path" =~ ^/[A-Za-z0-9._/-]+$ && "$target_path" != '/' ]] || die '目标网站目录必须是安全的绝对路径，且不能为根目录。'
default_web_user='www-data'
if ! id www-data >/dev/null 2>&1; then
  if id apache >/dev/null 2>&1; then default_web_user='apache'; else default_web_user='nginx'; fi
fi
read -r -p "网站文件所属用户 [$default_web_user]：" web_user
web_user="${web_user:-$default_web_user}"
[[ "$web_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die '用户名称格式无效。'
id "$web_user" >/dev/null 2>&1 || die "目标 VPS 不存在用户：$web_user"
echo "迁移后网站地址：${new_url:-数据库原值}"

mysql -e 'SELECT 1' >/dev/null 2>&1 || die '无法以系统 root 管理 MySQL/MariaDB，请先配置 root 本地 socket 登录。'
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="/root/wp-migration-backups/$stamp"
mkdir -p -- "$backup_dir"
if [[ -d "$target_path" && -n "$(find "$target_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  info "正在备份目标目录到 $backup_dir/site-files.tar.gz"
  tar -C "$target_path" -czf "$backup_dir/site-files.tar.gz" .
fi
if mysql -NBe "SHOW DATABASES LIKE '$db_name'" | grep -Fxq "$db_name"; then
  command -v mysqldump >/dev/null 2>&1 || die '数据库已存在，但缺少 mysqldump，无法安全备份。'
  info "正在备份目标数据库到 $backup_dir/database.sql.gz"
  mysqldump --single-transaction --default-character-set=utf8mb4 "$db_name" | gzip > "$backup_dir/database.sql.gz"
fi

echo "目标目录：$target_path"
echo "新网站地址：${new_url:-保持数据库原值}"
warn '目标目录和同名数据库将先备份，再由迁移内容覆盖。'
  read -r -p '确认导入？[Y/n]：' confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || die '已取消导入。'

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
tar -xzf "$script_dir/wordpress-files.tar.gz" -C "$target_path"
mysql --default-character-set=utf8mb4 "$db_name" < "$script_dir/database.sql"

# 目标数据库由本脚本部署在本机，源站若使用 Docker 服务名（如 mysql），必须改为 localhost。
wp config set DB_HOST localhost --type=constant --path="$target_path" --allow-root --quiet || \
  die '无法将 wp-config.php 的 DB_HOST 更新为 localhost。'
wp db check --path="$target_path" --allow-root >/dev/null 2>&1 || \
  die 'WordPress 无法连接目标数据库，请检查 wp-config.php 和本机 MariaDB/MySQL。'
ok 'WordPress 已连接目标数据库。'

if [[ -n "$old_url" && -n "$new_url" && "$old_url" != "$new_url" ]]; then
  wp_cmd=''
  if command -v wp >/dev/null 2>&1; then
    wp_cmd="$(command -v wp)"
  else
    info '目标 VPS 未安装 WP-CLI，正在下载临时 WP-CLI 以安全替换序列化数据…'
    wp_cmd="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --silent --show-error --connect-timeout 10 --max-time 120 https://github.com/wp-cli/wp-cli/releases/latest/download/wp-cli.phar -o "$wp_cmd" || die 'WP-CLI 下载失败。'
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=120 -O "$wp_cmd" https://github.com/wp-cli/wp-cli/releases/latest/download/wp-cli.phar || die 'WP-CLI 下载失败。'
    else
      die '目标 VPS 缺少 wp、curl 和 wget，无法安全更换域名。'
    fi
    chmod 700 "$wp_cmd"
  fi
  info "正在安全替换域名：$old_url -> $new_url"
  php "$wp_cmd" search-replace "$old_url" "$new_url" --all-tables-with-prefix --precise --path="$target_path" --allow-root || die '域名替换失败。'
  php -r '$p=$argv[1]; $old=$argv[2]; $new=$argv[3]; $s=file_get_contents($p); if ($s === false) exit(1); if (file_put_contents($p, str_replace($old, $new, $s)) === false) exit(1);' "$target_path/wp-config.php" "$old_url" "$new_url"
fi
chown -R "$web_user:$web_user" "$target_path"
find "$target_path" -type d -exec chmod 755 {} +
find "$target_path" -type f -exec chmod 644 {} +
chmod 640 "$target_path/wp-config.php"
site_host=''
[[ -n "$new_url" ]] && site_host="$(php -r '$h=parse_url($argv[1], PHP_URL_HOST); if ($h) echo strtolower($h);' "$new_url" 2>/dev/null || true)"
if [[ "$site_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  php_socket=''
  shopt -s nullglob
  for socket_candidate in /run/php/php*-fpm.sock /run/php-fpm/www.sock; do
    [[ -S "$socket_candidate" ]] && { php_socket="$socket_candidate"; break; }
  done
  shopt -u nullglob
  nginx_config="/etc/nginx/conf.d/wordpress-${site_host//./-}.conf"
  if [[ -n "$php_socket" ]]; then
    fastcgi_target="unix:$php_socket"
  else
    fastcgi_target='127.0.0.1:9000'
  fi
  cat > "$nginx_config" <<NGINX_CONFIG
server {
    listen 80;
    listen [::]:80;
    server_name $site_host;
    root $target_path;
    index index.php index.html;
    client_max_body_size 128m;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass $fastcgi_target;
    }
    location ~* /\.(?!well-known/) {
        deny all;
    }
}
NGINX_CONFIG
  if nginx -t; then
    if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx; else nginx -s reload; fi
    ok "Nginx 网站配置已生成：$nginx_config"

    cert_file=''
    key_file=''
    for cert_pair in \
      "/etc/letsencrypt/live/$site_host/fullchain.pem|/etc/letsencrypt/live/$site_host/privkey.pem" \
      "/home/web/certs/$site_host/fullchain.pem|/home/web/certs/$site_host/privkey.pem" \
      "/home/web/certs/$site_host/cert.pem|/home/web/certs/$site_host/key.pem" \
      "/root/.acme.sh/${site_host}_ecc/fullchain.cer|/root/.acme.sh/${site_host}_ecc/$site_host.key" \
      "/root/.acme.sh/$site_host/fullchain.cer|/root/.acme.sh/$site_host/$site_host.key"; do
      cert_candidate="${cert_pair%%|*}"
      key_candidate="${cert_pair#*|}"
      if [[ -s "$cert_candidate" && -s "$key_candidate" ]]; then
        if command -v openssl >/dev/null 2>&1 && \
           ! openssl x509 -in "$cert_candidate" -noout -checkhost "$site_host" >/dev/null 2>&1; then
          continue
        fi
        cert_file="$cert_candidate"
        key_file="$key_candidate"
        info "已发现网站证书：$cert_file"
        break
      fi
    done

    if [[ -z "$cert_file" ]]; then
      warn "未发现 $site_host 的证书，正在尝试自动申请 Let's Encrypt 证书。"
      acme_home='/root/.acme.sh'
      if [[ ! -x "$acme_home/acme.sh" ]]; then
        acme_installer="$(mktemp)"
        if command -v curl >/dev/null 2>&1; then
          curl -fL --silent --show-error --connect-timeout 10 --max-time 120 https://get.acme.sh -o "$acme_installer" || true
        elif command -v wget >/dev/null 2>&1; then
          wget -q --timeout=120 -O "$acme_installer" https://get.acme.sh || true
        fi
        [[ -s "$acme_installer" ]] && sh "$acme_installer" >/dev/null 2>&1 || true
        rm -f -- "$acme_installer"
      fi
      cert_dir="/etc/ssl/zhugeyusheng/$site_host"
      mkdir -p -- "$cert_dir"
      if [[ -x "$acme_home/acme.sh" ]] && \
         "$acme_home/acme.sh" --issue -d "$site_host" -w "$target_path" --keylength ec-256 && \
         "$acme_home/acme.sh" --install-cert -d "$site_host" --ecc \
           --key-file "$cert_dir/privkey.pem" --fullchain-file "$cert_dir/fullchain.pem" \
           --reloadcmd 'systemctl reload nginx'; then
        cert_file="$cert_dir/fullchain.pem"
        key_file="$cert_dir/privkey.pem"
        chmod 644 "$cert_file"
        chmod 600 "$key_file"
        ok "网站证书申请完成：$cert_file"
      else
        warn '证书自动申请失败；请确认新域名 DNS 已指向本 VPS，且公网 80 端口可访问。'
      fi
    fi

    if [[ -n "$cert_file" && -n "$key_file" ]]; then
      cp -a -- "$nginx_config" "${nginx_config}.http-only"
      cat >> "$nginx_config" <<NGINX_SSL_CONFIG

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $site_host;
    root $target_path;
    index index.php index.html;
    client_max_body_size 128m;
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass $fastcgi_target;
    }
    location ~* /\.(?!well-known/) {
        deny all;
    }
}
NGINX_SSL_CONFIG
      if nginx -t; then
        if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx; else nginx -s reload; fi
        ok "HTTPS 已自动应用到 Nginx：https://$site_host"
      else
        cp -a -- "${nginx_config}.http-only" "$nginx_config"
        warn '证书已找到或签发，但 Nginx HTTPS 配置校验失败，请检查证书格式。'
      fi
      rm -f -- "${nginx_config}.http-only"
    fi
  else
    rm -f -- "$nginx_config"
    warn 'Nginx 配置校验失败，已删除新配置；网站文件和数据库不受影响。'
  fi
else
  warn '未取得有效网站域名，跳过自动生成 Nginx 网站配置。'
fi
ok 'WordPress 文件和数据库导入完成。'
echo "目标目录：$target_path"
echo "网站地址：${new_url:-数据库原值}"
echo "覆盖前备份：$backup_dir"
info 'Nginx HTTP/HTTPS、证书扫描与自动申请流程已处理；请测试网站后再切换正式流量。'
IMPORT_SCRIPT
  chmod 700 "$import_script"

  tar -C "$package_dir" -czf "$package_file" wordpress-files.tar.gz database.sql migration.meta import-wordpress.sh || die '最终迁移包生成失败。'
  chmod 600 "$package_file"
  rm -rf -- "$package_dir"
  MIGRATION_TMP_DIR=''

  ok 'WordPress 离线迁移包已生成。'
  echo "迁移包：$package_file"
  echo '目标 VPS 导入步骤：'
  echo "  1. 将 $(basename "$package_file") 上传到目标 VPS"
  echo "  2. mkdir -p /root/wp-import && tar -xzf $(basename "$package_file") -C /root/wp-import"
  echo '  3. bash /root/wp-import/import-wordpress.sh'
  info '导入脚本会询问目标目录、文件用户和新域名。'
  pause
}

show_tool_version() {
  local tool="$1"
  case "$tool" in
    nginx) nginx -v 2>&1 | sed 's/^/当前版本：/' ;;
    mysql) mysql --version 2>/dev/null | sed 's/^/当前版本：/' ;;
    php) php -v 2>/dev/null | head -n1 | sed 's/^/当前版本：/' ;;
    redis) redis-server --version 2>/dev/null | sed 's/^/当前版本：/' ;;
  esac
}

update_website_tool() {
  local tool="$1" package answer
  case "$tool" in
    nginx) package='nginx' ;;
    mysql) package='mariadb-server mariadb-client' ;;
    php) package='php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip' ;;
    redis) package='redis-server' ;;
    *) return 1 ;;
  esac
  echo "------------------------------------------------"
  echo "工具：$tool"
  show_tool_version "$tool"
  if command -v apt-get >/dev/null 2>&1; then
    echo "可用最新版：$(apt-cache policy ${package%% *} 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  elif command -v dnf >/dev/null 2>&1; then
    dnf list --available "$package" 2>/dev/null | tail -n +2 | head -n1 || true
  fi
  read -r -p "确认更新 $tool？[Y/n]：" answer
  answer="${answer:-Y}"
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y $package || { warn "$tool 更新失败。"; pause; return; }
  elif command -v dnf >/dev/null 2>&1; then
    dnf upgrade -y $package || { warn "$tool 更新失败。"; pause; return; }
  elif command -v yum >/dev/null 2>&1; then
    yum update -y $package || { warn "$tool 更新失败。"; pause; return; }
  else
    warn '不支持当前系统的软件包管理器。'
    pause
    return
  fi
  if command -v systemctl >/dev/null 2>&1; then
    case "$tool" in
      nginx) systemctl restart nginx || true ;;
      mysql) systemctl restart mariadb >/dev/null 2>&1 || systemctl restart mysql >/dev/null 2>&1 || true ;;
      php) systemctl restart php-fpm >/dev/null 2>&1 || true ;;
      redis) systemctl restart redis-server >/dev/null 2>&1 || systemctl restart redis >/dev/null 2>&1 || true ;;
    esac
  fi
  ok "$tool 更新完成。"
  show_tool_version "$tool"
  pause
}

website_status() {
  local choice index config_file site_host root_url cert_file key_file http_code resolved expires
  local -a configs=() sites=()
  print_header
  echo '                网站状态'
  echo '------------------------------------------------'
  mapfile -t configs < <(find /etc/nginx/conf.d /etc/nginx/sites-enabled /home/web/conf.d \
    -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort -u)
  for config_file in "${configs[@]}"; do
    while IFS= read -r site_host; do
      [[ "$site_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && sites+=("$site_host")
    done < <(awk '$1 == "server_name" { for (i=2; i<=NF; i++) { gsub(";", "", $i); print $i } }' "$config_file")
  done
  mapfile -t sites < <(printf '%s\n' "${sites[@]}" | sort -u)
  (( ${#sites[@]} > 0 )) || { warn '没有扫描到 Nginx 网站。'; pause; return; }
  for index in "${!sites[@]}"; do printf '  %d. %s\n' "$((index + 1))" "${sites[$index]}"; done
  read -r -p '请选择网站编号 [1]：' choice
  choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sites[@]} )) || { warn '选择无效。'; pause; return; }
  site_host="${sites[$((choice - 1))]}"
  root_url="https://$site_host"
  echo "网站：$site_host"
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahosts "$site_host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    [[ -n "$resolved" ]] && ok "DNS：$resolved" || warn 'DNS：未解析到地址。'
  fi
  if command -v curl >/dev/null 2>&1; then
    http_code="$(curl -kIL --silent --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "$root_url" 2>/dev/null || true)"
    [[ "$http_code" =~ ^[1-5][0-9][0-9]$ ]] && ok "HTTPS：HTTP $http_code" || warn 'HTTPS：无法访问。'
  fi
  cert_file=''; key_file=''
  for cert_pair in "/etc/letsencrypt/live/$site_host/fullchain.pem|/etc/letsencrypt/live/$site_host/privkey.pem" "/home/web/certs/$site_host/fullchain.pem|/home/web/certs/$site_host/privkey.pem" "/etc/ssl/zhugeyusheng/$site_host/fullchain.pem|/etc/ssl/zhugeyusheng/$site_host/privkey.pem"; do
    [[ -s "${cert_pair%%|*}" && -s "${cert_pair#*|}" ]] && { cert_file="${cert_pair%%|*}"; key_file="${cert_pair#*|}"; break; }
  done
  if [[ -n "$cert_file" && -n "$key_file" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      expires="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)"
      ok "证书：$cert_file；到期：${expires:-未知}"
    else
      ok "证书：$cert_file"
    fi
  else
    warn '证书：未发现匹配证书。'
    info '可使用网站搬家导入流程自动申请，或确认 DNS 后重新执行证书申请。'
  fi
  nginx -t >/dev/null 2>&1 && ok 'Nginx 配置：通过' || warn 'Nginx 配置：失败'
  pause
}

website_tools_menu() {
  local choice
  while true; do
    print_header
    echo '                网站工具更新'
    echo '------------------------------------------------'
    echo '1. Nginx'
    echo '2. MySQL/MariaDB'
    echo '3. PHP'
    echo '4. Redis'
    echo '5. 网站状态（域名、HTTPS、证书、Nginx）'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) update_website_tool nginx ;;
      2) update_website_tool mysql ;;
      3) update_website_tool php ;;
      4) update_website_tool redis ;;
      5) website_status ;;
      0) return ;;
      *) warn '无效选择'; pause ;;
    esac
  done
}

delete_domain_and_clear_cache() {
  local choice index config_file domain root_dir db_name backup_dir confirm
  local cert_dir cache_dir db_dump
  local -a configs=() domains=()
  print_header
  echo '             缓存清理与删除域名'
  echo '------------------------------------------------'
  warn '此功能会删除 Nginx 配置、网站文件、数据库、证书和网站缓存。'
  warn '删除前会自动备份到 /root/domain-delete-backups。'
  mapfile -t configs < <(find /etc/nginx/conf.d /etc/nginx/sites-enabled /home/web/conf.d \
    -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort -u)
  for config_file in "${configs[@]}"; do
    while IFS= read -r domain; do
      [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && domains+=("$domain")
    done < <(awk '$1 == "server_name" { for (i=2; i<=NF; i++) { gsub(";", "", $i); print $i } }' "$config_file")
  done
  mapfile -t domains < <(printf '%s\n' "${domains[@]}" | awk 'NF' | sort -u)
  (( ${#domains[@]} > 0 )) || { warn '没有扫描到可删除的网站域名。'; pause; return; }
  for index in "${!domains[@]}"; do printf '  %d. %s\n' "$((index + 1))" "${domains[$index]}"; done
  read -r -p '请选择要删除的域名编号：' choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )) || { warn '选择无效。'; pause; return; }
  domain="${domains[$((choice - 1))]}"

  config_file=''
  for config_candidate in "${configs[@]}"; do
    if awk -v wanted="$domain" '$1 == "server_name" { for (i=2; i<=NF; i++) { gsub(";", "", $i); if ($i == wanted) found=1 } } END { exit !found }' "$config_candidate"; then
      config_file="$config_candidate"
      break
    fi
  done
  [[ -n "$config_file" ]] || { warn "未找到域名配置：$domain"; pause; return; }
  root_dir="$(awk '$1 == "root" { gsub(";", "", $2); print $2; exit }' "$config_file")"
  [[ "$root_dir" == /* && "$root_dir" != '/' ]] || root_dir=''
  db_name=''
  if [[ -n "$root_dir" && -f "$root_dir/wp-config.php" ]]; then
    db_name="$(php -r '$s=file_get_contents($argv[1]); if (preg_match("/define\\s*\\(\\s*[\\x27\\x22]DB_NAME[\\x27\\x22]\\s*,\\s*[\\x27\\x22]([^\\x27\\x22]+)[\\x27\\x22]/", $s, $m)) echo $m[1];' "$root_dir/wp-config.php" 2>/dev/null || true)"
    [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]] || db_name=''
  fi
  echo '------------------------------------------------'
  echo "准备删除域名：$domain"
  echo "Nginx 配置：$config_file"
  echo "网站目录：${root_dir:-未识别}"
  echo "数据库：${db_name:-未识别/不删除}"
  read -r -p "确认删除 $domain？[Y/n]：" confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || { info '已取消删除。'; pause; return; }

  backup_dir="/root/domain-delete-backups/$(date +%Y%m%d-%H%M%S)-$domain"
  mkdir -p -- "$backup_dir"
  cp -a -- "$config_file" "$backup_dir/"
  if [[ -n "$root_dir" && -d "$root_dir" ]]; then
    tar -C "$root_dir" -czf "$backup_dir/site-files.tar.gz" .
  fi
  if [[ -n "$db_name" ]] && command -v mysqldump >/dev/null 2>&1; then
    mysqldump --single-transaction --no-tablespaces --default-character-set=utf8mb4 "$db_name" > "$backup_dir/database.sql" 2>/dev/null || {
      warn '数据库备份失败，已停止删除以避免无法恢复。'
      pause
      return
    }
  fi

  rm -f -- "$config_file"
  [[ -n "$root_dir" && "$root_dir" != '/' ]] && rm -rf -- "$root_dir"
  for cert_dir in "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain" "/etc/letsencrypt/renewal/$domain.conf" "/home/web/certs/$domain" "/etc/ssl/zhugeyusheng/$domain" "/root/.acme.sh/$domain" "/root/.acme.sh/${domain}_ecc"; do
    rm -rf -- "$cert_dir"
  done
  if [[ -n "$root_dir" ]]; then
    for cache_dir in "$root_dir/wp-content/cache" "/home/web/cache/$domain" "/var/cache/nginx/$domain"; do
      rm -rf -- "$cache_dir"
    done
  fi
  if [[ -n "$db_name" ]] && mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;"; then
    ok "数据库已删除：$db_name"
  fi
  if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || true; else nginx -s reload >/dev/null 2>&1 || true; fi

  echo '------------------------------------------------'
  ok "域名删除和缓存清理完成：$domain"
  echo "删除备份：$backup_dir"
  if find /etc/nginx/conf.d /etc/nginx/sites-enabled /home/web/conf.d -maxdepth 2 -type f -name '*.conf' -print 2>/dev/null | xargs -r grep -lE "(^|[[:space:]])$domain([;[:space:]]|$)" >/dev/null 2>&1; then
    warn 'Nginx 配置中仍发现该域名，请检查共享配置。'
  else
    ok 'Nginx 配置中未发现该域名。'
  fi
  [[ -n "$root_dir" && ! -e "$root_dir" ]] && ok '网站目录已清理。' || warn '网站目录仍存在，请手动检查。'
  [[ -n "$db_name" ]] && mysql -NBe "SHOW DATABASES LIKE '$db_name'" | grep -Fxq "$db_name" && warn '数据库仍存在。' || ok '数据库已清理或未识别。'
  pause
}

edit_nginx_site_config() {
  local choice index config_file backup_file editor
  local -a configs=()
  print_header
  echo '             编辑 Nginx 网站配置'
  echo '------------------------------------------------'
  command -v nginx >/dev/null 2>&1 || { warn '未安装 Nginx。'; pause; return; }
  mapfile -t configs < <(find /etc/nginx/conf.d /etc/nginx/sites-enabled /home/web/conf.d \
    -maxdepth 2 \( -type f -o -type l \) -name '*.conf' 2>/dev/null | sort -u)
  (( ${#configs[@]} > 0 )) || { warn '没有扫描到 Nginx 网站配置。'; pause; return; }
  for index in "${!configs[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${configs[$index]}"
  done
  read -r -p '请选择要编辑的配置编号 [1]：' choice
  choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#configs[@]} )) || { warn '选择无效。'; pause; return; }
  config_file="$(readlink -f -- "${configs[$((choice - 1))]}")"
  [[ -f "$config_file" ]] || { warn '配置文件不存在。'; pause; return; }
  backup_file="${config_file}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$config_file" "$backup_file" || { warn '无法备份 Nginx 配置。'; pause; return; }
  if command -v nano >/dev/null 2>&1; then editor='nano'; else editor='vi'; fi
  "$editor" "$config_file"
  if nginx -t; then
    if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx; else nginx -s reload; fi
    ok "Nginx 配置已保存并生效，备份：$backup_file"
  else
    cp -a -- "$backup_file" "$config_file"
    nginx -t >/dev/null 2>&1 || true
    warn '新配置校验失败，已自动恢复原配置。'
  fi
  pause
}

website_migration_menu() {
  local choice
  while true; do
    print_header
    echo '                网站搬家'
    echo '------------------------------------------------'
    echo '1. 生成 WordPress 离线迁移包'
    echo '2. 导入 WordPress 迁移包（自动安装环境）'
    echo '3. 网站工具更新'
    echo '4. 缓存清理与删除域名'
    echo '0. 返回主菜单'
    echo '------------------------------------------------'
    read -r -p '请输入选择：' choice
    case "$choice" in
      1) wordpress_migration ;;
      2) import_wordpress_package ;;
      3) website_tools_menu ;;
      4) delete_domain_and_clear_cache ;;
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
