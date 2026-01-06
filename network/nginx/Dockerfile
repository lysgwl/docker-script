# ========================
# 全局参数
# ========================
ARG WORK_DIR=/app
ARG BASE_IMAGE=alpine:latest
ARG BUILD_VERSION=1.0
ARG UTILS_IMAGE_NAME=docker-utils
ARG UTILS_VERSION=latest

# ========================
# 阶段1: 定义utils镜像源
# ========================
FROM ${UTILS_IMAGE_NAME}:${UTILS_VERSION} AS utils-source

# ========================
# 阶段2: 编译构建阶段
# ========================
FROM ${BASE_IMAGE} AS builder
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

# 安装编译选项
RUN apk add --no-cache build-base linux-headers pcre-dev zlib-dev openssl-dev libaio-dev

# 工作目录
WORKDIR $WORK_DIR

# 复制文件
COPY --from=utils-source /app/utils $WORK_DIR/utils
COPY scripts/ $WORK_DIR/scripts
COPY usr/ $WORK_DIR/downloads

# 运行权限
RUN chmod +x $WORK_DIR/scripts/*.sh && \
	find $WORK_DIR/utils -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
	
# 执行初始化
RUN $WORK_DIR/scripts/entrypoint.sh init
# CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]

# ========================
# 阶段3: 主构建阶段
# ========================
FROM ${BASE_IMAGE} AS master

# 定义工作目录
ARG WORK_DIR

# 定义用户和组
ARG PUID=1000
ARG PGID=1000
ARG USERNAME=nginx
ARG GROUPNAME=nginx

# 定义端口号
ARG SSHD_PORT=22
ARG HTTP_PORT=80

# 定义版本号
ARG BUILD_VERSION

LABEL version="$BUILD_VERSION"
LABEL author="wanglei<lysgwl@163.com>"
LABEL description="Nginx For Alpine"

# 系统环境变量
ENV LANG=C.UTF-8 \
	TZ=Asia/Shanghai
	
# 应用目录变量
ENV WORK_DIR=$WORK_DIR \
	UTILS_DIR=$WORK_DIR/utils
	
# 导出用户和组
ENV PUID=$PUID \
	PGID=$PGID \
	USERNAME=$USERNAME \
	GROUPNAME=$GROUPNAME
	
# 导出端口号
ENV SSHD_PORT=$SSHD_PORT \
	HTTP_PORT=$HTTP_PORT
	
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

# 复制文件
COPY --from=utils-source /app/utils $WORK_DIR/utils
COPY --from=builder $WORK_DIR/install $WORK_DIR/install
COPY --from=builder /data $WORK_DIR/config/data
COPY --from=builder /config $WORK_DIR/config/etc

COPY etc/ $WORK_DIR/config
COPY --chown=$PUID:$PGID scripts/ $WORK_DIR/scripts

# 创建目录并设置权限
RUN chown -R $PUID:$PGID $WORK_DIR && \
	chmod +x $WORK_DIR/scripts/*.sh

# 持久化目录
VOLUME /config /data

# 暴露端口
EXPOSE ${HTTP_PORT}

SHELL ["/bin/bash", "-c"]

# 启动执行脚本
ENTRYPOINT ["/bin/bash", "/app/scripts/entrypoint.sh", "run"]