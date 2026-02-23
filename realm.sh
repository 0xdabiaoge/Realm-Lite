#!/bin/sh

# ====================================================
# Realm 转发一键脚本
# 支持系统: Debian, Ubuntu, Alpine
# 支持架构: x86_64, aarch64
# 功能: 安装、添加/删除/查看转发、服务管理
# ====================================================
# ====================================================

# 重定义 echo 兼容不同系统的 sh (如 Debian 的 dash 不支持 -e)
echo() {
    if [ "$1" = "-e" ]; then
        shift
        printf "%b\n" "$*"
    else
        printf "%s\n" "$*"
    fi
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 路径定义
REALM_BIN="/usr/bin/realm"
CONF_DIR="/etc/realm"
CONF_FILE="/etc/realm/config.toml"

# 检测操作系统
OS_TYPE="unknown"
OS_PRETTY_NAME="Unknown OS"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_PRETTY_NAME=$PRETTY_NAME
fi

if [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
elif [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
fi

# 检查权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本!${PLAIN}"
    exit 1
fi

# 安装依赖
install_deps() {
    echo -e "${YELLOW}正在安装必要依赖...${PLAIN}"
    if [ "$OS_TYPE" = "debian" ]; then
        apt update && apt install -y curl wget tar ca-certificates
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk update && apk add curl wget tar ca-certificates
    else
        echo -e "${RED}不支持的系统类型，请手动安装 curl, wget, tar${PLAIN}"
    fi
}

# 获取架构
get_arch() {
    arch=$(uname -m)
    if [ "$OS_TYPE" = "alpine" ]; then
        case "$arch" in
            x86_64) echo "x86_64-unknown-linux-musl" ;;
            aarch64) echo "aarch64-unknown-linux-musl" ;;
            *) echo "" ;;
        esac
    else
        case "$arch" in
            x86_64) echo "x86_64-unknown-linux-gnu" ;;
            aarch64) echo "aarch64-unknown-linux-gnu" ;;
            *) echo "" ;;
        esac
    fi
}

# 安装 Realm
install_realm() {
    if [ -f "$REALM_BIN" ]; then
        echo -e "${GREEN}Realm 已安装，跳过。${PLAIN}"
        return
    fi

    install_deps
    
    arch_suffix=$(get_arch)
    if [ -z "$arch_suffix" ]; then
        echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}正在从 GitHub 获取最新版本信息...${PLAIN}"
    latest_ver=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_ver" ]; then
        echo -e "${RED}获取最新版本失败，请检查网络连接。${PLAIN}"
        exit 1
    fi

    url="https://github.com/zhboner/realm/releases/download/${latest_ver}/realm-${arch_suffix}.tar.gz"
    echo -e "${YELLOW}正在下载 Realm ${latest_ver}...${PLAIN}"
    wget -O /tmp/realm.tar.gz "$url"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败!${PLAIN}"
        exit 1
    fi

    tar -zxf /tmp/realm.tar.gz -C /tmp
    mv /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    mkdir -p "$CONF_DIR"
    
    # 初始化配置文件
    if [ ! -f "$CONF_FILE" ]; then
        touch "$CONF_FILE"
    fi

    setup_service
    rm -rf /tmp/realm*
    echo -e "${GREEN}Realm 安装成功!${PLAIN}"
}

# 设置服务 (Systemd or OpenRC)
setup_service() {
    if [ "$OS_TYPE" = "debian" ]; then
        cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$REALM_BIN -c $CONF_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm
        systemctl start realm
    elif [ "$OS_TYPE" = "alpine" ]; then
        cat > /etc/init.d/realm <<EOF
#!/sbin/openrc-run
description="Realm Service"
command="$REALM_BIN"
command_args="-c $CONF_FILE"
pidfile="/run/realm.pid"
command_background=true
output_log="/var/log/realm.log"
error_log="/var/log/realm.err"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/realm
        rc-update add realm default
        rc-service realm start
    fi
}

