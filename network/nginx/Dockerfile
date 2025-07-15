FROM alpine:latest AS builder

LABEL stage=builder

# ENV HTTP_PROXY=http://192.168.2.11:10809
# ENV HTTPS_PROXY=http://192.168.2.11:10809

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装软件包
RUN apk update && apk add --no-cache bash curl coreutils jq rsync

# 安装编译选项
RUN apk add --no-cache build-base linux-headers pcre-dev zlib-dev openssl-dev libaio-dev

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
LABEL description="Nginx For Debian"

# 定义工作目录
ARG WORK_DIR=/app

# 定义用户和组
ARG PUID=1000
ARG PGID=1000
ARG USERNAME=nginx
ARG GROUPNAME=nginx

# 定义端口号
ARG SSHD_PORT=22
ARG HTTP_PORT=80

# 导出用户和组
ENV PUID=$PUID \
	PGID=$PGID \
	USERNAME=$USERNAME \
	GROUPNAME=$GROUPNAME

# 导出端口号
ENV SSHD_PORT=$SSHD_PORT \
	HTTP_PORT=$HTTP_PORT
	
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

# 安装核心依赖库
RUN apk update && apk add --no-cache bash ca-certificates coreutils gawk openssl sqlite tzdata shadow su-exec

# 安装运维工具
RUN apk add --no-cache bc curl git jq openssh openssh-server-pam rsync tar wget

RUN rm -rf /var/cache/apk/*

# 工作目录
WORKDIR $WORK_DIR

# 持久化目录
VOLUME /config /data

# 复制文件
COPY --from=builder $WORK_DIR/install $WORK_DIR/install
COPY --from=builder /data $WORK_DIR/config/data
COPY --from=builder /config $WORK_DIR/config/etc

COPY etc/ $WORK_DIR/config
COPY --chown=$PUID:$PGID scripts/ $WORK_DIR/scripts

# 创建目录并设置权限
RUN chown -R $PUID:$PGID $WORK_DIR && \
	chmod +x $WORK_DIR/scripts/*.sh

# 暴露端口
EXPOSE ${HTTP_PORT}

# 启动执行脚本
ENTRYPOINT ["/app/scripts/entrypoint.sh", "run"]