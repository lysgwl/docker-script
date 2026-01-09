#!/bin/bash
#/app/bin/docker/docker-common.sh
#

# ==================== 参数解析 ====================
# 参数解析
parse_args()
{
	local args=("$@")
	
	# 全局参数数组
	declare -gA PARAMS
	
	# 默认值
	PARAMS[action]=""
	PARAMS[mode]="auto"
	PARAMS[build_utils]="false"
	PARAMS[clean_build]="false"
	
	local i=0
	while [[ $i -lt ${#args[@]} ]]; do
		local arg="${args[i]}"

		case "$arg" in
			build|start|stop|restart|clean|status|logs)
				PARAMS[action]="$arg"
				;;
			--build-utils) PARAMS[build_utils]="true" ;;
			--clean-build) PARAMS[clean_build]="true" ;;
			--mode|--compose-file|--image-name|--container-name|--version|--network|--port|--volume|--env)
				local key="${args[i]#--}"
				key="${key//-/_}"
				
				PARAMS["$key"]="${args[i+1]}"
				((i++)) || true
				;;
			-*)
				echo "警告: 未知参数 ${args[i]}"
				;;
		esac
		
		((i++)) || true
	done
}

# 获取参数值
get_param()
{
	local key="$1"
	local default="${2:-}"
	
	echo "${PARAMS[$key]:-$default}"
}

# ==================== 检查函数 ====================

