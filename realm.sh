#!/bin/sh

set -eu

REALM_BIN="/usr/local/bin/realm"
BASE_DIR="/etc/realm"
RULES_DIR="$BASE_DIR/rules"
LOG_DIR="/var/log"
SYSTEMD_TMPL="/etc/systemd/system/realm@.service"
SELF_PATH="$(/usr/bin/env realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

ensure_root(){ [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo $0"; exit 1; }; }
pause(){ printf "按回车继续..."; read -r _ || true; }

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

_is_pid1_systemd(){
  [ -d /run/systemd/system ] || return 1
  ps -o comm= -p 1 2>/dev/null | grep -qx "systemd"
}

has_systemd(){
  has_cmd systemctl && _is_pid1_systemd
}

has_openrc(){ has_cmd rc-update && has_cmd rc-status; }

pm_detect(){
  if   has_cmd apt; then echo apt
  elif has_cmd apk; then echo apk
  elif has_cmd dnf; then echo dnf
  elif has_cmd yum; then echo yum
  else echo none; fi
}

mode(){
  case "${REALM_FORCE_MODE-}" in
    systemd|openrc|direct) echo "$REALM_FORCE_MODE"; return ;;
    *) : ;;
  esac
  if has_systemd; then echo systemd
  elif has_openrc; then echo openrc
  else echo direct
  fi
}

install_deps(){
  PM=$(pm_detect)
  case "$PM" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt update -y; apt install -y curl tar xz-utils ca-certificates procps; update-ca-certificates || true ;;
    apk) apk add --no-cache curl tar xz ca-certificates coreutils procps; update-ca-certificates || true ;;
    dnf) dnf install -y curl tar xz ca-certificates procps-ng || dnf install -y procps ;;
    yum) yum install -y curl tar xz ca-certificates procps ;;
    *) echo "请先安装 curl tar xz ca-certificates"; exit 1 ;;
  esac
}

arch_target(){
  case "$(uname -m)" in
    x86_64) echo x86_64-unknown-linux-musl ;;
    aarch64|arm64) echo aarch64-unknown-linux-musl ;;
    armv7l) echo armv7-unknown-linux-gnueabi ;;
    *) echo unsupported ;;
  esac
}

install_realm(){
  T="$(arch_target)"; [ "$T" != "unsupported" ] || { echo "不支持的架构: $(uname -m)"; exit 1; }
  API="https://api.github.com/repos/zhboner/realm/releases/latest"
  URL="$(curl -fsSL "$API" | grep -oE "https://[^\" ]*realm-${T}\.tar\.gz" | head -n1 || true)"
  [ -n "$URL" ] || { echo "未找到预编译包"; exit 1; }
  
  TMP="$(mktemp -d)"
  
  ( cd "$TMP" && curl -fL --retry 3 -o r.tgz "$URL" && tar -xzf r.tgz && install -m 0755 realm "$REALM_BIN" )
  
  rm -rf "$TMP"
  
  echo "✅ 已安装 realm 到 $REALM_BIN (临时文件已清理)"
}

ensure_dirs(){ mkdir -p "$RULES_DIR"; }

write_systemd_template(){
cat >"$SYSTEMD_TMPL" <<'EOF'
[Unit]
Description=Realm Port Forwarder (%i)
After=network-online.target
Wants=network-online.target
[Service]
ExecStartPre=/bin/sh -c '/usr/bin/install -o root -g root -m 0644 -D /dev/null /var/log/realm-%i.log'
ExecStart=/usr/local/bin/realm -c /etc/realm/rules/%i.toml
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_openrc_service(){
  NAME="$1"
  F="/etc/init.d/realm-$NAME"
  PID="/run/realm-$NAME.pid"
  cat >"$F" <<EOF
#!/sbin/openrc-run
name="Realm Port Forwarder ($NAME)"
command="$REALM_BIN"
command_args="-c $RULES_DIR/$NAME.toml"
command_user="root:root"
pidfile="$PID"
command_background="yes"
start_stop_daemon_args="--make-pidfile --quiet"
output_log="$LOG_DIR/realm-$NAME.log"
error_log="\$output_log"
depend(){ need net; }
start_pre(){
  checkpath -d -m 0755 /run
  checkpath -f -m 0644 -o root:root "\$output_log"
}
EOF
  chmod +x "$F"
}

write_direct_watchdog(){
  NAME="$1"
  D="$RULES_DIR/.direct"; mkdir -p "$D"
  cat >"$D/$NAME.sh" <<EOF
#!/usr/bin/env sh
while true; do
  $REALM_BIN -c $RULES_DIR/$NAME.toml >>/var/log/realm-$NAME.log 2>&1
  echo "\$(date '+%F %T') [$NAME] 退出，5 秒后重启..." >>/var/log/realm-$NAME.log
  sleep 5
done
EOF
  chmod +x "$D/$NAME.sh"
}

valid_hostport(){
  S="$1"
  echo "$S" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}:(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3})$' && return 0
  echo "$S" | grep -Eq '^\[::\]:(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3})$' && return 0
  echo "$S" | grep -Eq '^0\.0\.0\.0:(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3})$' && return 0
  echo "$S" | grep -Eq '^[A-Za-z0-9._-]+:(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3})$' && return 0
  return 1
}

