#!/bin/bash
# ======================================
#   Realm 一键安装 & 转发管理器 v3.0
# ======================================

REALM_BIN="/usr/local/bin/realm"
CONFIG_DIR="/etc/realm"
CONFIG="$CONFIG_DIR/config.toml"
BACKUP_DIR="$CONFIG_DIR/backup"
SERVICE="/etc/systemd/system/realm.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 初始化环境与检测安装
init() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    if [ ! -f "$CONFIG" ]; then
        cat > "$CONFIG" << EOF
[network]
use_udp = true

EOF
    fi
}

# 检测 Realm 主程序与服务状态
check_installation() {
    if [ ! -f "$REALM_BIN" ]; then
        echo -e "${RED}警告：检测到未安装 Realm 主程序！${PLAIN}"
        read -rp "是否立即自动下载并安装 Realm？(y/n) [y]: " choice
        choice=${choice:-y}
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            install_realm
        else
            echo -e "${YELLOW}请先安装 Realm 后再使用管理功能。${PLAIN}"
            exit 1
        fi
    fi
}

# 一键安装 Realm 主程序与服务
install_realm() {
    echo -e "\n${YELLOW}--- 开始安装 Realm ---${PLAIN}"
    
    # 架构检测
    local arch=$(uname -m)
    local target_arch=""
    case "$arch" in
        x86_64|amd64) target_arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) target_arch="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}错误：暂不支持的系统架构 $arch${PLAIN}"; return 1 ;;
    esac

    # 依赖检查
    if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null; then
        echo -e "${YELLOW}正在安装必要依赖 (curl, tar)...${PLAIN}"
        apt-get update && apt-get install -y curl tar || yum install -y curl tar
    fi

    # 获取最新发布版本并下载
    echo -e "${YELLOW}正在下载最新的 Realm 程序...${PLAIN}"
    local download_url="https://github.com/zhboner/realm/releases/latest/download/realm-${target_arch}.tar.gz"
    
    curl -L -o /tmp/realm.tar.gz "$download_url"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络（特别是 GitHub 连接）${PLAIN}"
        return 1
    fi

    tar -xvf /tmp/realm.tar.gz -C /tmp/
    mv /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    # 配置 systemd 服务
    cat > "$SERVICE" << EOF
[Unit]
Description=Realm Relay Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$REALM_BIN -c $CONFIG
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    
    init
    echo -e "${GREEN}Realm 安装并配置成功！${PLAIN}"
}

# 卸载 Realm
uninstall_realm() {
    echo -e "\n${RED}--- 正在卸载 Realm ---${PLAIN}"
    read -rp "确定要彻底卸载 Realm 及其所有配置吗？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop realm >/dev/null 2>&1
        systemctl disable realm >/dev/null 2>&1
        rm -f "$SERVICE"
        rm -f "$REALM_BIN"
        rm -rf "$CONFIG_DIR"
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成！${PLAIN}"
        exit 0
    fi
}

# 校验规则是否存在
rule_exists() {
    grep -q "listen = \"0.0.0.0:$1\"" "$CONFIG"
}

