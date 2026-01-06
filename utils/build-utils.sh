#!/bin/bash
# /app/bin/docker/utils/build-utils.sh

set -e

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$UTILS_DIR/../" && pwd)"

# 默认镜像名称
DEFAULT_IMAGE_NAME="docker-utils"
IMAGE_NAME="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"

build_platform()
{
	local platform="$1"
	local version="${2:-latest}"
	local image_name="${3:-$IMAGE_NAME}"
	
	case "$platform" in
		"alpine")
			docker build --target alpine-utils -t ${image_name}:alpine-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
			;;
		"debian")
			docker build --target debian-utils -t ${image_name}:debian-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
			;;
		"ubuntu")
			docker build --target ubuntu-utils -t ${image_name}:ubuntu-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
			;;
		*)
			echo "平台构建参数发生错误, 请检查!"
			return
			;;
	esac
	
	docker tag $image_name:$platform-$version $image_name:$version
	echo "✓ 构建完成: ${image_name}:$version"
}

build_all_platforms()
{
	local version="${1:-latest}"
	local image_name="${2:-$IMAGE_NAME}"
	
	echo "[INFO] 构建Alpine版本..."
	docker build --target alpine-utils -t ${image_name}:alpine-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
	
	echo "[INFO] 构建Debian版本..."
	docker build --target debian-utils -t ${image_name}:debian-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
	
	echo "[INFO] 构建Ubuntu版本..."
	docker build --target ubuntu-utils -t ${image_name}:ubuntu-$version -f "$UTILS_DIR/Dockerfile" "$UTILS_DIR"
	
	# 创建通用标签
	docker tag $image_name:alpine-$version $image_name:$version
	
	echo "[SUCCESS] 所有平台构建完成"
}

case "${1:-}" in
	"alpine"|"ubuntu"|"debian")
		build_platform "$1" "${2:-latest}" "${3:-${DEFAULT_IMAGE_NAME}}"
		;;
	"all")
		build_all_platforms "${2:-latest}" "${3:-${DEFAULT_IMAGE_NAME}}"
		;;
esac