# ========================
# 全局参数
# ========================
ARG WORK_DIR=/app
ARG UTILS_VERSION=latest

# ========================
# 阶段1: 定义utils镜像源
# ========================
FROM docker-utils:${UTILS_VERSION} AS utils-source

# ========================
# 阶段2: 编译构建阶段
# ========================
FROM alpine:latest AS builder
LABEL stage=builder

# 定义工作目录
ARG WORK_DIR
ENV WORK_DIR=$WORK_DIR \
	UTILS_DIR=$WORK_DIR/utils
	
# ENV HTTP_PROXY=http://192.168.2.11:10809
# ENV HTTPS_PROXY=http://192.168.2.11:10809

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装软件包
RUN apk update && apk add --no-cache bash curl coreutils jq rsync

# 工作目录
WORKDIR $WORK_DIR

# 复制文件
COPY --from=utils-source /app/utils $WORK_DIR/utils
COPY scripts/ $WORK_DIR/scripts
COPY usr/ $WORK_DIR/downloads

# 设置运行权限
RUN chmod +x $WORK_DIR/scripts/*.sh && \
	find $WORK_DIR/utils -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
	
# 执行初始化
RUN $WORK_DIR/scripts/entrypoint.sh init
# CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]

# ========================
# 阶段3: 主构建阶段
# ========================
FROM alpine:latest AS master

LABEL version="1.0"
LABEL author="wanglei<lysgwl@163.com>"
LABEL description="FileSync For Debian"

# 定义工作目录
ARG WORK_DIR

# 定义用户和组
ARG PUID=1001
ARG PGID=1001
ARG USERNAME=filesync
ARG GROUPNAME=filesync

# 定义端口号
ARG FILEBROWSER_PORT=8080
ARG OPENLIST_HTTP_PORT=5244
ARG VERYSYNC_HTTP_PORT=8886
ARG SYNCTHING_HTTP_PORT=8384
ARG SYNCTHING_TRANS_PORT=22000
ARG SYNCTHING_DISCOVERY_PORT=21027

# 系统环境变量
ENV LANG=C.UTF-8 \
	TZ=Asia/Shanghai

# 应用目录变量
ENV WORK_DIR=$WORK_DIR \
	UTILS_DIR=$WORK_DIR/utils

# 用户变量
ENV PUID=$PUID \
	PGID=$PGID \
	USERNAME=$USERNAME \
	GROUPNAME=$GROUPNAME
	
# 端口变量
ENV FILEBROWSER_PORT=$FILEBROWSER_PORT \
	OPENLIST_HTTP_PORT=$OPENLIST_HTTP_PORT \
	VERYSYNC_HTTP_PORT=$VERYSYNC_HTTP_PORT \
	SYNCTHING_HTTP_PORT=$SYNCTHING_HTTP_PORT \
	SYNCTHING_TRANS_PORT=$SYNCTHING_TRANS_PORT \
	SYNCTHING_DISCOVERY_PORT=$SYNCTHING_DISCOVERY_PORT
	
# 设置时区和语言
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone
	
# 创建用户和组
RUN addgroup -g $PGID $GROUPNAME && \
	adduser -D -H -G $GROUPNAME -u $PUID $USERNAME
	
# 设置镜像源 (mirrors.ustc.edu.cn mirrors.aliyun.com)
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装核心依赖库 (sqlite shadow)
RUN apk update && apk add --no-cache bash ca-certificates coreutils dcron gawk openssl su-exec tzdata

# 安装运维工具 (cifs-utils git netcat-openbsd openssh openssh-server-pam samba vsftpd) (tar wget)
RUN apk add --no-cache bc curl jq rsync xmlstarlet

RUN rm -rf /var/cache/apk/*

# 工作目录
WORKDIR $WORK_DIR

# 复制文件
COPY --chown=$PUID:$PGID --from=builder $WORK_DIR/install $WORK_DIR/install
COPY --from=utils-source /app/utils $WORK_DIR/utils
COPY --chown=$PUID:$PGID scripts/ $WORK_DIR/scripts
COPY --chown=$PUID:$PGID etc/ $WORK_DIR/config

# 创建目录并设置权限
RUN chown -R $PUID:$PGID $WORK_DIR && \
	chmod +x $WORK_DIR/scripts/*.sh

# 持久化目录
VOLUME /config /data

# 暴露端口
EXPOSE ${FILEBROWSER_PORT} \
	${OPENLIST_HTTP_PORT} \
	${VERYSYNC_HTTP_PORT} \
	${SYNCTHING_HTTP_PORT} \
	${SYNCTHING_TRANS_PORT}/tcp \
	${SYNCTHING_TRANS_PORT}/udp \
	${SYNCTHING_DISCOVERY_PORT}/udp 
	
SHELL ["/bin/bash", "-c"]
	
# 启动执行脚本
ENTRYPOINT ["/bin/bash", "/app/scripts/entrypoint.sh", "run"]