# 查找匹配的镜像列表
find_images()
{
	local pattern="$1"
	
	# 获取所有镜像
	local images_list=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>/dev/null)
	if [[ -z "$images_list" ]]; then
		echo "[WARNING] 没有找到任何镜像, 请检查!" >&2
		return 1
	fi
	
	# 查找匹配的镜像
	local matches=""

	if [[ "$pattern" == *:* ]]; then
		# 完整镜像名:标签模式 - 精确匹配
		matches=$(echo "$images_list" | grep -E "^[a-f0-9]+ ${pattern}\$" 2>/dev/null || true)
	elif [[ "$pattern" == */* ]]; then
		# 包含仓库路径的模式 - 匹配指定仓库
		matches=$(echo "$images_list" | grep -E "^^[a-f0-9]+ ${pattern}:" 2>/dev/null || true)
	else
		# 简单镜像名模式 - 匹配镜像名
		matches=$(echo "$images_list" | grep -E "^[a-f0-9]+ ([^/]+/)?${pattern}:" 2>/dev/null || true)
	fi
	
	# 输出结果
	if [[ -z "$matches" ]]; then
		echo "没有找到匹配的镜像" >&2
		return 1
	fi
	
	echo "找到匹配的镜像:" >&2
	echo "$matches"
	
	return 0
}

# 检查镜像是否存在
check_image()
{
	local image_name="$1"
	local image_tag="${2:-latest}"
	
	local full_image="$image_name:$image_tag"
	echo "检查镜像: $full_image"
	
	if ! docker image inspect "$full_image" >/dev/null 2>&1; then
		echo "✗ 镜像不存在: $full_image"
		return 1
	fi
	
	echo "✓ 镜像已存在: $full_image"
	return 0
}

# 检查容器是否存在
check_container()
{
	local container_name="$1"
	docker ps -a --filter "name=^/${container_name}\$" --format '{{.Names}}' \
	| grep -qxF "$container_name"
}

# 检查容器是否运行中
check_container_running()
{
	local container_name="$1"
	
	if ! check_container "$container_name"; then
		return 1
	fi
	
	local status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
	[[ "$status" == "running" ]]
}

# 获取容器ID
get_container_id()
{
	local container_name="$1"
	docker ps -a --filter "name=^/${container_name}$" --format "{{.ID}}" | head -1
}

# ==================== 构建函数 ====================
# 构建 utils 镜像
build_utils()
{
	local utils_platform="$1"
	local utils_tag="$2"
	local utils_image_name="$3"
	local utils_dir="$4"
	
	# 组合标签
	local utils_full_tag="$utils_platform-$utils_tag"
	
	# 检查是否需要构建
	if check_image "$utils_image_name" "$utils_full_tag"; then
		echo "utils 镜像已存在，跳过 utils 构建!"
		return 0
	fi
	
	echo "开始构建 utils 镜像: $utils_image_name:$utils_full_tag"
	
	if [[ ! -f "$utils_dir/build-utils.sh" ]]; then
		echo "Utils 构建脚本不存在: $utils_dir/build-utils.sh"
		return 1
	fi
	
	cd "$utils_dir"
	
	# 调用 build-utils.sh
	if ! ./build-utils.sh "$utils_platform" "$utils_tag" "$utils_image_name"; then
		echo "Utils 构建失败"
		return 1
	fi
	
	echo "✓ Utils 镜像构建完成: $utils_image_name:$utils_full_tag"
	return 0
}

# 构建项目镜像
build_project()
{
	local project_name="$1"
	local project_dir="$2"
	local image_name="$3"
	local base_image="$4"
	
	local build_version="$5"
	local utils_platform="$6"
	local utils_tag="$7"
	local utils_image_name="$8"
	
	if [[ ! -f "$project_dir/Dockerfile" ]]; then
		echo "[ERROR] Dockerfile 不存在: $project_dir/Dockerfile"
		return 1
	fi
	
	# 切换项目目录
	cd "$project_dir"
	
	# 组合 utils 版本
	local utils_full_version="$utils_platform-$utils_tag"
	
	# 构建参数
	local build_args="--build-arg BASE_IMAGE=$base_image"
	build_args+=" --build-arg BUILD_VERSION=$build_version"
	build_args+=" --build-arg UTILS_VERSION=$utils_full_version"
	build_args+=" --build-arg UTILS_IMAGE_NAME=$utils_image_name"
	
	# 镜像标签
	local full_image_name="$image_name:$build_version"
	
	# 构建命令
	local build_cmd="docker build $build_args -t $full_image_name -t $image_name:latest ."
	
	echo "执行构建命令: $build_cmd"
	
	# 执行构建
	if ! eval "$build_cmd"; then
		echo "✗ $project_name 镜像构建失败!"
		return 1
	fi
	
	echo "✓ $project_name 镜像构建成功: $image_name"
	
	# 显示镜像信息
	docker images "$image_name" --format "table {{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" | head -10
	return 0
}

# ==================== 启动函数 ====================
_start_with_run()
{
	local name="$1"
	local image="$2"
	
	if check_container "$name"; then
		echo "容器已存在: $name"
		return 1
	fi
	
	if ! check_image "$image"; then
		echo "[ERROR] 镜像不存在: $image"
		return 1
	fi
	
	# 清理旧容器
	docker rm -f "$name" 2>/dev/null || true
	
	# 构建命令
	local cmd="docker run -d --name $name --restart unless-stopped"
	
	local port="$(get_param port)"
	[[ -n "$port" ]] && cmd+=" -p $port"
	
	local volume="$(get_param volume)"
	[[ -n "$volume" ]] && cmd+=" -v $volume"
	
	local env="$(get_param env)"
	[[ -n "$env" ]] && cmd+=" -e $env"
	
	local network="$(get_param network)"
	[[ -n "$network" ]] && cmd+=" --network $network"
	
	cmd+=" $image"
	echo "执行: $cmd"
	
	if ! eval "$cmd"; then
		echo "✗ $name 容器启动失败"
		return 1
	fi
	
	echo "✓ $name 容器启动成功"
}

_start_with_compose()
{
	local name="$1"
	local dir="$2"
	
	if check_container "$name"; then
		echo "容器已存在: $name"
		return 1
	fi
	
	cd "$dir" || return 1
	local compose_file="$(get_param compose_file docker-compose.yml)"
	
	if [[ ! -f "$compose_file" ]]; then
		echo "[ERROR] compose文件不存在: $compose_file"
		return 1
	fi
	
	local cmd="docker compose -f $compose_file up -d --no-build"
	#[[ -n "$name" ]] && cmd+=" $name"
	
	echo "执行: $cmd"
	
	if ! eval "$cmd"; then
		echo "✗ $name compose 启动失败"
		return 1
	fi
	
	echo "✓ $name compose 启动成功"
}

# 启动服务
start_service()
{
	local service="$1"
	local image="$2"
	local mode="${3:-auto}"
	local dir="$4"
	
	# 自动模式选择
	if [[ "$mode" == "auto" ]]; then
		local compose_file="$(get_param compose_file docker-compose.yml)"
		local file_path="$([[ "$compose_file" == /* ]] && echo "$compose_file" || echo "$dir/$compose_file")"
		[[ -f "$file_path" ]] && mode="compose" || mode="run"
	fi
	
	case "$mode" in
		run)	 _start_with_run "$service" "$image" ;;
		compose) _start_with_compose "$service" "$dir" ;;
	esac
}

# ==================== 停止函数 ====================
# 停止容器
_stop_with_run()
{
	local container_name="$1"
	echo "停止容器: $container_name"
	
	if ! check_container "$container_name"; then
		echo "容器不存在: $container_name"
		return 1
	fi
	
	# 停止容器
	docker stop "$container_name" 2>/dev/null || true
	
	# 移除容器
	docker rm -f "$container_name" 2>/dev/null || true
	
	echo "✓ 容器已停止并移除"
	return 0
}

# 停止 compose 服务
_stop_with_compose()
{
	local name="$1"
	local dir="$2"
	
	if ! check_container "$container_name"; then
		echo "容器不存在: $container_name"
		return 1
	fi
	
	echo "停止 $name compose 服务"
	
	cd "$dir" || return 1
	local compose_file="$(get_param compose_file docker-compose.yml)"
	
	if [[ ! -f "$compose_file" ]]; then
		echo "[ERROR] $name compose文件不存在: $compose_file"
		return 1
	fi
	
	if ! docker compose -f "$compose_file" down; then
		echo "✗ $name compose 服务停止失败"
		return 1
	fi
	
	echo "✓ $name compose 服务已停止"
	return 0
}

# 停止服务
stop_service()
{
	local service="$1"
	local mode="${2:-auto}"
	local dir="$3"
	
	# 自动模式选择
	if [[ "$mode" == "auto" ]]; then
		local compose_file="$(get_param compose_file docker-compose.yml)"
		local file_path="$([[ "$compose_file" == /* ]] && echo "$compose_file" || echo "$dir/$compose_file")"
		[[ -f "$file_path" ]] && mode="compose" || mode="run"
	fi
	
	case "$mode" in
		run)	 _stop_with_run "$service" ;;
		compose) _stop_with_compose "service" "$dir" ;;
	esac
}

# ==================== 其他函数 ====================

# 查看容器状态
show_status()
{
	local container_name="$1"
	local mode="${2:-auto}"
	local dir="${3:-.}"
	
	if ! check_container "$container_name"; then
		echo "容器不存在: $container_name"
		return 1
	fi
	
	# 自动模式选择
	if [[ "$mode" == "auto" ]]; then
		local compose_file="$(get_param compose_file docker-compose.yml)"
		local file_path="$([[ "$compose_file" == /* ]] && echo "$compose_file" || echo "$dir/$compose_file")"
		[[ -f "$file_path" ]] && mode="compose" || mode="run"
	fi
	
	echo -e "\n容器状态:"
	case "$mode" in
		run)
			docker ps -a --filter "name=$container_name" \
				--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
			;;
		compose)
			cd "$dir" || return 1
			
			local compose_file="$(get_param compose_file docker-compose.yml)"
			if [[ ! -f "$compose_file" ]]; then
				echo "compose文件不存在: $compose_file"
				return 1
			fi
			
			docker compose -f "$compose_file" ps
			;;
	esac
}

# 查看容器日志
show_logs()
{
	local container_name="$1"
	local mode="${2:-auto}"
	local dir="${3:-.}"
	
	if ! check_container "$container_name"; then
		echo "容器不存在: $container_name"
		return 1
	fi
	
	# 自动模式选择
	if [[ "$mode" == "auto" ]]; then
		local compose_file="$(get_param compose_file docker-compose.yml)"
		local file_path="$([[ "$compose_file" == /* ]] && echo "$compose_file" || echo "$dir/$compose_file")"
		[[ -f "$file_path" ]] && mode="compose" || mode="run"
	fi
	
	echo -e "\n容器日志:"
	case "$mode" in
		run)
			docker logs --tail=50 "$container_name"
			;;
		compose)
			cd "$dir" || return 1
			
			local compose_file="$(get_param compose_file docker-compose.yml)"
			if [[ ! -f "$compose_file" ]]; then
				echo "compose 文件不存在: $compose_file"
				return 1
			fi
			
			docker compose -f "$compose_file" logs --tail=50
			;;
	esac
}

# 清理构建缓存
clean_build()
{
	echo "清理构建缓存..."
	
	# 清理 docker 构建缓存
	docker builder prune -f
	
	# 清理未使用的镜像
	docker image prune -f
	
	# 清理未使用的容器
	docker container prune -f
	
	echo "✓ 清理完成"
}

# 清理镜像
clean_image()
{
	local image_name="$1"
	echo "清理镜像: $image_name"
	
	local matches
	if ! matches=$(find_images "$image_name" 2>/dev/null); then
		echo "没有找到匹配的镜像: $image_name"
		return 0
	fi
	
	declare -A image_ids
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		
		IFS=" " read -r image_id image_tag <<< "$line"
		if [[ -n "$image_id" && -n "$image_tag" ]]; then
			if [[ -z "${image_ids[$image_id]}" ]]; then
				image_ids["$image_id"]="$image_tag"
			else
				image_ids["$image_id"]="${image_ids[$image_id]} $image_tag"
			fi
		fi
	done <<< "$matches"
	
	if [[ ${#image_ids[@]} -eq 0 ]]; then
		echo "没有找到匹配的镜像: $image_name"
		return 0
	fi
	
	#for image_id in "${!image_ids[@]}"; do
	#	local tags="${image_ids[$image_id]}"
	#	echo "  ID: ${image_id:0:12}  标签: $tags"
	#done
	
	for image_id in "${!image_ids[@]}"; do
		local tags="${image_ids[$image_id]}"
		
		local containers=$(docker ps -a --filter "ancestor=$image_id" --format "{{.Names}}" 2>/dev/null)
		if [[ -n "$containers" ]]; then
			echo "[WARNING] 跳过镜像 ${image_id:0:12}, 正在被容器引用：$containers"
			continue
		fi
		
		local tag_deleted=false
		for tag in $tags; do
			if docker rmi -f "$tag" 2>/dev/null; then
				echo "[INFO] 成功删除标签: $tag"
				tag_deleted=true
			fi
		done
		
		if [[ "$tag_deleted" == "false" ]]; then
			if ! docker rmi -f "$image_id" 2>/dev/null; then
				echo "[ERROR] 删除镜像失败: ${image_id:0:12}"
			else
				echo "[INFO] 成功删除镜像ID: ${image_id:0:12}"
			fi
		fi
	done
}

# 检查容器状态
get_container_status()
{
	local container_name="$1"
	
	if ! check_container "$container_name"; then
		echo "not_exist"
	else
		if ! check_container_running "$container_name"; then
			echo "stopped"
		else
			echo "running"
		fi
	fi
}

# 等待容器启动
wait_for_container()
{
	local container_name="$1"
	local max_attempts="${2:-30}"
	local attempt=1
	
	echo "等待容器 $container_name 启动..."
	
	while [[ $attempt -le $max_attempts ]]; do
		if check_container_running "$container_name"; then
			echo "✓ 容器已启动"
			return 0
		fi
		
		echo "等待中... ($attempt/$max_attempts)"
		
		sleep 2
		((attempt++)) || true
	done
	
	echo "✗ 容器启动超时"
	return 1
}