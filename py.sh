#!/bin/bash

CORE_FILE="/etc/proxy-core"
INFO_FILE="/root/proxy-info.txt"

SING_DIR="/etc/sing-box"
XRAY_DIR="/usr/local/etc/xray"

pause(){ read -rp "回车继续..."; }
uuid(){ cat /proc/sys/kernel/random/uuid; }
port(){ shuf -i 20000-60000 -n 1; }
rand(){ openssl rand -hex 8; }
IP=$(curl -s ipinfo.io/ip)

install_base(){
  apt update -y
  apt install -y curl wget unzip tar socat nano openssl
}

# ================= 内核 =================

install_singbox(){
  install_base
  ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4)
  wget -q https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-amd64.tar.gz
  tar -xzf sing-box-*.tar.gz
  mv sing-box-*/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
  mkdir -p $SING_DIR

cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c $SING_DIR/config.json
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  echo "sing-box" > $CORE_FILE
}

install_xray(){
  install_base
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  systemctl enable xray
  echo "xray" > $CORE_FILE
}

# ================= 协议：VLESS =================

install_vless(){
  id=$(uuid); p=$(port)
  CORE=$(cat $CORE_FILE)

if [ "$CORE" = "sing-box" ]; then
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"vless",
  "listen":"::",
  "listen_port":$p,
  "users":[{"uuid":"$id"}]
 }],
 "outbounds":[{"type":"direct"}]
}
EOF
else
cat >$XRAY_DIR/config.json <<EOF
{
 "inbounds":[{
  "port":$p,
  "protocol":"vless",
  "settings":{"clients":[{"id":"$id"}]}
 }],
 "outbounds":[{"protocol":"freedom"}]
}
EOF
fi

cat >$INFO_FILE <<EOF
[VLESS]
地址：$IP
端口：$p
UUID：$id

客户端链接：
vless://$id@$IP:$p?encryption=none#VLESS
EOF
}

# ================= Reality =================

install_reality(){
  id=$(uuid); p=$(port); key=$(rand); sni=www.cloudflare.com
  CORE=$(cat $CORE_FILE)

if [ "$CORE" = "sing-box" ]; then
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"vless",
  "listen":"::",
  "listen_port":$p,
  "users":[{"uuid":"$id","flow":"xtls-rprx-vision"}],
  "tls":{
   "enabled":true,
   "reality":{
    "enabled":true,
    "handshake":{"server":"$sni","server_port":443},
    "private_key":"$key"
   }
  }
 }]
}
EOF
else
cat >$XRAY_DIR/config.json <<EOF
{
 "inbounds":[{
  "port":$p,
  "protocol":"vless",
  "settings":{"clients":[{"id":"$id","flow":"xtls-rprx-vision"}]},
  "streamSettings":{
   "security":"reality",
   "realitySettings":{
    "dest":"$sni:443",
    "privateKey":"$key"
   }
  }
 }]
}
EOF
fi

cat >$INFO_FILE <<EOF
[VLESS Reality]
IP：$IP
端口：$p
UUID：$id
SNI：$sni
私钥：$key

客户端：
vless://$id@$IP:$p?security=reality&sni=$sni&fp=chrome#Reality
EOF
}

# ================= sing-box 专属 =================

install_hysteria2(){
  p=$(port); pw=$(rand)
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"hysteria2",
  "listen":"::",
  "listen_port":$p,
  "users":[{"password":"$pw"}]
 }]
}
EOF

cat >$INFO_FILE <<EOF
[Hysteria2]
IP：$IP
端口：$p
密码：$pw

hy2://$pw@$IP:$p#Hysteria2
EOF
}

install_tuic(){
  p=$(port); pw=$(rand)
cat >$SING_DIR/config.json <<EOF
{
 "inbounds":[{
  "type":"tuic",
  "listen":"::",
  "listen_port":$p,
  "users":[{"password":"$pw"}]
 }]
}
EOF

cat >$INFO_FILE <<EOF
[TUIC]
tuic://$pw@$IP:$p
EOF
}

# ================= 菜单 =================

choose_core(){
  clear
  echo "选择内核"
  echo "1. sing-box"
  echo "2. xray"
  read -rp ">" c
  [ "$c" = "1" ] && install_singbox
  [ "$c" = "2" ] && install_xray
}

choose_proto(){
  CORE=$(cat $CORE_FILE)
  clear
  echo "选择协议 ($CORE)"
  echo "1. VLESS"
  echo "2. VLESS Reality"
  [ "$CORE" = "sing-box" ] && echo "3. Hysteria2"
  [ "$CORE" = "sing-box" ] && echo "4. TUIC"
  read -rp ">" p

  case $p in
    1) install_vless ;;
    2) install_reality ;;
    3) [ "$CORE" = "sing-box" ] && install_hysteria2 ;;
    4) [ "$CORE" = "sing-box" ] && install_tuic ;;
  esac
}

start(){
  systemctl restart $(cat $CORE_FILE)
}

uninstall(){
  systemctl stop sing-box xray 2>/dev/null
  rm -rf $SING_DIR $XRAY_DIR /usr/local/bin/sing-box
  rm -f /etc/systemd/system/sing-box.service $CORE_FILE $INFO_FILE
  systemctl daemon-reload
}

# ================= 主面板 =================

while true; do
clear
echo "========== 内置代理面板 =========="
echo "1. 安装协议"
echo "2. 查看节点信息"
echo "3. 启动服务"
echo "4. 卸载"
echo "0. 退出"
read -rp ">" n

case $n in
  1) choose_core; choose_proto; start; pause ;;
  2) cat $INFO_FILE; pause ;;
  3) start; pause ;;
  4) uninstall; pause ;;
  0) exit ;;
esac
done
