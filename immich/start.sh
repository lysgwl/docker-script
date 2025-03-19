#!/bin/bash

# 加载 .env 文件中的环境变量
source .env

# 配置路径
IMMICH_CONFIG_PATH="/app/usr/immich"

# 照片路径
SOURCE_PHOTOS_PATH="/app/files/我的图库"

# 模型路径
SOURCE_MODEL_PATH="/app/data/cache/immich"

# 定义容器名称
CONTAINER_NAMES=("immich_server" "immich_machine_learning" "immich_redis" "immich_postgres")

# 初始化immich环境
initImmichEnv()
{
	if [ ! -d "${IMMICH_CONFIG_PATH}" ]; then
		mkdir -p "${IMMICH_CONFIG_PATH}"
	fi
	
	# 检查模型路径存在
	if [ -d "${SOURCE_MODEL_PATH}" ]; then
		# 检查模型符号链接
		if [ -L "${MODEL_CACHE_PATH}" ]; then
			rm "${MODEL_CACHE_PATH}"
		fi
		
		# 创建模型符号链接
		ln -s "${SOURCE_MODEL_PATH}" "${MODEL_CACHE_PATH}"
	fi
	
	# 检查照片路径存在
	if [ -d "${SOURCE_PHOTOS_PATH}" ]; then
		# 检查模型符号链接
		if [ -L "${PHOTOS_PATH}" ]; then
			rm "${PHOTOS_PATH}"
		fi
		
		# 创建照片符号链接
		ln -s "${SOURCE_PHOTOS_PATH}" "${PHOTOS_PATH}"
	fi

	docker compose -p immich up -d
}

# 删除immich环境
uninitImmichEnv()
{
	# 停止并删除容器
	for CONTAINER_NAME in "${CONTAINER_NAMES[@]}"; do
	
		# 检查容器是否存在
		if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
			# 停止容器
			docker stop "${CONTAINER_NAME}" &> /dev/null
			
			# 卸载容器
			docker rm "${CONTAINER_NAME}" &> /dev/null
		fi
	done
	
	# 删除IMMICH_CONFIG_PATH路径下所有的文件
    if [ -d "${IMMICH_CONFIG_PATH}" ]; then
		rm -rf "${IMMICH_CONFIG_PATH:?}/"*
	fi
	
	# 停止并删除 docker-compose 管理的容器和资源
	# docker-compose down --remove-orphans --rmi local
	
	# 清理未使用的镜像、网络和卷
	# docker system prune -f
	
	if [ -d "${IMMICH_CONFIG_PATH}" ]; then
		rm -rf "${IMMICH_CONFIG_PATH}"
	fi
}

case "${1:-1}" in
	0)
		uninitImmichEnv
		;;
	1)
		initImmichEnv
		;;
esac