have_ipv6(){ [ -s /proc/net/if_inet6 ] 2>/dev/null; }
bindv6only(){ cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0; }

emit_endpoints_allip(){
  PORT="$1"
  if have_ipv6; then
    V6ONLY="$(bindv6only)"
    if [ "$V6ONLY" = "0" ]; then
      echo "[[endpoints]]"; echo "listen = \"[::]:$PORT\""; echo "remote = \"$REMOTE\""
    else
      echo "[[endpoints]]"; echo "listen = \"[::]:$PORT\""; echo "remote = \"$REMOTE\""
      echo; echo "[[endpoints]]"; echo "listen = \"0.0.0.0:$PORT\""; echo "remote = \"$REMOTE\""
    fi
  else
    echo "[[endpoints]]"; echo "listen = \"0.0.0.0:$PORT\""; echo "remote = \"$REMOTE\""
  fi
}

valid_port(){ echo "$1" | grep -Eq '^(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3})$'; }

rule_create(){
  mkdir -p "$RULES_DIR"
  echo "监听方式：1) 本机全部 IP（只需输入端口）  2) 自定义 host:port"
  printf "请选择 1 或 2: "; read -r MODESEL
  if [ "$MODESEL" = "1" ]; then
    printf "监听端口 (1-65535): "; read -r PORT
    valid_port "$PORT" || { echo "端口无效"; return; }
    printf "转发目标 (如 1.2.3.4:443 或 example.com:443): "; read -r REMOTE
    echo "协议选择: 1) TCP  2) UDP"; printf "选择 1 或 2: "; read -r PROTO
    case "$PROTO" in 1) USE_UDP=false; NO_TCP=false; TAG=tcp ;; 2) USE_UDP=true; NO_TCP=true; TAG=udp ;; *) echo "无效输入"; return ;; esac
    NAME="${TAG}-${PORT}-$(date +%s)"; CFG="$RULES_DIR/$NAME.toml"
    printf "自定义规则名 (回车默认: %s): " "$NAME"; read -r CUSTOM_NAME
    DISPLAY_NAME="${CUSTOM_NAME:-$NAME}"
    { if [ -n "$CUSTOM_NAME" ]; then echo "# display_name: $CUSTOM_NAME"; fi;
      echo "[log]"; echo 'level="warn"'; echo "output=\"$LOG_DIR/realm-$NAME.log\""; echo;
      echo "[network]"; echo "no_tcp=$NO_TCP"; echo "use_udp=$USE_UDP"; echo;
      emit_endpoints_allip "$PORT"; } >"$CFG"
  else
    printf "监听 (0.0.0.0:PORT / [::]:PORT / IPv4:PORT / 域名:PORT): "; read -r LISTEN
    valid_hostport "$LISTEN" || { echo "监听无效"; return; }
    printf "目标 (如 1.2.3.4:443 或 example.com:443): "; read -r REMOTE
    echo "协议选择: 1) TCP  2) UDP"; printf "选择 1 或 2: "; read -r PROTO
    case "$PROTO" in 1) USE_UDP=false; NO_TCP=false; TAG=tcp ;; 2) USE_UDP=true; NO_TCP=true; TAG=udp ;; *) echo "无效输入"; return ;; esac
    PORT="${LISTEN##*:}"; NAME="${TAG}-${PORT}-$(date +%s)"; CFG="$RULES_DIR/$NAME.toml"
    printf "自定义规则名 (回车默认: %s): " "$NAME"; read -r CUSTOM_NAME
    DISPLAY_NAME="${CUSTOM_NAME:-$NAME}"
    {
      if [ -n "$CUSTOM_NAME" ]; then echo "# display_name: $CUSTOM_NAME"; fi
      cat <<EOF
[log]
level="warn"
output="$LOG_DIR/realm-$NAME.log"
[network]
no_tcp=$NO_TCP
use_udp=$USE_UDP
[[endpoints]]
listen="$LISTEN"
remote="$REMOTE"
EOF
    } > "$CFG"
  fi
  M="$(mode)"
  if [ "$M" = "systemd" ]; then
    write_systemd_template
    systemctl enable --now "realm@$NAME"
  elif [ "$M" = "openrc" ]; then
    write_openrc_service "$NAME"
    rc-update add "realm-$NAME" default
    rc-service "realm-$NAME" start || service "realm-$NAME" start || true
  else
    write_direct_watchdog "$NAME"
    nohup "$RULES_DIR/.direct/$NAME.sh" >/dev/null 2>&1 &
  fi
  echo "✅ 已创建规则 [$DISPLAY_NAME] ($([ "$USE_UDP" = true ] && echo UDP || echo TCP))"
}

