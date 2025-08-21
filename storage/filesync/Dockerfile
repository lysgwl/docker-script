FROM alpine:latest AS builder

LABEL stage=builder

# ENV HTTP_PROXY=http://192.168.2.11:10809
# ENV HTTPS_PROXY=http://192.168.2.11:10809

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装软件包
RUN apk update && apk add --no-cache bash curl coreutils jq rsync

# 工作目录
ARG WORK_DIR=/app
WORKDIR $WORK_DIR

# 复制文件
COPY scripts/ $WORK_DIR/scripts
COPY usr/ $WORK_DIR/downloads

# 设置运行权限
RUN chmod +x $WORK_DIR/scripts/*.sh

# 执行初始化
RUN $WORK_DIR/scripts/entrypoint.sh init

# CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]

FROM alpine:latest

LABEL version="1.0"
LABEL author="wanglei<lysgwl@163.com>"
LABEL description="FileSync For Debian"

# 定义工作目录
ARG WORK_DIR=/app

# 定义用户和组
ARG PUID=1001
ARG PGID=1001
ARG USERNAME=filesync
ARG GROUPNAME=filesync

# 定义端口号
ARG FILEBROWSER_PORT=8080
ARG ALIST_HTTP_PORT=5244
ARG SYNCTHING_HTTP_PORT=8384
ARG SYNCTHING_TRANS_PORT=22000
ARG SYNCTHING_DISCOVERY_PORT=21027

# 导出用户和组
ENV PUID=$PUID \
	PGID=$PGID \
	USERNAME=$USERNAME \
	GROUPNAME=$GROUPNAME
	
# 导出端口号
ENV FILEBROWSER_PORT=$FILEBROWSER_PORT \
	ALIST_HTTP_PORT=$ALIST_HTTP_PORT \
	SYNCTHING_HTTP_PORT=$SYNCTHING_HTTP_PORT \
	SYNCTHING_TRANS_PORT=$SYNCTHING_TRANS_PORT \
	SYNCTHING_DISCOVERY_PORT=$SYNCTHING_DISCOVERY_PORT
	
ENV LANG=C.UTF-8 \
	WORK_DIR=$WORK_DIR
	
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
COPY --chown=$PUID:$PGID scripts/ $WORK_DIR/scripts
COPY --chown=$PUID:$PGID etc/ $WORK_DIR/config

# 持久化目录
VOLUME /config /data

# 创建目录并设置权限
RUN chown -R $PUID:$PGID $WORK_DIR && \
	chmod +x $WORK_DIR/scripts/*.sh

# 暴露端口
EXPOSE ${FILEBROWSER_PORT} \
	${ALIST_HTTP_PORT} \
	${SYNCTHING_HTTP_PORT} \
	${SYNCTHING_TRANS_PORT}/tcp \
	${SYNCTHING_TRANS_PORT}/udp \
	${SYNCTHING_DISCOVERY_PORT}/udp

# 启动执行脚本
ENTRYPOINT ["/app/scripts/entrypoint.sh", "run"]