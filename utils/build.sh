#!/bin/bash
# /app/bin/docker/utils/build-utils.sh

set -e

# ==================== 项目配置 ====================

# 项目名称
PROJECT_NAME="utils"

# 默认镜像配置
DEFAULT_IMAGE="docker-${PROJECT_NAME}"
UTILS_IMAGE_NAME="${UTILS_IMAGE_NAME:-$DEFAULT_IMAGE}"
UTILS_PLATFORM="${UTILS_PLATFORM:-alpine}"
UTILS_TAG="${UTILS_TAG:-latest}"

# 文件路径配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$SCRIPT_DIR"

# ==================== 加载公共函数 ====================

if [[ ! -f "$DOCKER_ROOT/docker-common.sh" ]]; then
	echo "[ERROR] 公共构建脚本不存在: $DOCKER_ROOT/docker-common.sh"
	exit 1
else
	source "$DOCKER_ROOT/docker-common.sh"
fi

# ==================== 项目函数 ====================
build_platform()
{
	local platform="$1"
	local version="${2:-latest}"
	local image_name="${3:-$UTILS_IMAGE_NAME}"
	
	case "$platform" in
		"alpine")
			docker build --target alpine-utils -t ${image_name}:alpine-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
			;;
		"debian")
			docker build --target debian-utils -t ${image_name}:debian-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
			;;
		"ubuntu")
			docker build --target ubuntu-utils -t ${image_name}:ubuntu-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
			;;
		*)
			echo "[ERROR] 平台构建参数发生错误, 请检查!"
			return
			;;
	esac
	
	docker tag $image_name:$platform-$version $image_name:$version
	echo "✓ 构建完成: ${image_name}:$version (${platform})"
}

build_all_platforms()
{
	local version="${1:-latest}"
	local image_name="${2:-$UTILS_IMAGE_NAME}"
	
	echo "[INFO] 构建Alpine版本..."
	docker build --target alpine-utils -t ${image_name}:alpine-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
	
	echo "[INFO] 构建Debian版本..."
	docker build --target debian-utils -t ${image_name}:debian-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
	
	echo "[INFO] 构建Ubuntu版本..."
	docker build --target ubuntu-utils -t ${image_name}:ubuntu-$version -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
	
	# 创建通用标签
	docker tag $image_name:alpine-$version $image_name:$version
	
	echo "[SUCCESS] 所有平台构建完成"
}

# 构建项目
build_utils()
{
	echo "========== 构建项目: $PROJECT_NAME =========="
	
	local platform="${1:-$UTILS_PLATFORM}"
	local version="${2:-$UTILS_TAG}"
	local image_name="${3:-$UTILS_IMAGE_NAME}"
	local clean_build="${CLEAN_BUILD:-false}"
	
	echo "平台: $platform, 版本: $version, 镜像名: $image_name"
	if ! [[ "$platform" =~ ^(alpine|ubuntu|debian|all)$ ]]; then
		echo "❌ [ERROR] 不支持的平台: $platform"
		exit 1
	fi
	
	# 检查镜像是否已存在
	echo "[INFO] 检查镜像: $image_name:$version"
	if ! check_image "$image_name" "$version"; then	
		echo "[INFO] 镜像不存在，开始构建..."
	else
		if [[ "$clean_build" == "false" ]]; then
			echo "✅ 镜像已存在, 跳过构建: $image_name:$version"
			return 0
		fi
		
		echo "[INFO] 清理已存在的镜像..."
		docker rmi -f ${image_name}:alpine-$version 2>/dev/null || true
		docker rmi -f ${image_name}:debian-$version 2>/dev/null || true
		docker rmi -f ${image_name}:ubuntu-$version 2>/dev/null || true
		docker rmi -f ${image_name}:$version 2>/dev/null || true
		
		echo "[INFO] 镜像已清理，重新构建..."
	fi
	
	case "$platform" in
		"alpine"|"debian"|"ubuntu")
			build_platform "$platform" "$version" "$image_name" 
			;;
		"all")
			build_all_platforms "$version" "$image_name" 
			;;
	esac
	
	echo "✅ 构建完成"
}

# 清理项目
clean_utils()
{
	echo "========== 清理项目: $PROJECT_NAME =========="
	
	# 清理镜像
	local image_name="$(get_param image_name $DEFAULT_IMAGE)"
	clean_image "$image_name"
	
	# 清理构建缓存
	if [[ "$(get_param clean_build)" == "true" ]]; then
		clean_build
	fi
	
	echo "✓ $PROJECT_NAME 清理完成"
}

show_usage()
{
	echo "========================================"
	echo "🔧 Utils 工具镜像构建脚本"
	echo "========================================"
	echo "用法: $0 <平台> [版本] [镜像名]"
	echo ""
	echo "平台:"
	echo "  alpine      Alpine版本"
	echo "  debian      Debian版本"
	echo "  ubuntu      Ubuntu版本"
	echo "  all         所有平台 (默认: alpine)"
	echo ""
	echo "  UTILS_PLATFORM    构建平台 (默认: alpine)"
	echo "  BUILD_VERSION     镜像版本 (默认: latest)"
	echo "  UTILS_IMAGE_NAME  镜像名称 (默认: docker-utils)"
	echo "  CLEAN_BUILD       清理旧镜像 (true/false, 默认: false)"
	echo ""
	echo "示例:"
	echo "  $0 alpine                    # 构建Alpine版本"
	echo "  $0 alpine 1.0.0              # 构建指定版本"
	echo "  $0 alpine 1.0.0 my-utils     # 构建自定义镜像名"
	echo "  $0 build all                 # 构建所有平台"
	echo "  CLEAN_BUILD=true $0 alpine   # 清理后构建"
	echo "========================================"
}

# 主函数
main()
{
	if [[ "$1" =~ ^(alpine|ubuntu|debian|all)$ ]]; then
		build_utils "$1" "${2:-latest}" "${3:-$UTILS_IMAGE_NAME}"
		return 0
	fi
	
	# 解析参数
	parse_args "$@"
	local action="$(get_param action)"
	if [[ "$action" == "build" ]]; then
		local platform="${2:-${UTILS_PLATFORM:-all}}"
		if ! [[ "$platform" =~ ^(alpine|ubuntu|debian|all)$ ]]; then
			echo "❌ [ERROR] 无效的平台参数: $platform"
			exit 1
		fi
		
		local version="${3:-${BUILD_VERSION:-latest}}"
		local image_name="${4:-$UTILS_IMAGE_NAME}"
		
		build_utils "$platform" "$version" "$image_name"
	elif [[ "$action" == "clean" ]]; then
		clean_utils
	else
		echo "❌ [ERROR] 未指定有效的构建动作"
		show_usage
		exit 1
	fi
}

# 运行主函数
main "$@" || true