# 1. 添加转发
add_rule() {
    echo -e "\n${YELLOW}--- 添加转发规则 ---${PLAIN}"
    read -rp "本地监听端口 (如 1234): " listen_port
    
    if [[ ! "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        echo -e "${RED}错误：请输入有效端口号 (1-65535)${PLAIN}"
        return
    fi

    if rule_exists "$listen_port"; then
        echo -e "${RED}错误：端口 $listen_port 的规则已存在！${PLAIN}"
        return
    fi

    read -rp "目标地址与端口 (如 1.2.3.4:8080 或 example.com:8080): " remote
    read -rp "备注信息 (可选): " note

    cat >> "$CONFIG" << EOF

[[endpoints]]
listen = "0.0.0.0:$listen_port"
remote = "$remote"
EOF
    [ -n "$note" ] && echo "# $note" >> "$CONFIG"

    echo -e "${GREEN}规则添加成功！${PLAIN}"
    auto_restart
}

# 2. 删除转发
delete_rule() {
    echo -e "\n${YELLOW}--- 删除转发规则 ---${PLAIN}"
    list_rules
    read -rp "请输入要删除的本地监听端口: " port

    if ! rule_exists "$port"; then
        echo -e "${RED}错误：未找到监听端口 $port 的规则${PLAIN}"
        return
    fi

    awk -v port="0.0.0.0:$port" '
    BEGIN { skip = 0 }
    /\[\[endpoints\]\]/ {
        if (block ~ port) { block = "" }
        else { printf "%s", block }
        block = $0 "\n"
        skip = 1
        next
    }
    {
        if (skip) { block = block $0 "\n" }
        else { print $0 }
    }
    END {
        if (block !~ port) { printf "%s", block }
    }
    ' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    echo -e "${GREEN}端口 $port 的规则已成功删除！${PLAIN}"
    auto_restart
}

# 3. 修改转发
edit_rule() {
    echo -e "\n${YELLOW}--- 修改转发规则 ---${PLAIN}"
    list_rules
    read -rp "请输入要修改的本地监听端口: " port

    if ! rule_exists "$port"; then
        echo -e "${RED}错误：未找到监听端口 $port 的规则${PLAIN}"
        return
    fi

    echo -e "${YELLOW}找到对应规则，准备重新设置：${PLAIN}"
    read -rp "新目标地址与端口 (如 1.2.3.4:8080): " new_remote
    read -rp "新备注 (可选): " new_note

    awk -v port="0.0.0.0:$port" '
    BEGIN { skip = 0 }
    /\[\[endpoints\]\]/ {
        if (block ~ port) { block = "" }
        else { printf "%s", block }
        block = $0 "\n"
        skip = 1
        next
    }
    {
        if (skip) { block = block $0 "\n" }
        else { print $0 }
    }
    END {
        if (block !~ port) { printf "%s", block }
    }
    ' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

    cat >> "$CONFIG" << EOF

[[endpoints]]
listen = "0.0.0.0:$port"
remote = "$new_remote"
EOF
    [ -n "$new_note" ] && echo "# $new_note" >> "$CONFIG"

    echo -e "${GREEN}规则修改成功！${PLAIN}"
    auto_restart
}

# 4. 查看规则
list_rules() {
    echo -e "\n${YELLOW}================ 当前转发规则 ================${PLAIN}"
    if ! grep -q "\[\[endpoints\]\]" "$CONFIG"; then
        echo "暂无任何转发规则。"
        return
    fi

    awk '
    /\[\[endpoints\]\]/ { if (listen) print "监听: " listen " --> 目标: " remote " (" note ")"; listen=""; remote=""; note="无备注" }
    /listen/ { gsub(/["\t ]/, "", $0); split($0, a, "="); listen=a[2] }
    /remote/ { gsub(/["\t ]/, "", $0); split($0, a, "="); remote=a[2] }
    /#/ { gsub(/^#[ \t]*/, "", $0); note=$0 }
    END { if (listen) print "监听: " listen " --> 目标: " remote " (" note ")" }
    ' "$CONFIG"
    echo -e "${YELLOW}==============================================${PLAIN}"
}

# 5-9. 服务管理
restart_realm() { systemctl restart realm && echo -e "${GREEN}Realm 服务已重启${PLAIN}"; }
start_realm()   { systemctl start realm && echo -e "${GREEN}Realm 服务已启动${PLAIN}"; }
stop_realm()    { systemctl stop realm && echo -e "${GREEN}Realm 服务已停止${PLAIN}"; }
status_realm()  { systemctl status realm --no-pager; }
logs_realm()    { echo -e "${YELLOW}按 Ctrl+C 退出日志查看${PLAIN}"; journalctl -u realm -f -n 50; }

# 10. 备份配置
backup_config() {
    local filename="config_backup_$(date +%Y%m%d_%H%M%S).toml"
    cp "$CONFIG" "$BACKUP_DIR/$filename"
    echo -e "${GREEN}备份成功！文件保存至: $BACKUP_DIR/$filename${PLAIN}"
}

# 11. 恢复配置
restore_config() {
    echo -e "\n${YELLOW}--- 可用的备份文件 ---${PLAIN}"
    local files=("$BACKUP_DIR"/*.toml)
    if [ ! -e "${files[0]}" ]; then
        echo -e "${RED}未找到任何备份文件！${PLAIN}"
        return
    fi

    select file in "${files[@]}"; do
        if [ -n "$file" ]; then
            cp "$file" "$CONFIG"
            echo -e "${GREEN}配置已成功恢复！${PLAIN}"
            auto_restart
            break
        else
            echo -e "${RED}无效选项${PLAIN}"
        fi
    done
}

# 提示重启
auto_restart() {
    read -rp "是否立即重启 Realm 生效？(y/n) [y]: " choice
    choice=${choice:-y}
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        restart_realm
    fi
}

# 主菜单
main_menu() {
    init
    check_installation
    while true; do
        echo -e "
${GREEN}======================================${PLAIN}
${GREEN}      Realm 转发管理器 v3.0${PLAIN}
${GREEN}======================================${PLAIN}
 ${GREEN}1.${PLAIN} 添加转发       ${GREEN}7.${PLAIN} 停止 Realm
 ${GREEN}2.${PLAIN} 删除转发       ${GREEN}8.${PLAIN} 查看状态
 ${GREEN}3.${PLAIN} 修改转发       ${GREEN}9.${PLAIN} 查看日志
 ${GREEN}4.${PLAIN} 查看规则       ${GREEN}10.${PLAIN} 备份配置
 ${GREEN}5.${PLAIN} 重启 Realm     ${GREEN}11.${PLAIN} 恢复配置
 ${GREEN}6.${PLAIN} 启动 Realm      ${GREEN}12.${PLAIN} ${RED}卸载 Realm${PLAIN}
 ${GREEN}0.${PLAIN} 退出
"
        read -rp "请输入数字 [0-12]: " option
        case "$option" in
            1) add_rule ;;
            2) delete_rule ;;
            3) edit_rule ;;
            4) list_rules ;;
            5) restart_realm ;;
            6) start_realm ;;
            7) stop_realm ;;
            8) status_realm ;;
            9) logs_realm ;;
            10) backup_config ;;
            11) restore_config ;;
            12) uninstall_realm ;;
            0) exit 0 ;;
            *) echo -e "${RED}请输入正确的数字！${PLAIN}" ;;
        esac
    done
}

# 运行主逻辑
main_menu
