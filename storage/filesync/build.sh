#!/bin/bash
# /app/bin/docker/storage/filesync/build.sh

set -e

# FileSync 镜像配置
PROJECT_NAME="filesync"
IMAGE_NAME="${IMAGE_NAME:-filesync-image}"
BASE_IMAGE="${BASE_IMAGE:-alpine:latest}"

# 文件路径配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
UTILS_DIR="$DOCKER_ROOT/utils"
PROJECT_DIR="$SCRIPT_DIR"

# Utils 配置
UTILS_IMAGE_NAME="${UTILS_IMAGE_NAME:-docker-utils}"
UTILS_PLATFORM="${UTILS_PLATFORM:-alpine}"
UTILS_TAG="${UTILS_TAG:-latest}"

# 构建版本
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d_%H%M%S)}"

# 构建控制
BUILD_UTILS="${BUILD_UTILS:-false}"
CLEAN_BUILD="${CLEAN_BUILD:-false}"

# 加载公共构建函数
if [[ ! -f "$DOCKER_ROOT/docker-common.sh" ]]; then
	echo "[ERROR] 公共构建脚本不存在: $DOCKER_ROOT/docker-common.sh"
	exit 1
else
	source "$DOCKER_ROOT/docker-common.sh"
fi

# 主函数
main()
{
	# 清理构建缓存
	if [[ "$CLEAN_BUILD" == "true" ]]; then
		clean_build
	fi 
	
	# 构建utils镜像
	if [[ "$BUILD_UTILS" == "true" ]]; then
		if ! build_utils "$UTILS_PLATFORM" "$UTILS_TAG" "$UTILS_IMAGE_NAME" "$UTILS_DIR"; then
			echo "Utils 镜像构建失败, 请检查!"
			exit 1
		fi
	fi
	
	# 构建项目镜像
	if ! build_project "$PROJECT_NAME" "PROJECT_DIR" "$IMAGE_NAME" \
					"$BASE_IMAGE" "$BUILD_VERSION" "$UTILS_PLATFORM" \
					"$UTILS_TAG" "$UTILS_IMAGE_NAME"; then
		echo "$PROJECT_NAME 镜像构建失败, 请检查!"
		exit 1
	fi
	
	echo "✓ $PROJECT_NAME 镜像构建完成!"
}

# 运行主函数
main "$@"