# 重启服务
restart_service() {
    # 检查是否有内容
    if ! grep -q "^\[\[endpoints\]\]" "$CONF_FILE"; then
        echo -e "${YELLOW}检测到暂无有效转发规则，服务将保持挂起状态。${PLAIN}"
        if [ "$OS_TYPE" = "debian" ]; then
            systemctl stop realm 2>/dev/null
        elif [ "$OS_TYPE" = "alpine" ]; then
            rc-service realm stop 2>/dev/null
        fi
        return
    fi
    echo -e "${YELLOW}正在启动/重启 Realm 服务...${PLAIN}"
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl restart realm
    elif [ "$OS_TYPE" = "alpine" ]; then
        rc-service realm restart
    fi
    echo -e "${GREEN}服务已应用最新配置！${PLAIN}"
    sleep 1
}

# 卸载 Realm
uninstall_realm() {
    echo -e "${YELLOW}警告: 此操作将删除 Realm、配置文件以及此脚本自身!${PLAIN}"
    read -p "确定要卸载吗？[y/N]: " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            echo -e "${YELLOW}正在停止并移除服务...${PLAIN}"
            if [ "$OS_TYPE" = "debian" ]; then
                systemctl stop realm
                systemctl disable realm
                rm -f /etc/systemd/system/realm.service
                systemctl daemon-reload
            elif [ "$OS_TYPE" = "alpine" ]; then
                rc-service realm stop
                rc-update del realm default
                rm -f /etc/init.d/realm
            fi
            
            echo -e "${YELLOW}正在删除相关文件...${PLAIN}"
            rm -f "$REALM_BIN"
            rm -rf "$CONF_DIR"
            
            echo -e "${GREEN}Realm 卸载成功! 脚本也将被移除。${PLAIN}"
            sleep 1
            # 获取脚本绝对路径并删除
            rm -f "$(readlink -f "$0")"
            exit 0
            ;;
        *)
            echo -e "${GREEN}已取消卸载。${PLAIN}"
            sleep 1
            ;;
    esac
}

# 查看转发列表
list_forwards() {
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}配置文件不存在!${PLAIN}"
        return
    fi
    echo -e "\n${YELLOW}--- 当前转发列表 ---${PLAIN}"
    # 获取所有 endpoint 块的起始行号
    lines=$(grep -n "^\[\[endpoints\]\]" "$CONF_FILE" | cut -d: -f1)
    
    total_lines=$(wc -l < "$CONF_FILE")
    count=1

    for start_line in $lines; do
        # 寻找下一个 endpoint 的行号，如果没找到则默认到文件结尾
        next_line=$(grep -n "^\[\[endpoints\]\]" "$CONF_FILE" | cut -d: -f1 | awk -v s="$start_line" '$1>s {print $1}' | head -n 1)
        if [ -z "$next_line" ]; then
            end_line=$total_lines
        else
            end_line=$((next_line - 1))
        fi

        # 在该块中提取各种值
        block_content=$(sed -n "${start_line},${end_line}p" "$CONF_FILE")
        
        l=$(echo "$block_content" | grep "^listen" | cut -d'"' -f2)
        r=$(echo "$block_content" | grep "^remote" | cut -d'"' -f2)
        
        no_t=0; use_u=0
        echo "$block_content" | grep -q "^[ \t]*no_tcp[ \t]*=[ \t]*true" && no_t=1
        echo "$block_content" | grep -q "^[ \t]*use_udp[ \t]*=[ \t]*true" && use_u=1

        if [ "$l" != "" ] && [ "$r" != "" ]; then
            if [ "$no_t" = "1" ] && [ "$use_u" = "1" ]; then
                net="UDP"
            elif [ "$no_t" = "0" ] && [ "$use_u" = "1" ]; then
                net="TCP+UDP"
            else
                net="TCP"
            fi
            printf "[%d] %s -> %s (%s)\n" "$count" "$l" "$r" "$net"
            count=$((count + 1))
        fi
    done
    echo -e "--------------------\n"
}

