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
WORKDIR /app

# 复制文件
COPY scripts/ /app/scripts
COPY usr/ /app/downloads

# 设置运行权限
RUN chmod +x /app/scripts/*.sh

# 执行初始化
RUN /app/scripts/entrypoint.sh init

# 安装perl模块
RUN cpanm --local-lib=/usr/local/perl XML::LibXML XML::LibXML::PrettyPrint && \
	rm -rf /root/.cpanm

# CMD ["/bin/sh", "-c", "while true; do echo 'Running...'; sleep 60; done"]

FROM debian:bookworm

# 定义用户和组
ARG PUID=1000
ARG PGID=1000
ARG USERNAME=freeswitch
ARG GROUPNAME=freeswitch

# 导出用户和组
ENV PUID=$PUID \
	PGID=$PGID \
	USERNAME=$USERNAME \
	GROUPNAME=$GROUPNAME \
	LANG=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive
	
# 配置时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
	echo 'Asia/Shanghai' > /etc/timezone

# 创建用户和组
RUN groupadd -g $PGID $GROUPNAME && \
	useradd -m -s /bin/bash -g $GROUPNAME -u $PUID $USERNAME

# 设置镜像源
RUN sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources

# 安装核心依赖
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates gosu locales xmlstarlet tzdata

# 安装多媒体运行库
RUN apt-get install -y --no-install-recommends libavformat59 libcurl4 libedit2 libexpat1 libflac12 libjpeg62-turbo liblua5.1-0 libmp3lame0 libmpg123-0 libogg0 libopus0 libpcre3 libpq5 libshout3 libsndfile1 libspeex1 libspeexdsp1 libsqlite3-0 libssl3 libswscale6 libtiff6 libvorbis0a libxml2 unixodbc zlib1g

# 安装运维工具
RUN apt-get install -y --no-install-recommends \
		curl \
		git \
		jq \
		wget \
		rsync \
		perl \
		openssh-client \
		openssh-server && \
	apt-get clean && rm -rf /var/lib/apt/lists/*
	
# 工作目录
WORKDIR /app

# 持久化目录
VOLUME /config /data

# 复制文件
COPY --from=builder /usr/local /usr/local
COPY --from=builder /data /app/config/data
COPY --from=builder /config /app/config/etc
COPY --chown=$USERNAME:$GROUPNAME scripts/ /app/scripts

# 设置权限
RUN chown -R $USERNAME:$GROUPNAME /app && \
	chmod +x /app/scripts/*.sh
	
# 设置perl环境变量	
ENV PERL5LIB=/usr/local/perl/lib/perl5	
	
# 暴露端口
EXPOSE 22
EXPOSE 8021/tcp	
EXPOSE 5060/tcp 5060/udp 5080/tcp 5080/udp
EXPOSE 5061/tcp 5061/udp 5081/tcp 5081/udp
EXPOSE 5066/tcp
EXPOSE 7443/tcp
EXPOSE 8081/tcp 8082/tcp
EXPOSE 16384-32768/udp
EXPOSE 64535-65535/udp

# 启动执行脚本
ENTRYPOINT ["/app/scripts/entrypoint.sh", "run"]