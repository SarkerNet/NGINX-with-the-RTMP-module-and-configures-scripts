#!/bin/bash

# =========================================================
# Sarker Net - Specific RTMP to HLS Configuration
# URL Structure: rtmp://ip/hls/name -> http://ip/hls/name.m3u8
# =========================================================

# 1. Check for Root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Variables
NGINX_VER="1.24.0"
INSTALL_PATH="/usr/local/nginx"
# We use this exact path so the URL http://ip/hls maps correctly
WEB_ROOT="/var/www/html"
HLS_DIR="${WEB_ROOT}/hls"

echo "=== 1. Installing Dependencies ==="
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

echo "=== 4. Configuring Directories ==="
# Create the HLS directory
mkdir -p ${HLS_DIR}
# Give permissions so Nginx can write to it
chmod -R 777 ${WEB_ROOT}

echo "=== 5. Writing nginx.conf ==="
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

        # Application name is 'hls' to match your requested URL:
        # rtmp://server/hls/streamname
        application hls {
            live on;
            record off;

            hls on;
            # Files will be stored in /var/www/html/hls/
            hls_path ${HLS_DIR};
            hls_fragment 3;
            hls_playlist_length 60;
            
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

        # This block serves the files via HTTP
        # Request: http://server/hls/streamname.m3u8
        # Maps to: /var/www/html/hls/streamname.m3u8
        location /hls {
            # CORS headers for web players
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length';

            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            
            # 'root' means the URL path is appended to this path
            # /hls becomes /var/www/html/hls
            root ${WEB_ROOT};
            
            # Disable caching so users always get the live playlist
            add_header Cache-Control no-cache;
        }

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
EOF

echo "=== 6. Creating System Service ==="
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

# Start Nginx
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

# Get IP
IP_ADDR=$(hostname -I | cut -d' ' -f1)

echo ""
echo "=========================================================="
echo "   Sarker Net - Configuration Complete"
echo "=========================================================="
echo "1. RTMP Publish URL:"
echo "   rtmp://$IP_ADDR/hls/streamname"
echo ""
echo "2. HLS Playback URL:"
echo "   http://$IP_ADDR/hls/streamname.m3u8"
echo "=========================================================="
