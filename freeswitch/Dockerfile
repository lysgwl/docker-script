FROM debian:bookworm AS builder

LABEL stage=builder

#ENV HTTP_PROXY=http://192.168.2.11:10809
#ENV HTTPS_PROXY=http://192.168.2.11:10809

# 设置环境变量
ENV LANG=C.UTF-8 \
	LC_ALL=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive

# 设置镜像源
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources	

# 安装软件包
RUN apt-get update && \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		git \
		jq \
		wget \
		tzdata && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*	

# 设置时区	
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone && \
	dpkg-reconfigure -f noninteractive tzdata
	
# 工作目录
WORKDIR /app

# 复制文件
COPY scripts/ /app/scripts
COPY usr/ /app/downloads

# 设置运行权限
RUN chmod +x /app/scripts/*.sh

# 执行初始化
RUN /app/scripts/entrypoint.sh init

# CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]

FROM debian:bookworm

# 定义用户和组
ARG APP_USER=freeswitch
ARG APP_GROUP=freeswitch
ARG APP_UID=1000
ARG APP_GID=1000

# 定义端口号
ARG SSHD_PORT=22	

# 导出用户和组
ENV APP_USER=$APP_USER \
	APP_GROUP=$APP_GROUP \
	APP_UID=$APP_UID \
	APP_GID=$APP_GID \
	LANG=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive
	
# 导出端口号
ENV SSHD_PORT=$SSHD_PORT
	
# 配置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone

# 创建用户和组
RUN groupadd -g $APP_GID $APP_GROUP && \
	useradd -m -s /bin/bash -g $APP_GROUP -u $APP_UID $APP_USER		

# 设置镜像源
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources

# 安装核心依赖
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates gosu locales tzdata

# 安装多媒体运行库
RUN apt-get install -y --no-install-recommends libavformat59 libcurl4 libedit2 libexpat1 libflac12 libjpeg62-turbo liblua5.1-0 libmp3lame0 libmpg123-0 libogg0 libopus0 libpcre3 libpq5 libshout3 libsndfile1 libspeex1 libspeexdsp1 libsqlite3-0 libssl3 libswscale6 libtiff6 libvorbis0a unixodbc zlib1g

# 安装运维工具
RUN apt-get install -y --no-install-recommends \
		curl \
		git \
		jq \
		wget \
		openssh-client \
		openssh-server && \
	apt-get clean && rm -rf /var/lib/apt/lists/*
	
# 工作目录
WORKDIR /app

# 复制文件
COPY --from=builder /data /data
COPY --from=builder /config /config
COPY --from=builder /usr/local /usr/local
COPY --chown=$APP_USER:$APP_GROUP scripts/ /app/scripts

# 设置权限
RUN chown -R $APP_USER:$APP_GROUP /app /config /data && \
	chmod +x /app/scripts/*.sh

# 持久化目录
VOLUME /config /data
	
# 暴露端口
EXPOSE ${SSHD_PORT}	
	
# 启动执行脚本
ENTRYPOINT ["/app/scripts/entrypoint.sh", "run"]