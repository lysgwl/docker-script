#!/bin/bash
#/app/bin/docker/docker-common.sh
#

set -e

# 检查 utils 镜像是否存在
check_utils_image()
{
	local utils_tag="$1"
	local utils_image_name="$2"
	
	echo "检查 utils 镜像: $utils_image_name:$utils_tag"
	
	if ! docker image inspect "$utils_image_name:$utils_tag" >/dev/null 2>&1; then
		echo "✗ Utils 镜像不存在: $utils_image_name:$utils_tag"
		return 1
	fi
	
	echo "✓ Utils 镜像已存在: $utils_image_name:$utils_tag"
	return 0
}

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
	if check_utils_image "$utils_full_tag" "$utils_image_name"; then
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
	
	echo "========== 构建 $project_name =========="
	
	# 切换项目目录
	cd "$project_dir"
	
	# 组合 utils 版本
	local utils_full_version="$utils_platform-$utils_tag"
	
	# 构建参数
	local build_args="--build-arg BUILD_VERSION=$build_version"
	build_args+=" --build-arg BASE_IMAGE=$base_image"
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
