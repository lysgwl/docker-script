#!/bin/bash
# 下载工具模块

# 声明依赖
DEPENDENCIES=("archive_utils")

if [[ -n "${DOWNLOAD_UTILS_LOADED:-}" ]]; then
	return 0
fi
export DOWNLOAD_UTILS_LOADED=1

# 获取重定向URL
get_redirect_url()
{
	local url="$1"
	
	local timeout=30
	local retries=2
	
	# 特殊处理GitHub发布下载链接
	if [[ "$url" =~ ^https?://(www\.)?github.com/[^/]+/[^/]+/releases/download/ ]]; then
		echo "$url"
		return 0
	fi
	
	local US=$'\x1f'  # Unit Separator
	
	# 获取HTTP状态码和头信息
	local response
	response=$(curl -s -I -k \
		--connect-timeout "$timeout" \
		--max-time "$timeout" \
		--retry "$retries" \
		--retry-delay 3 \
		-w "HTTP_CODE:%{http_code}${US}REDIRECT_URL:%{redirect_url}${US}EFFECTIVE_URL:%{url_effective}\n" \
		-o /dev/null \
		"$url") || {
		echo "[ERROR] 访问 ${url} 失败,请检查!" >&2
		return 2
	}
		
	# 解析字段
	local status_code redirect_url effective_url
	IFS=$'\x1f' read -r status_code redirect_url effective_url <<< "$response"
	
	# 提取状态码、重定向URL、最终有效URL
	status_code=${status_code#HTTP_CODE:}
	redirect_url=${redirect_url#REDIRECT_URL:}
	effective_url=${effective_url#EFFECTIVE_URL:}

	# 清理null值
	redirect_url="${redirect_url//(null)/}"
	
	# 检查是否是重定向状态码
	if [[ "$status_code" =~ ^3[0-9]{2}$ ]] && [ -n "$redirect_url" ]; then
		echo "$redirect_url"
	elif [ -n "$effective_url" ] && [ "$effective_url" != "$url" ]; then
		echo "$effective_url"
	else
		echo "$url"
	fi

	return 0
}

# 生成最终文件名
generate_filename() 
{
	local default_name="$1"
	local redirect_url="$2"
	
	# 从重定向URL中提取文件名
	local redirect_name=$(basename "$redirect_url" | sed 's/[?#].*$//')
	local redirect_extension=$(get_file_extension "$redirect_name")
	
	if [ -n "$default_name" ]; then
		# 检查默认名称是否包含扩展名
		local default_extension=$(get_file_extension "$default_name")
		
		if [ -n "$default_extension" ]; then
			# 默认名称已经包含扩展名
			echo "$default_name"
		else
			# 默认名称没有扩展名
			if [ -n "$redirect_extension" ]; then
				echo "${default_name}${redirect_extension}"
			else
				# 重定向URL也没有扩展名，使用默认名称
				echo "$default_name"
			fi
		fi
	else
		# 没有提供默认名称，使用重定向URL的文件名
		if [ -n "$redirect_name" ] && [ "$redirect_name" != "/" ] && [ "$redirect_name" != "." ]; then
			echo "$redirect_name"
		else
			# 生成默认文件名
			local generated_name="downloaded_file_$(date +%Y%m%d_%H%M%S)"
			if [ -n "$redirect_extension" ]; then
				echo "${generated_name}${redirect_extension}"
			else
				echo "$generated_name"
			fi
		fi
	fi
}

# 下载文件
download_file()
{
	local url="$1"
	local download_dir="$2"
	local default_name="$3"
	
	if [ -z "$url" ]; then
		echo "[ERROR]下载URL参数为空,请检查!" >&2
		return 1
	fi
	
	if [ -z "$download_dir" ]; then
		echo "[ERROR] 下载目录参数为空,请检查!" >&2
		return 1
	fi
	
	# 获取重定向URL
	local redirect_url
	redirect_url=$(get_redirect_url "$url") || {
		echo "[WARNING] 获取重定向URL失败, 使用原始URL: $url" >&2
		redirect_url="$url"
	}
	
	# 生成文件名
	local filename=$(generate_filename "$default_name" "$redirect_url")
	
	# 构建输出文件路径
	local output_file="${download_dir}/${filename}"
	
	echo "[INFO] 正在下载: $filename" >&2
	echo "[INFO] 下载URL: $redirect_url" >&2
	echo "[INFO] 保存文件: $output_file" >&2
	
	local response
	response=$(curl -L --fail \
		--insecure \
		--silent \
		--show-error \
		--connect-timeout 30 \
		--max-time 300 \
		--retry 3 \
		--retry-delay 5 \
		--progress-bar \
		--output "$output_file" \
		--write-out "HTTP_STATUS:%{http_code}\nSIZE_DOWNLOAD:%{size_download}\n" \
		 "$redirect_url" 2>&1)
		 
	local exit_code=$?
	
	# 提取HTTP状态码和下载大小
	local http_status=$(echo "$response" | awk -F: '/HTTP_STATUS:/ {print $2}' | tr -d '[:space:]')
	local download_size=$(echo "$response" | awk -F: '/SIZE_DOWNLOAD:/ {print $2}' | tr -d '[:space:]')
	
	if [ $exit_code -ne 0 ]; then
		# 显示具体的错误信息
		local error_msg=$(echo "$response" | grep -v -E '^[[:space:]]*[0-9]*#$' | grep -v -E '^(HTTP_STATUS|SIZE_DOWNLOAD)')
		
		if [ -n "$error_msg" ]; then
			echo "[ERROR] 错误详情: $(echo "$error_msg" | head -1)" >&2
		fi
		
		echo "[DEBUG] HTTP状态: $http_status, 下载大小: $download_size 字节" >&2
		
		# 清理部分下载文件
		if [ -f "$output_file" ]; then
			rm -f "$output_file"
		fi
		
		return 2
	fi
	
	# 验证下载文件
	if [ ! -f "$output_file" ]; then
		echo "[ERROR] 文件未正确保存,请检查!" >&2
		return 3
	fi
	
	if [ ! -s "$output_file" ]; then
		echo "[ERROR] 下载的文件为空,请检查!" >&2
		rm -f "$output_file"
		return 4
	fi
	
	# 获取文件信息
	local file_size=$(du -h "$output_file" | cut -f1)
	echo "[INFO] 文件大小: $file_size" >&2

	echo "[SUCCESS] 下载完成: $output_file" >&2
	echo "$output_file"
	return 0
}

# 下载文件包
download_package()
{
	local json_config=$1
	local downloads_path=$2
	
	# 校验工具
	command -v jq >/dev/null || { echo "[ERROR] jq解析包未安装,请检查!" >&2; return 1; }

	# 预处理环境变量
	#local processed_config=$(echo "$json_config" | 
	#	sed \
	#		-e "s/\${SYSTEM_ARCH}/$SYSTEM_ARCH/g" \
	#		-e "s/\${SYSTEM_TYPE}/$SYSTEM_TYPE/g" \
	#		-e "s/\${VERSION}/$VERSION/g")
	
	local processed_config=$(jq -n \
		--argjson config "$json_config" \
		--arg SYSTEM_ARCH "$SYSTEM_ARCH" \
		--arg SYSTEM_TYPE "$SYSTEM_TYPE" \
		--arg VERSION "$VERSION" \
		'$config | 
		walk(if type == "string" then 
			gsub("\\$SYSTEM_ARCH"; $SYSTEM_ARCH) |
			gsub("\\$SYSTEM_TYPE"; $SYSTEM_TYPE) |
			gsub("\\$VERSION"; $VERSION)
		else . end)')

	# 解析配置	
	local type=$(echo "$processed_config" | jq -r '.type // empty')
	local name=$(echo "$processed_config" | jq -r '.name // empty')

	local default_name="${name:-}"
	local repo_branch repo_url
	
	case $type in
		"static")
			repo_url=$(jq -r '.url // empty' <<< "${processed_config}")
			;;
		"github")
			if ! get_github_info "$processed_config" repo_branch repo_url; then
				return 2
			fi
			
			if [ -n "$name" ]; then
				default_name="$name-$repo_branch"
			fi
			;;
		*)
			echo "[ERROR] 不支持的类型下载: $type" >&2
			return 1
			;;
	esac
	
	local target_file
	if ! target_file=$(download_file "$repo_url" "$downloads_path" "$default_name"); then
		return 3
	fi

	# 设置输出变量
	echo "$target_file"
	return 0
}