# 添加转发
add_forward() {
    echo -e "${YELLOW}请输入本地监听端口 (例如: 8080):${PLAIN}"
    read -p "> " lport
    echo -e "${YELLOW}请输入远程目标地址 / IP / 域名 (例如: 8.8.8.8或google.com):${PLAIN}"
    read -p "> " rhost
    echo -e "${YELLOW}请输入远程目标端口 (例如: 443):${PLAIN}"
    read -p "> " rport
    
    echo -e "${YELLOW}请选择转发协议:${PLAIN}"
    echo -e " 1. TCP (默认)"
    echo -e " 2. UDP"
    echo -e " 3. TCP+UDP"
    read -p "> [1-3]: " proto_choice
    
    if [ -z "$lport" ] || [ -z "$rhost" ] || [ -z "$rport" ]; then
        echo -e "${RED}输入不能为空!${PLAIN}"
        return
    fi
    
    raddr="${rhost}:${rport}"

    no_tcp_val="false"
    use_udp_val="false"
    case "$proto_choice" in
        2) no_tcp_val="true"; use_udp_val="true" ;;
        3) no_tcp_val="false"; use_udp_val="true" ;;
    esac

    cat >> "$CONF_FILE" <<EOF

[[endpoints]]
listen = "0.0.0.0:$lport"
remote = "$raddr"
no_tcp = $no_tcp_val
use_udp = $use_udp_val
EOF
    restart_service
    echo -e "${GREEN}添加成功!${PLAIN}"
}

# 删除规则 (自动)
del_forward() {
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}配置文件不存在!${PLAIN}"
        return
    fi
    
    # 统计当前有多少条规则
    total_rules=$(grep -c "^\[\[endpoints\]\]" "$CONF_FILE")
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        return
    fi

    list_forwards
    echo -e "${YELLOW}请输入要删除的转发序号 [1-$total_rules] (直接回车取消):${PLAIN}"
    read -p "> " num
    
    if [ -z "$num" ]; then 
        echo -e "${GREEN}已取消删除。${PLAIN}"
        return
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total_rules" ]; then
        echo -e "${RED}输入无效的序号!${PLAIN}"
        sleep 1
        return
    fi

    # 使用 awk 重写配置文件，跳过第 $num 个 [[endpoints]] 块
    tmp_file="/tmp/realm_config.toml.tmp"
    awk -v target="$num" '
    BEGIN { count = 0; skip = 0; }
    /^\[\[endpoints\]\]/ {
        count++;
        if (count == target) {
            skip = 1;
        } else {
            skip = 0;
            print $0;
        }
        next;
    }
    {
        if (skip == 0) {
            print $0;
        }
    }
    ' "$CONF_FILE" > "$tmp_file"

    # 清理多余的空白行 (可选，使格式更好看)
    cat "$tmp_file" | awk 'NF > 0 { blank=0; print $0 } NF == 0 && blank==0 { blank=1; print $0 }' > "$CONF_FILE"
    rm -f "$tmp_file"

    restart_service
    echo -e "${GREEN}规则 [$num] 已成功删除!${PLAIN}"
    sleep 1
}

