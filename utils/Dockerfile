ARG BUILD_VERSION=latest
ARG BUILD_DATE
ARG WORK_DIR=/app

# ========================
# 阶段1：创建scratch脚本层
# ========================
FROM scratch AS utils-scripts

# 复制utils源码
COPY lib/ /app/utils/lib/
COPY feature.sh /app/utils/

# ========================
# 阶段2：Alpine运行版本
# ========================
FROM alpine:latest AS utils-alpine

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装软件包
RUN apk update && apk add --no-cache bash \
		coreutils \
		curl \
		jq \
		rsync && \
		rm -rf /var/cache/apk/*
		
ARG BUILD_VERSION
ARG BUILD_DATE
ARG WORK_DIR
		
# 工作目录
WORKDIR $WORK_DIR

# 复制脚本
COPY --from=utils-scripts /app $WORK_DIR

# 设置运行权限
RUN find ${WORK_DIR}/utils -name "*.sh" -type f -exec chmod +x {} \; && \
	chmod -R +x ${WORK_DIR}/utils/lib/
	
# 设置环境变量
ENV UTILS_DIR=$WORK_DIR/utils \
	LIB_DIR=$WORK_DIR/utils/lib \
	PLATFORM=alpine \
	BUILD_VERSION=$BUILD_VERSION \
	BUILD_DATE=$BUILD_DATE \
	PATH="${WORK_DIR}/utils:${WORK_DIR}/utils/lib:${PATH}"
	
# 设置默认shell
SHELL ["/bin/bash", "-c"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
	CMD bash -c '[[ -x "${UTILS_DIR}/feature.sh" ]] || exit 1'

# 默认指令
ENTRYPOINT ["/bin/bash"]

# ========================
# 阶段3：Debian运行版本
# ========================
