#!/bin/bash
#/app/bin/docker/network/freeswitch/build.sh
#

set -e

# ==================== 项目配置 ====================
PROJECT_NAME="freeswitch"

# 默认镜像配置
DEFAULT_IMAGE="${PROJECT_NAME}-image"
BASE_IMAGE="${BASE_IMAGE:-debian:bookworm-slim}"

# 文件路径配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PROJECT_DIR="$SCRIPT_DIR"

# Utils 配置
UTILS_IMAGE_NAME="${UTILS_IMAGE_NAME:-docker-utils}"
UTILS_PLATFORM="${UTILS_PLATFORM:-alpine}"
UTILS_TAG="${UTILS_TAG:-latest}"
UTILS_DIR="$DOCKER_ROOT/utils"

# ==================== 加载公共函数 ====================

if [[ ! -f "$DOCKER_ROOT/docker-common.sh" ]]; then
	echo "[ERROR] 公共构建脚本不存在: $DOCKER_ROOT/docker-common.sh"
	exit 1
else
	source "$DOCKER_ROOT/docker-common.sh"
fi

# ==================== 项目函数 ====================

# 构建项目
build_freeswitch()
{
	echo "========== 构建项目: $PROJECT_NAME =========="
	
	# 清理缓存
	if [[ "$(get_param clean_build)" == "true" ]]; then
		clean_build
	fi 
	
	# 构建utils镜像
	if [[ "$(get_param build_utils)" == "true" ]]; then
		if ! build_utils "$UTILS_PLATFORM" "$UTILS_TAG" "$UTILS_IMAGE_NAME" "$UTILS_DIR"; then
			echo "Utils 镜像构建失败, 请检查!"
			exit 1
		fi
	fi
	
	# 建项目镜像
	local image_name="$(get_param image_name $DEFAULT_IMAGE)"
	local version="$(get_param version $(date +%Y%m%d_%H%M%S))"
	
	echo "构建项目镜像: $image_name:$version"
	if check_image "$image_name" "latest"; then
		echo "✅ 镜像已存在, 跳过构建: $image_name:$version"
		exit 1
	fi
	
	# 构建项目镜像
	if ! build_project "$PROJECT_NAME" "$PROJECT_DIR" "$image_name" \
					"$BASE_IMAGE" "$version" "$UTILS_PLATFORM" \
					"$UTILS_TAG" "$UTILS_IMAGE_NAME"; then
		echo "$PROJECT_NAME 镜像构建失败, 请检查!"
		exit 1
	fi
	
	echo "✓ $PROJECT_NAME 镜像构建完成!"
}

# 启动项目
start_freeswitch()
{
	echo "========== 启动项目: $PROJECT_NAME =========="

	local mode="$(get_param mode auto)"
	local image_name="$(get_param image_name $DEFAULT_IMAGE)"
	local container_name="$(get_param container_name $PROJECT_NAME)"
	
	if ! start_service "$container_name" "$image_name" "$mode" "$PROJECT_DIR"; then
		exit 1
	fi
	
	# 等待容器启动
	wait_for_container "$container_name" 10
}

# 停止项目
stop_freeswitch()
{
	echo "========== 停止项目: $PROJECT_NAME =========="
	
	local mode="$(get_param mode auto)"
	local container_name="$(get_param container_name $PROJECT_NAME)"
	
	stop_service "$container_name" "$mode"  "$PROJECT_DIR"
}

# 重启项目
restart_freeswitch()
{
	echo "========== 重启项目: $PROJECT_NAME =========="
	
	# 停止容器
	stop_freeswitch
	
	sleep 2
	
	# 启动容器
	start_freeswitch
}

# 清理项目
clean_freeswitch()
{
	echo "========== 清理项目: $PROJECT_NAME =========="
	
	# 停止容器
	stop_freeswitch || true
	
	# 清理镜像
	local image_name="$(get_param image_name $DEFAULT_IMAGE)"
	clean_image "$image_name"
	
	# 清理构建缓存
	if [[ "$(get_param clean_build)" == "true" ]]; then
		clean_build
	fi
	
	echo "✓ $PROJECT_NAME 清理完成"
}

# 状态检查
status_freeswitch()
{
	echo "========== 项目状态: $PROJECT_NAME =========="
	
	local mode="$(get_param mode auto)"
	local container_name="$(get_param container_name $PROJECT_NAME)"
	
	show_status "$container_name" "$mode" "$PROJECT_DIR"
}

# 查看日志
logs_freeswitch()
{
	echo "========== 项目日志: $PROJECT_NAME =========="
	
	local mode="$(get_param mode auto)"
	local container_name="$(get_param container_name $PROJECT_NAME)"
	
	show_logs "$container_name" "$mode" "$PROJECT_DIR"
}

show_usage() 
{
	echo "========================================"
	echo "freeswitch 管理脚本"
	echo "========================================"
	echo "用法: $0 <动作> [选项]"
	echo ""
	echo "可用动作:"
	echo "  build    构建 freeswitch 镜像"
	echo "  start    启动 freeswitch 服务"
	echo "  stop     停止 freeswitch 服务"
	echo "  restart  重启 freeswitch 服务"
	echo "  clean    清理 freeswitch 资源"
	echo "  status   查看 freeswitch 状态"
	echo "  logs     查看 freeswitch 日志"
	echo ""
	echo "示例:"
	echo "  $0 build"
	echo "  $0 start"
	echo "  $0 logs"
	echo "========================================"
}

# 主函数
main()
{
	# 解析参数
	parse_args "$@"

	local action="$(get_param action)"
	case "$action" in
		build)	build_freeswitch ;;
		start)	start_freeswitch ;;
		stop)	stop_freeswitch ;;
		restart) restart_freeswitch ;;
		clean)	clean_freeswitch ;;
		status)	status_freeswitch ;;
		logs)	logs_freeswitch ;;
		*)		show_usage ;;
	esac
}

# 运行主函数
main "$@"