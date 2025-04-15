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
	
	local filename=$(basename "$url")
	local save_path=$(realpath "$dest_path" 2>/dev/null || echo "$dest_path")
	
	echo "[INFO] 正在下载:$(basename "$dest_path")" >&2
	echo "[INFO] 下载URL: $url" >&2
	
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
	
	# 验证下载文件
    if [ ! -f "$dest_path" ]; then
        echo "[ERROR] 文件未正确保存,请检查!" >&2
        return 1
    fi

	return 0
}

# 获取github信息
get_github_info()
{
	local json_config=$1
	local -n __result_tag=$2	# nameref 直接引用外部变量
	local -n __result_url=$3
	
	echo "[INFO] 获取软件包的Github信息..." >&2
	
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
		echo "[ERROR] GitHub API请求失败,请检查! ${repo}" >&2
		return 1
	}
	
	# 提取版本标签
    local tag_name=$(jq -r '.tag_name' <<< "${release_info}")
    if [ -z "${tag_name}" ] || [ "${tag_name}" = "null" ]; then
        echo "[ERROR] 无效的版本标签,请检查!" >&2
        return 1
    fi
	
	# 下载URL
	local download_url
	
	# 匹配资产文件
	if [[ -n "${pattern}" || -n "${asset_matcher}" ]]; then
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
	else
		download_url="https://github.com/${repo}/archive/refs/tags/${tag_name}.tar.gz"
	fi
	
	# 设置输出变量
	#eval "${__result_tag}=\$(printf '%q' \"\${tag_name}\")"
	#eval "${__result_url}=\$(printf '%q' \"\${download_url}\")"
	
	__result_tag="$tag_name"
    __result_url="$download_url"
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
            gsub("\\${SYSTEM_ARCH}"; $SYSTEM_ARCH) |
            gsub("\\${SYSTEM_TYPE}"; $SYSTEM_TYPE) |
            gsub("\\${VERSION}"; $VERSION)
        else . end)')

	# 解析配置	
	local type=$(echo "$processed_config" | jq -r '.type // empty')
	local name=$(echo "$processed_config" | jq -r '.name // empty')
	
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
			
			# 拆分文件名和扩展名
			local base_name extension
			if [[ "$filename" =~ ^(.*)\.([^.]+)\.([^.]+)$ ]]; then
				# 处理复合扩展名（如 .tar.gz）
				base_name="${BASH_REMATCH[1]}"
				extension="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
			else
				base_name="${filename%.*}"
				extension="${filename##*.}"
			fi
			
			# 定义新文件名
			local new_filename
			
			if [[ -n "${name}" && "${name}" != "null" ]]; then
				new_filename="${name}-${github_tag}.${extension}"
			else
				new_filename="${filename}"
				
				# 检查原始文件名是否已包含版本号
				if [[ "${new_filename}" != *"${github_tag}"* ]]; then
					if [[ "${new_filename}" =~ \.tar\.gz$ ]]; then
						local new_base="${base_name%.tar}"
						new_filename="${new_base}-${github_tag}.tar.gz"
					else
						new_filename="${base_name}-${github_tag}.${extension}"
					fi
				fi
			fi

			local dest_file="${downloads_path}/${new_filename}"
			download_file "${github_url}" "${dest_file}" || return 2
			;;
		*)
			echo "[ERROR] 不支持的类型下载: ${type}" >&2
			return 3
			;;
	esac
	
	# 设置输出变量
	echo "${dest_file}"
	return 0
}

# 端口检测函数
wait_for_ports()
{
	local ports=("$@")
	local timeout=${PORT_CHECK_TIMEOUT:-60} #shift
	
	local interval=1 	# 检测间隔1秒
    local counter=0
	local all_ready=false
	
	while ((counter < timeout)); do
		all_ready=true
		
		# 检查所有端口
        for port in "${ports[@]}"; do
            if ! nc -z 127.0.0.1 "$port" &> /dev/null; then 
                all_ready=false
                break
            fi
        done
		
		${all_ready} && break
		echo "尝试 $((counter + 1))/${timeout}: 端口未就绪，等待 ${interval} 秒..."
		
		sleep ${interval}
		((counter++))
	done
	
	${all_ready} && return 0 || return 1
}