# 修改规则 (自动)
edit_forward() {
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}配置文件不存在!${PLAIN}"
        return
    fi
    
    total_rules=$(grep -c "^\[\[endpoints\]\]" "$CONF_FILE")
    if [ "$total_rules" -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        return
    fi

    list_forwards
    echo -e "${YELLOW}请输入要修改的转发序号 [1-$total_rules] (直接回车取消):${PLAIN}"
    read -p "> " num
    
    if [ -z "$num" ]; then 
        echo -e "${GREEN}已取消修改。${PLAIN}"
        return
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total_rules" ]; then
        echo -e "${RED}输入无效的序号!${PLAIN}"
        sleep 1
        return
    fi

    # 提取当前规则的内容用于默认展示
    # 获取第 num 个 endpoint 的起始和结束行号
    lines=$(grep -n "^\[\[endpoints\]\]" "$CONF_FILE" | cut -d: -f1)
    
    current_count=1
    target_start_line=""
    for start_line in $lines; do
        if [ "$current_count" -eq "$num" ]; then
            target_start_line=$start_line
            break
        fi
        current_count=$((current_count + 1))
    done

    if [ -n "$target_start_line" ]; then
        next_line=$(grep -n "^\[\[endpoints\]\]" "$CONF_FILE" | cut -d: -f1 | awk -v s="$target_start_line" '$1>s {print $1}' | head -n 1)
        if [ -z "$next_line" ]; then
            target_end_line=$(wc -l < "$CONF_FILE")
        else
            target_end_line=$((next_line - 1))
        fi
        
        block_content=$(sed -n "${target_start_line},${target_end_line}p" "$CONF_FILE")
        
        curr_listen=$(echo "$block_content" | grep "^listen" | cut -d'"' -f2)
        curr_raddr=$(echo "$block_content" | grep "^remote" | cut -d'"' -f2)
        
        curr_no_tcp=0; curr_use_udp=0
        echo "$block_content" | grep -q "^[ \t]*no_tcp[ \t]*=[ \t]*true" && curr_no_tcp=1
        echo "$block_content" | grep -q "^[ \t]*use_udp[ \t]*=[ \t]*true" && curr_use_udp=1
    else
        curr_listen=""
        curr_raddr=""
        curr_no_tcp=0; curr_use_udp=0
    fi
    
    curr_lport=$(echo "$curr_listen" | awk -F':' '{print $NF}')
    
    curr_rhost=$(echo "$curr_raddr" | awk -F':' '{OFS=":"; NF--; print $0}')
    [ -z "$curr_rhost" ] && curr_rhost="$curr_raddr"
    curr_rport=$(echo "$curr_raddr" | awk -F':' '{print $NF}')
    
    if [ "$curr_no_tcp" = "1" ] && [ "$curr_use_udp" = "1" ]; then
        curr_net="UDP"
    elif [ "$curr_no_tcp" = "0" ] && [ "$curr_use_udp" = "1" ]; then
        curr_net="TCP+UDP"
    else
        curr_net="TCP"
    fi

    echo -e "${YELLOW}当前本地监听端口: ${GREEN}$curr_lport${PLAIN}"
    read -p "请输入新的监听端口 [回车保持不变]: " new_lport
    [ -z "$new_lport" ] && new_lport=$(echo "$curr_lport" | awk -F':' '{print $NF}')

    echo -e "${YELLOW}当前远程目标地址: ${GREEN}$curr_rhost${PLAIN}"
    read -p "请输入新的目标地址/IP [回车保持不变]: " new_rhost
    [ -z "$new_rhost" ] && new_rhost="$curr_rhost"

    echo -e "${YELLOW}当前远程目标端口: ${GREEN}$curr_rport${PLAIN}"
    read -p "请输入新的目标端口 [回车保持不变]: " new_rport
    [ -z "$new_rport" ] && new_rport="$curr_rport"

    echo -e "${YELLOW}当前转发协议: ${GREEN}$curr_net${PLAIN}"
    echo -e " 1. TCP"
    echo -e " 2. UDP"
    echo -e " 3. TCP+UDP"
    read -p "请选择新的协议 [1-3, 回车保持不变]: " proto_choice
    
    new_no_tcp="false"; new_use_udp="false"
    case "$proto_choice" in
        1) new_no_tcp="false"; new_use_udp="false" ;;
        2) new_no_tcp="true"; new_use_udp="true" ;;
        3) new_no_tcp="false"; new_use_udp="true" ;;
        *) 
           if [ "$curr_net" = "UDP" ]; then
               new_no_tcp="true"; new_use_udp="true"
           elif [ "$curr_net" = "TCP+UDP" ]; then
               new_no_tcp="false"; new_use_udp="true"
           else
               new_no_tcp="false"; new_use_udp="false"
           fi
           ;;
    esac

    new_raddr="${new_rhost}:${new_rport}"

    # 使用 awk 替换对应序号的块
    tmp_file="/tmp/realm_config.toml.tmp"
    awk -v target="$num" -v nl="$new_lport" -v nr="$new_raddr" -v notcp="$new_no_tcp" -v useudp="$new_use_udp" '
    BEGIN { count = 0; skip = 0; }
    /^\[\[endpoints\]\]/ {
        count++;
        if (count == target) {
            skip = 1;
            print "[[endpoints]]";
            print "listen = \"0.0.0.0:" nl "\"";
            print "remote = \"" nr "\"";
            print "no_tcp = " notcp;
            print "use_udp = " useudp;
        } else {
            skip = 0;
            print $0;
        }
        next;
    }
    {
        if (skip == 0) {
            print $0;
        }
    }
    ' "$CONF_FILE" > "$tmp_file"

    cat "$tmp_file" | awk 'NF > 0 { blank=0; print $0 } NF == 0 && blank==0 { blank=1; print $0 }' > "$CONF_FILE"
    rm -f "$tmp_file"

    restart_service
    echo -e "${GREEN}规则 [$num] 修改成功!${PLAIN}"
    sleep 1
}

