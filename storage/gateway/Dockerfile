
FROM alpine:latest

LABEL version="1.0"
LABEL author="wanglei<lysgwl@163.com>"
LABEL description="storage-gateway"

# 定义工作目录和用户参数
ARG WORK_DIR=/app
ARG PUID=1000
ARG PGID=1000

ENV LANG=C.UTF-8 \
	WORK_DIR=$WORK_DIR \
	PUID=$PUID \
	PGID=$PGID
	
# 配置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone
	
# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装核心依赖和挂载工具
RUN apk update && apk add --no-cache \
	bash coreutils gawk tzdata \
	bc cifs-utils nfs-utils samba-client jq curl \
	docker-cli fuse fuse3 rsync shadow
	
# 创建用户和组
RUN addgroup -g $PGID gateway && \
	adduser -D -u $PUID -G gateway gateway
	
# 清理缓存	
RUN rm -rf /var/cache/apk/*

# 工作目录
WORKDIR $WORK_DIR

# 持久化目录
VOLUME ["/config", "/data"]

# 复制文件
COPY etc/ $WORK_DIR/config
COPY --chown=$PUID:$PGID scripts/ $WORK_DIR/scripts

# 创建目录并设置权限
RUN chown -R $PUID:$PGID $WORK_DIR && \
	chmod +x $WORK_DIR/scripts/*.sh
	
# 启动执行脚本
ENTRYPOINT ["/app/scripts/entrypoint.sh"]