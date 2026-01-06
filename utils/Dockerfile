ARG BUILD_VERSION=latest
ARG BUILD_DATE
ARG WORK_DIR=/app

# ========================
# 阶段1：创建scratch脚本层
# ========================
FROM scratch AS utils-scripts

# 设置环境变量
ARG WORK_DIR
ENV UTILS_DIR=${WORK_DIR}/utils
ENV LIB_DIR=${WORK_DIR}/utils/lib

# 复制utils源码
COPY lib/ ${LIB_DIR}/
COPY feature.sh ${UTILS_DIR}/

# ========================
# 阶段2：Alpine运行版本
# ========================
FROM alpine:latest AS alpine-utils

# 构建参数
ARG BUILD_VERSION
ARG BUILD_DATE
ARG WORK_DIR

# 设置环境变量
ENV UTILS_DIR=${WORK_DIR}/utils
ENV LIB_DIR=${WORK_DIR}/utils/lib

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

# 安装软件包
RUN apk update && apk add --no-cache bash coreutils && \
		rm -rf /var/cache/apk/*
	
# 工作目录
WORKDIR ${WORK_DIR}

# 复制脚本
COPY --from=utils-scripts ${UTILS_DIR} ${UTILS_DIR}

# 设置权限
RUN find ${UTILS_DIR} -name "*.sh" -type f -exec chmod +x {} \; && \
	chmod -R +x ${LIB_DIR}
	
# 设置环境变量
ENV PLATFORM=alpine \
	BUILD_VERSION=${BUILD_DATE} \
	BUILD_DATE=${BUILD_DATE} \
	PATH="${UTILS_DIR}:${LIB_DIR}:${PATH}"
	
# 设置默认shell
SHELL ["/bin/bash", "-c"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
	CMD bash -c '[[ -x "${UTILS_DIR}/feature.sh" ]] || exit 1'

# 默认指令
ENTRYPOINT ["/bin/bash"]

# ========================
# 阶段3：Debian 运行版本
# ========================
FROM debian:bookworm-slim AS debian-utils

# 构建参数
ARG BUILD_VERSION
ARG BUILD_DATE
ARG WORK_DIR

# 设置环境变量
ENV UTILS_DIR=${WORK_DIR}/utils
ENV LIB_DIR=${WORK_DIR}/utils/lib

# 设置环境变量以避免交互式安装提示
ENV DEBIAN_FRONTEND=noninteractive

# 设置镜像源
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources

# 安装软件包
RUN apt-get update && \
	apt-get install -y --no-install-recommends bash && \
	rm -rf /var/lib/apt/lists/*
	
# 工作目录
WORKDIR ${WORK_DIR}

# 复制脚本
COPY --from=utils-scripts ${UTILS_DIR} ${UTILS_DIR}

# 设置权限
RUN find ${UTILS_DIR} -name "*.sh" -type f -exec chmod +x {} \; && \
	chmod -R +x ${LIB_DIR}
	
# 设置环境变量
ENV PLATFORM=Debian \
	BUILD_VERSION=${BUILD_VERSION} \
	BUILD_DATE=${BUILD_DATE} \
	PATH="${UTILS_DIR}:${LIB_DIR}:${PATH}"
	
# 设置默认shell
SHELL ["/bin/bash", "-c"]

# 默认指令
ENTRYPOINT ["/bin/bash"]

# ========================
# 阶段4：Ubuntu运行版本
# ========================
FROM ubuntu:22.04 AS ubuntu-utils

# 构建参数
ARG BUILD_VERSION
ARG BUILD_DATE
ARG WORK_DIR

# 设置环境变量
ENV UTILS_DIR=${WORK_DIR}/utils
ENV LIB_DIR=${WORK_DIR}/utils/lib

# 设置环境变量以避免交互式安装提示
ENV DEBIAN_FRONTEND=noninteractive

# 设置镜像源
RUN sed -i 's/archive.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list

# 安装软件包
RUN apt-get update && \
	apt-get install -y --no-install-recommends bash && \
	rm -rf /var/lib/apt/lists/*
	
# 工作目录
WORKDIR ${WORK_DIR}

# 复制脚本
COPY --from=utils-scripts ${UTILS_DIR} ${UTILS_DIR}

# 设置权限
RUN find ${UTILS_DIR} -name "*.sh" -type f -exec chmod +x {} \; && \
	chmod -R +x ${LIB_DIR}
	
# 设置环境变量
ENV PLATFORM=ubuntu \
	BUILD_VERSION=${BUILD_VERSION} \
	BUILD_DATE=${BUILD_DATE} \
	PATH="${UTILS_DIR}:${LIB_DIR}:${PATH}"
	
# 设置默认shell
SHELL ["/bin/bash", "-c"]

# 默认指令
ENTRYPOINT ["/bin/bash"]

# ========================
# 阶段5：默认目标（Alpine）
# ========================
FROM alpine-utils AS default