# 检查服务状态
check_status() {
    if [ ! -f "$REALM_BIN" ]; then
        echo -e "${RED}未安装${PLAIN}"
        return
    fi
    
    if ! grep -q "^\[\[endpoints\]\]" "$CONF_FILE" 2>/dev/null; then
        echo -e "${YELLOW}待添加规则 (已挂起)${PLAIN}"
        return
    fi
    
    if [ "$OS_TYPE" = "debian" ]; then
        if systemctl is-active --quiet realm; then
            echo -e "${GREEN}运行中 (systemd)${PLAIN}"
        else
            echo -e "${RED}已停止 (systemd)${PLAIN}"
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        if rc-service realm status | grep -q 'started'; then
             echo -e "${GREEN}运行中 (OpenRC)${PLAIN}"
        else
             echo -e "${RED}已停止 (OpenRC)${PLAIN}"
        fi
    else
        # Fallback 检查进程
        if pgrep -x "realm" > /dev/null; then
            echo -e "${GREEN}运行中 (PID)${PLAIN}"
        else
            echo -e "${RED}已停止${PLAIN}"
        fi
    fi
}

# 查看日志
view_log() {
    echo -e "${YELLOW}正在获取 Realm 日志 (按 Ctrl+C 退出)...${PLAIN}"
    if [ "$OS_TYPE" = "debian" ]; then
        journalctl -u realm -n 50 -f
    elif [ "$OS_TYPE" = "alpine" ]; then
        if [ -f "/var/log/realm.err" ]; then
            tail -n 50 -f /var/log/realm.err /var/log/realm.log
        else
            echo -e "${RED}暂无日志文件。${PLAIN}"
            sleep 1
        fi
    else
        echo -e "${RED}不支持的系统日志查看方式。${PLAIN}"
        sleep 1
    fi
}

# 主菜单
main_menu() {
    clear
    status_str=$(check_status)
    echo -e "#############################################################"
    echo -e "#                Realm 转发一键管理脚本                     #"
    echo -e "#############################################################"
    echo -e " 操作系统: ${GREEN}${OS_PRETTY_NAME}${PLAIN}"
    echo -e " 当前状态: $status_str"
    echo -e "#############################################################"
    echo -e " 1. 安装 Realm"
    echo -e " 2. 卸载 Realm"
    echo -e "-------------------------------------------------------------"
    echo -e " 3. 添加转发规则"
    echo -e " 4. 删除转发规则"
    echo -e " 5. 修改转发规则"
    echo -e " 6. 查看转发规则"
    echo -e "-------------------------------------------------------------"
    echo -e " 7. 查看运行日志"
    echo -e "-------------------------------------------------------------"
    echo -e " 8. 启动 Realm 服务"
    echo -e " 9. 停止 Realm 服务"
    echo -e "10. 重启 Realm 服务"
    echo -e "-------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo -e "#############################################################"
    read -p "请输入数字 [0-10]: " num
    case "$num" in
        1) install_realm ;;
        2) uninstall_realm ;;
        3) add_forward ;;
        4) del_forward ;;
        5) edit_forward ;;
        6) list_forwards; echo ""; echo -e "${YELLOW}按回车键继续...${PLAIN}"; read -r dummy ;;
        7) view_log ;;
        8)
            echo -e "${YELLOW}正在启动...${PLAIN}"
            if [ "$OS_TYPE" = "debian" ]; then systemctl start realm; else rc-service realm start; fi
            sleep 1
            ;;
        9)
            echo -e "${YELLOW}正在停止...${PLAIN}"
            if [ "$OS_TYPE" = "debian" ]; then systemctl stop realm; else rc-service realm stop; fi
            sleep 1
            ;;
        10) restart_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确数字!${PLAIN}" && sleep 1 ;;
    esac
    # 循环调用主菜单
    main_menu
}


main_menu
