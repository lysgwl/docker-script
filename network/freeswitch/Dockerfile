# ========================
# 全局参数
# ========================
ARG WORK_DIR=/app
ARG BASE_IMAGE=debian:bookworm-slim
ARG BUILD_VERSION=1.0
ARG UTILS_IMAGE_NAME=docker-utils
ARG UTILS_VERSION=latest

# Perl 镜像源
ARG CPAN_MIRROR="http://mirrors.ustc.edu.cn/CPAN/"

# ========================
# 阶段1: 定义utils镜像源
# ========================
FROM ${UTILS_IMAGE_NAME}:${UTILS_VERSION} AS utils-source

# ========================
# 阶段2: 编译构建阶段
# ========================
FROM ${BASE_IMAGE} AS builder
LABEL stage=builder

ARG WORK_DIR
ARG CPAN_MIRROR

# 环境变量
ENV WORK_DIR=$WORK_DIR \
	UTILS_DIR=$WORK_DIR/utils
	
ENV LANG=C.UTF-8 \
	LC_ALL=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive \
	PERL_MM_USE_DEFAULT=1

# ENV HTTP_PROXY=http://192.168.2.11:10808
# ENV HTTPS_PROXY=http://192.168.2.11:10808

# 设置镜像源
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources

# 设置PERL源
RUN mkdir -p /usr/share/perl5/CPAN/Config/ && \
	{ \
		echo "mirror $CPAN_MIRROR"; \
		echo "urllist $CPAN_MIRROR"; \
	} > /usr/share/perl5/CPAN/Config/Mirrors.pm

# 安装软件包
RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		cpanminus \
		curl \
		git \
		jq \
		rsync \
		wget \
		tzdata && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# 设置时区	
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone && \
	dpkg-reconfigure -f noninteractive tzdata
	
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

# 安装Perl模块
RUN cpanm --local-lib=/usr/local/perl \
		  --mirror $CPAN_MIRROR \
		  --mirror-only \
		  XML::LibXML \
	      XML::LibXML::PrettyPrint && \
	rm -rf /root/.cpanm /root/.cpan
	
CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]