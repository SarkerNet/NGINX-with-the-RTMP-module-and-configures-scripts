#!/bin/bash

# =========================================================
# Sarker Net - Simple RTMP to HLS Server (No DASH/ABS)
# =========================================================

# 1. Check for Root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Variables
NGINX_VER="1.24.0"
INSTALL_PATH="/usr/local/nginx"
WEB_ROOT="/var/www/html/stream"
HLS_PATH="${WEB_ROOT}/hls"

echo "=== 1. Updating System & Installing Dependencies ==="
apt-get update -y
apt-get install -y build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev unzip git wget ffmpeg

echo "=== 2. Downloading Nginx & RTMP Module ==="
cd /tmp
if [ ! -d "nginx-${NGINX_VER}" ]; then
    wget https://nginx.org/download/nginx-${NGINX_VER}.tar.gz
    tar -zxvf nginx-${NGINX_VER}.tar.gz
fi

if [ ! -d "nginx-rtmp-module" ]; then
    git clone https://github.com/arut/nginx-rtmp-module.git
fi

echo "=== 3. Compiling Nginx ==="
cd nginx-${NGINX_VER}
./configure \
    --prefix=${INSTALL_PATH} \
    --with-http_ssl_module \
    --add-module=../nginx-rtmp-module \
    --with-cc-opt="-Wno-error"

make
make install

echo "=== 4. Setting up Directories ==="
mkdir -p ${HLS_PATH}
chmod -R 777 ${WEB_ROOT}

echo "=== 5. Creating Simplified Nginx Configuration ==="
mv ${INSTALL_PATH}/conf/nginx.conf ${INSTALL_PATH}/conf/nginx.conf.bak 2>/dev/null

cat > ${INSTALL_PATH}/conf/nginx.conf <<EOF
worker_processes  auto;

events {
    worker_connections  1024;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            # HLS Configuration (Single Quality)
            hls on;
            hls_path ${HLS_PATH};
            hls_fragment 4;
            hls_playlist_length 60;
            
            # Clean up old fragments
            hls_cleanup on;
        }
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       80;
        server_name  localhost;

        # HLS Playback
        location /hls {
            # CORS setup (allows web players to access the stream)
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length';

            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias ${HLS_PATH};
        }

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
EOF

echo "=== 6. Installing Systemd Service ==="
cat > /lib/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and RTMP Server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${INSTALL_PATH}/logs/nginx.pid
ExecStartPre=${INSTALL_PATH}/sbin/nginx -t
ExecStart=${INSTALL_PATH}/sbin/nginx
ExecReload=${INSTALL_PATH}/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Reload Daemon and Start
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

# Get IP Address
IP_ADDR=$(hostname -I | cut -d' ' -f1)

echo ""
echo "=========================================================="
echo "   INSTALLATION COMPLETE - Simple HLS Server              "
echo "=========================================================="
echo "1. Stream Input (OBS/Encoder):"
echo "   RTMP URL: rtmp://$IP_ADDR/live"
echo "   Stream Key: test"
echo ""
echo "2. Playback URL (HLS):"
echo "   http://$IP_ADDR/hls/test.m3u8"
echo "=========================================================="