# 设置SSH服务
set_ssh_service()
{
	local sshd_port="$1"
	local sshd_listen_address="$2"
	local sshd_file="$3"
    local sshd_rsakey="$4"
	
	# 验证配置文件存在
	if [ ! -f "${sshd_file}" ]; then
		echo "[ERROR] SSH服务没有安装,请检查!"
		return 1
	fi
	
	# 备份配置
    cp -f "${sshd_file}" "${sshd_file}.bak"
	
	# 设置ssh端口号
	if [ -n "${sshd_port}" ]; then
		ssh_port=$(grep -E '^(#?)Port [[:digit:]]*$' "${sshd_file}")
		if [ -n "${ssh_port}" ]; then
			sed -E -i "s/^(#?)Port [[:digit:]]*$/Port ${sshd_port}/" "${sshd_file}"
		else
			echo -e "Port ${sshd_port}" >> "${sshd_file}"
		fi
	else
		sed -i -E '/^Port[[:space:]]+[0-9]+/s/^/#/' "${sshd_file}"
	fi
	
	# 设置监听IP地址
	if [ -n "${sshd_listen_address}" ]; then
		# grep -Po '^.*ListenAddress\s+([^\s]+)' "${sshd_file}" | grep -Po '([0-9]{1,3}\.){3}[0-9]{1,3}'
		# grep -Eo '^.*ListenAddress[[:space:]]+([^[:space:]]+)' ${sshd_file} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
		ipv4_address=$(awk '/ListenAddress[[:space:]]+/ {print $2}' ${sshd_file} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		if [ -n "${ipv4_address}" ]; then
			sed -i -E 's/^(\s*)#?(ListenAddress)\s+([0-9]{1,3}\.){3}[0-9]{1,3}/\1\2 '"${sshd_listen_address}"'/' "${sshd_file}"
		else
			echo "ListenAddress ${sshd_listen_address}" >> "${sshd_file}"
		fi
	else
		sed -i -E '/^ListenAddress\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/s/^/#/' "${sshd_file}"
	fi
	
	# 设置ssh密钥KEY
	if [ ! -f "${sshd_rsakey}" ]; then
		ssh-keygen -t rsa -N "" -f "${sshd_rsakey}"
	fi
	
	# 注释密钥ssh_host_ecdsa_key
	if [ -z "`sed -n '/^#.*HostKey .*ecdsa_key/p' ${sshd_file}`" ]; then
		sed -i '/^HostKey .*ecdsa_key$/s/^/#/' "${sshd_file}"
	fi
	
	# 注释密钥ssh_host_ed25519_key
	if [ -z "`sed -n '/^#.*HostKey .*ed25519_key/p' ${sshd_file}`" ]; then
		sed -i '/^HostKey .*ed25519_key$/s/^/#/' "${sshd_file}"
	fi
	
	# 设置PermitRootLogin管理员权限登录
	if grep -q -E "^#?PermitRootLogin" "${sshd_file}"; then
		sed -i -E 's/^(#?PermitRootLogin).*/PermitRootLogin yes/' "${sshd_file}"
	else
		echo "PermitRootLogin yes" >> "${sshd_file}"
	fi
	
	# 设置PasswordAuthentication密码身份验证
	if grep -q -E "^#?PasswordAuthentication" "${sshd_file}"; then
		sed -i -E 's/^(#?PasswordAuthentication).*/PasswordAuthentication yes/' "${sshd_file}"
	else
		echo "PasswordAuthentication yes" >> "${sshd_file}"
	fi
	
	# 设置SSHD进程pid文件路径
	if [ -z "$(awk '/#PidFile /{getline a; print a}' "${sshd_file}" | sed -n '/^PidFile \/var\/run\/sshd.pid/p')" ]; then
		sed -i '/^#PidFile / a\PidFile \/var\/run\/sshd.pid' "${sshd_file}"
	fi
	
	ssh_dir="/root/.ssh"
	if [ ! -d "${ssh_dir}" ]; then
		mkdir -p "${ssh_dir}"
	fi
	
	chmod 700 "${ssh_dir}"
	return 0
}

# 增加服务用户
add_service_user()
{
	local user="$1"
	local group="$2"
	local uid="$3"
	local gid="$4"
	
	# 创建组
    if ! getent group ${group} >/dev/null; then
        addgroup -g ${gid} ${group} || {
            echo "[ERROR] 无法创建组${group}, 请检查!"
            return 1
        }
		
		echo "[DEBUG] 成功创建组${group}"
    fi
	
	# 创建用户
	if ! id -u ${user} >/dev/null 2>&1; then
        adduser -D -H -G ${group} -u ${uid} ${user} || {
            echo "[ERROR] 无法创建用户${user}, 请检查!"
            return 1
        }
		
		echo "[DEBUG] 成功创建用户${user}"
    fi
	
	return 0
}