rules_list(){
  if ls -1 "$RULES_DIR"/*.toml >/dev/null 2>&1; then
    echo
    printf "%-36s %-26s -> %-26s [%s]\n" "名称" "监听地址" "转发目标" "协议"
    printf "------------------------------------ -------------------------- -------------------------- ------\n"
    for f in "$RULES_DIR"/*.toml; do
      n="$(basename "$f" .toml)"
      DN="$(grep '^# display_name:' "$f" | cut -d ':' -f 2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
      DISPLAY_NAME="${DN:-$n}"
      L="$(awk -F= '/^\[\[endpoints\]\]/{s=1;next} s==1&&/listen/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
      R="$(awk -F= '/^\[\[endpoints\]\]/{s=1;next} s==1&&/remote/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
      U="$(awk -F= '/^\[network\]/{s=1;next} s==1&&/use_udp/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
      N="$(awk -F= '/^\[network\]/{s=1;next} s==1&&/no_tcp/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
      [ "$U" = "true" ] && [ "$N" = "true" ] && P="UDP" || P="TCP"
      printf "%-36s %-26s -> %-26s [%s]\n" "$DISPLAY_NAME" "$L" "$R" "$P"
    done
    echo
  else
    echo "(无规则)"
  fi
}

rule_delete(){
  if ! ls -1 "$RULES_DIR"/*.toml >/dev/null 2>&1; then
    echo "(无规则)"; return
  fi

  echo "请选择要删除的规则:"
  
  i=0
  # 使用 while read 循环处理文件名，确保兼容性和健壮性
  ls -1 "$RULES_DIR"/*.toml | sort | while IFS= read -r f; do
    i=$((i+1))
    n="$(basename "$f" .toml)"
    DN="$(grep '^# display_name:' "$f" | cut -d ':' -f 2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    DISPLAY_NAME="${DN:-$n}"
    L="$(awk -F= '/^\[\[endpoints\]\]/{s=1;next} s==1&&/listen/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
    R="$(awk -F= '/^\[\[endpoints\]\]/{s=1;next} s==1&&/remote/{gsub(/[ "\t]/,"",$2);print $2;exit}' "$f")"
    printf "%d) %s (%s -> %s)\n" "$i" "$DISPLAY_NAME" "$L" "$R"
  done
  
  # POSIX sh 中无法在 while 循环外部直接获取其内部变量 i 的最终值
  # 所以我们用 wc -l 来获取总数
  rule_count=$(ls -1 "$RULES_DIR"/*.toml | wc -l)

  printf "输入数字选择 (或按回车取消): "; read -r choice
  
  # 使用 case 语句进行 POSIX 兼容的输入验证
  case "$choice" in
    ''|*[!0-9]*)
      echo "无效输入，已取消。"
      return
      ;;
  esac

  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$rule_count" ]; then
    echo "无效选择，数字超出范围。"
    return
  fi

  # 使用 sed 精准获取第 N 个文件名
  target_file=$(ls -1 "$RULES_DIR"/*.toml | sort | sed -n "${choice}p")
  
  NAME="$(basename "$target_file" .toml)"
  DN_DEL="$(grep '^# display_name:' "$target_file" | cut -d ':' -f 2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
  DISPLAY_NAME_DEL="${DN_DEL:-$NAME}"

  M="$(mode)"
  if [ "$M" = "systemd" ]; then
    systemctl disable --now "realm@$NAME" || true
  elif [ "$M" = "openrc" ]; then
    rc-service "realm-$NAME" stop || service "realm-$NAME" stop || true
    rc-update del "realm-$NAME" default || true
    rm -f "/etc/init.d/realm-$NAME"
  else
    pkill -f "$RULES_DIR/.direct/$NAME.sh" 2>/dev/null || true
    rm -f "$RULES_DIR/.direct/$NAME.sh" 2>/dev/null || true
  fi
  rm -f "$target_file" "$LOG_DIR/realm-$NAME.log"
  echo "✅ 已删除规则 [$DISPLAY_NAME_DEL]"
}

start_all(){
  if ls -1 "$RULES_DIR"/*.toml >/dev/null 2>&1; then
    M="$(mode)"
    for f in "$RULES_DIR"/*.toml; do
      n="$(basename "$f" .toml)"
      if [ "$M" = "systemd" ]; then
        write_systemd_template; systemctl enable --now "realm@$n"
      elif [ "$M" = "openrc" ]; then
        write_openrc_service "$n"; rc-update add "realm-$n" default; rc-service "realm-$n" start || true
      else
        write_direct_watchdog "$n"; nohup "$RULES_DIR/.direct/$n.sh" >/dev/null 2>&1 &
      fi
    done
  fi
  echo "✅ 所有规则已启动（如有）"
}

stop_all(){
  M="$(mode)"
  if [ "$M" = "systemd" ]; then
    systemctl list-units --type=service --no-legend 2>/dev/null | awk '/realm@.*\.service/{print $1}' | xargs -r -n1 systemctl stop
  elif [ "$M" = "openrc" ]; then
    rc-status -a 2>/dev/null | awk '/realm-/{print $1}' | while read -r s; do rc-service "$s" stop || true; done
  else
    pkill -f "$RULES_DIR/.direct/.*\.sh" 2>/dev/null || true
    pkill -f "^$REALM_BIN" >/dev/null 2>&1 || true
  fi
  echo "✅ 所有规则已停止（如有）"
}

check_realm_status(){
  if ps aux | grep "$REALM_BIN" | grep -q -v grep; then
    echo "Realm 正在运行"
  else
    echo "Realm 没有运行"
  fi
}

uninstall_all(){
  set +eu

  echo "--- 开始执行 Realm 彻底卸载程序 (高可靠性版) ---"
  echo "⚠️ 将彻底删除 Realm、规则、日志、配置、服务与本脚本。"
  printf "确定继续？(y/N): "; read -r yn
  [ "$(printf '%s' "$yn" | tr 'A-Z' 'a-z')" = "y" ] || { echo "已取消"; return; }
  
  echo
  echo "[1/4] 正在停止并禁用服务..."
  if command -v systemctl >/dev/null 2>&1; then
      echo "  > 正在处理 Systemd 服务..."
      systemctl stop realm@*.service >/dev/null 2>&1
      systemctl disable realm@*.service >/dev/null 2>&1
  fi
  if command -v rc-service >/dev/null 2>&1; then
      echo "  > 正在处理 OpenRC 服务..."
      for SCRIPT in /etc/init.d/realm-*; do
          if [ -f "$SCRIPT" ]; then
              rc-service "$(basename "$SCRIPT")" stop >/dev/null 2>&1
              rc-update del "$(basename "$SCRIPT")" default >/dev/null 2>&1
          fi
      done
  fi
  echo "  > 服务处理完成。"
  echo

  echo "[2/4] 正在强制终止所有残留进程..."
  pkill -9 -f /usr/local/bin/realm
  pkill -f "/etc/realm/rules/.direct/.*.sh"
  echo "  > 进程终止完成。"
  echo

  echo "[3/4] 正在删除所有已知的文件和目录..."
  echo "  > 删除 /etc/realm..."
  rm -rf /etc/realm
  echo "  > 删除 /usr/local/bin/realm..."
  rm -f /usr/local/bin/realm
  echo "  > 删除 /var/log/realm-*..."
  rm -rf /var/log/realm-*
  echo "  > 删除 /etc/systemd/system/realm@.service..."
  rm -f /etc/systemd/system/realm@.service
  echo "  > 删除 /etc/init.d/realm-*..."
  rm -f /etc/init.d/realm-*
  echo "  > 文件删除完成。"
  echo

  echo "[4/4] 正在刷新系统服务配置..."
  if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload
      echo "  > 已刷新 Systemd 。"
  fi
  echo "  > 刷新完成。"
  echo

  echo "✅ Realm 已彻底卸载。"
  echo "🧨 脚本将开始自毁..."
  ( sleep 1 && rm -f "$SELF_PATH" ) &
  
  exit 0
}

menu(){
  clear
  echo "===== Realm 管理器 v1.0  ====="
  echo "模式: $(mode)"
  echo "规则目录: $RULES_DIR"
  echo
  cat <<'EOF'
1) 安装 / 更新 Realm
2) 新建规则
3) 删除规则
4) 启动所有规则
5) 停止所有规则
6) 查看当前创建的规则
7) 查看 Realm 运行状态
8) 卸载并彻底删除所有文件
0) 退出
EOF
  printf "选择: "; read -r c
  case "$c" in
    1) install_deps; install_realm; ensure_dirs; pause ;;
    2) rule_create; pause ;;
    3) rule_delete; pause ;;
    4) start_all; pause ;;
    5) stop_all; pause ;;
    6) rules_list; pause ;;
    7) check_realm_status; pause ;;
    8) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选择"; pause ;;
  esac
}

ensure_root
while true; do menu; done