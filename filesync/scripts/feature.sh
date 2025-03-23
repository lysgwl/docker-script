#!/bin/bash

# 查找版本的压缩包
find_latest_archive()
{
	local search_dir=$1
	local pattern=$2
	
	local matched_files=()
	while IFS= read -r -d $'\0' file; do
		matched_files+=("${file}")
	done < <(find "${search_dir}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null)
	
	if [[ ${#matched_files[@]} -eq 0 ]]; then
		return 1
	fi
	
	# 按修改时间排序取最新
	local latest_file=$(ls -t "${matched_files[@]}" 2>/dev/null | head -n1)
	[[ -n "${latest_file}" ]] || {
		return 1
	}
	
	echo "${latest_file}"
}

# 解压并验证文件
extract_and_validate() 
{
	local archive_file=$1
	local extract_dir=$2
	local dir_pattern=$3
	local required_file=${4:-}
	
	[[ -f "${archive_file}" ]] || {
		echo "[ERROR] 安装文件不存在,请检查! [${archive_file}]" >&2
		return 1
	}
	
	local service_name=$(basename "${archive_file}")
	mkdir -p "${extract_dir}"
	
	if ! tar -zxvf "${archive_file}" -C "${extract_dir}" >/dev/null; then
		echo "[ERROR] ${service_name}安装失败,请检查!" >&2
		return 1
	fi
	
	local extracted_entry=$(find "${extract_dir}" -maxdepth 1 \( -type f -o -type d \) -name "${dir_pattern}" -print -quit)
	[[ -n "${extracted_entry}" ]] || {
		echo "[ERROR] 未找到匹配${service_name}文件,请检查!" >&2
		return 1
	}
	
	# 验证文件
	if [[ -n "${required_file}" ]]; then
		if [[ -d "${extracted_entry}" ]]; then
			local required_path="${extracted_entry%/}/${required_file}"
			[[ -f "${required_path}" ]] || {
				echo "[ERROR] ${required_path}文件不存在,请检查!" >&2
				return 1
			}
		else
			[[ "$(basename "$extracted_entry")" == "$required_file" ]] || {
				echo "[ERROR] ${service_name}文件不存在,请检查!" >&2
				return 1
			}
		fi
	fi
	
	echo "${extracted_entry}"
}

# 安装运行文件
install_binary()
{
	local src_file=$1
	local dest_path=$2
	local symlink_path=${3:-}
	
	# 校验源路径类型
	[[ -f "${src_file}" || -d "${src_file}" ]] || {
		echo "[ERROR] 源文件不存在,请检查!" >&2
		return 1
	}
	
	mkdir -p "${dest_path%/*}" || {
		echo "[ERROR] 无法创建目录,请检查!" >&2
		return 1
	}
	
	# 复制文件/目录
    cp -a "${src_file}" "${dest_path}" || {
        echo "[ERROR] 文件复制失败,请检查!" >&2
        return 1
    }
	
	# 设置可执行权限 (仅文件)
    [[ -f "${dest_path}" ]] && chmod +x "${dest_path}"
	
	# 创建符号链接
    [[ -n "${symlink_path}" ]] && ln -sf "${dest_path}" "${symlink_path}" 2>/dev/null || :
	
	return 0
}

# 下载文件
download_file()
{
	local url=$1
	local dest_path=$2
	
	if [ -z "${url}" ]; then
		echo "[ERROR]下载URL参数为空,请检查!" >&2
		return 1
	fi
	
	echo "[INFO] 下载开始:$(basename "$dest_path")" >&2
	
	#curl -L -o "${dest_path}" "${url}" >/dev/null 2>&1 || {
	#	echo "[ERROR] 下载失败,请检查!${url}" >&2
	#	return 1
	#}
	
	curl -L --fail \
		--silent \
		--show-error \
		--max-time 300 \
		--retry 3 \
		--retry-delay 5 \
		--output "${dest_path}" "${url}" || {
		echo "[ERROR] 下载失败,请检查!${url}" >&2
		return 1
	}

	return 0
}

# 获取github信息
get_github_info()
{
	local json_config=$1
	local __result_tag=$2
	local __result_url=$3
	
	# 解析配置参数
	local repo=$(jq -r '.repo' <<< "$json_config")
	local version=$(jq -r '.version // "latest"' <<< "$json_config")
	local pattern=$(jq -r '.pattern // ""' <<< "$json_config")
	local asset_matcher=$(jq -r '.asset_matcher // ""' <<< "$json_config")

	# 构造API地址
	local release_url
	if [ "${version}" = "latest" ]; then
		release_url="https://api.github.com/repos/${repo}/releases/latest"
	else
		release_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
	fi
	
	# 获取发布信息
	local release_info
	release_info=$(curl -fsSL "${release_url}") || {
		echo "[ERROR] GitHub API请求失败,请检查!${repo}" >&2
		return 1
	}
	
	# 提取版本标签
    local tag_name=$(jq -r '.tag_name' <<< "${release_info}")
    if [ -z "${tag_name}" ] || [ "${tag_name}" = "null" ]; then
        echo "[ERROR] 无效的版本标签,请检查!" >&2
        return 1
    fi
	
	# 匹配资产文件
	local download_url
	local assets=$(jq -r '.assets[] | @base64' <<< "$release_info")
	for asset in $assets; do
		_decode() { 
            echo "$asset" | base64 -d | jq -r "$1" 
        }
		
		local name=$(_decode '.name')
        local url=$(_decode '.browser_download_url')
		
		# 双重匹配逻辑
        if [ -n "${pattern}" ]; then
            if [[ "${name}" =~ ${pattern} ]]; then
				download_url="${url}"
                break
			fi
		elif [ -n "${asset_matcher}" ]; then
			if eval "${asset_matcher}"; then
				download_url="${url}"
				break
			fi
		fi
	done
	
	if [ -z "${download_url}" ]; then
        echo "[ERROR] 未找到匹配资源,请检查！" >&2
        return 1
    fi
	
	# 设置输出变量
	eval "${__result_tag}=\$(printf '%q' \"\${tag_name}\")"
	eval "${__result_url}=\$(printf '%q' \"\${download_url}\")"
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
	local processed_config=$(echo "$json_config" | 
		sed \
			-e "s/\${SYSTEM_ARCH}/$SYSTEM_ARCH/g" \
			-e "s/\${SYSTEM_TYPE}/$SYSTEM_TYPE/g" \
			-e "s/\${VERSION}/$VERSION/g")

	# 解析配置	
	local type=$(echo "$processed_config" | jq -r '.type')

	case ${type} in
		"static")
			local url=$(jq -r '.url' <<< "${processed_config}")
            local filename=$(jq -r '.filename // empty' <<< "${processed_config}")
            local dest_file="${downloads_path}/${filename:-$(basename "${url}")}"
			
			download_file "${url}" "${dest_file}" || return 2
			;;
		"github")
			local github_tag github_url
			if ! get_github_info "${processed_config}" github_tag github_url; then
				return 1
			fi
			
			# 原始文件名
			local filename=$(basename "${github_url}")
			
			# 检查原始文件名是否已包含版本号
			if [[ "${filename}" == *"${github_tag}"* ]]; then
				local new_filename="$filename"
			else
				# 拆分文件名和扩展名
				local base_name="${filename%.*}"
				local extension="${filename##*.}"
				
				# 插入版本号
				if [[ "$filename" =~ \.tar\.gz$ ]]; then
					local new_base="${base_name%.tar}"
					local new_filename="${new_base}-${github_tag}.tar.gz"
				else
					local new_filename="${base_name}-${github_tag}.${extension}"
				fi
			fi	

			local dest_file="${downloads_path}/${new_filename}"
			download_file "${github_url}" "${dest_file}" || return 2
			;;
		*)
			echo "[ERROR] 不支持的类型下载: ${type}" >&2
			return 1
			;;
	esac
	
	# 设置输出变量
	echo "${dest_file}"
	return 0
}