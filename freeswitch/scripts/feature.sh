#!/bin/bash

# 查找版本的压缩包
find_latest_archive()
{
	local search_dir=$1
	local pattern=$2
	
	# 匹配项数组
	local matched_entries=()
	
	# 查找并处理匹配项
	while IFS= read -r -d $'\0' path; do
		local name=$(basename "$path")
		local type="unknown"
		
		[[ -f "$path" ]] && type="file"
		[[ -d "$path" ]] && type="directory"
		
		# 获取修改时间戳
		local mtime
		if [[ "$OSTYPE" == "darwin"* ]]; then
			mtime=$(stat -f %m "$path")
		else
			mtime=$(stat -c %Y "$path")
		fi
		
		local json_config=$(jq -n \
				--arg name "$name" \
				--arg path "$path" \
				--arg type "$type" \
				--argjson mtime "$mtime" \
				'{
					name: $name,
					path: $path,
					type: $type,
					mtime: $mtime
				}')
		
		matched_entries+=("${json_config}")
	done < <(find "${search_dir}" -maxdepth 1 -name "${pattern}" -print0 2>/dev/null)
	
	if [[ ${#matched_entries[@]} -eq 0 ]]; then
		return 2
	fi
	
	# 按修改时间降序排序
	IFS=$'\n' sorted=($(
		printf '%s\n' "${matched_entries[@]}" | 
		jq -s 'sort_by(-.mtime)'	# 直接按 mtime 降序排序
	))
	
	# 构建 JSON 输出
	local json_output=$(printf '%s\n' "${sorted[@]}" | jq '.[0]')
	
	echo "${json_output}"
	return 0
}

# 解压并验证文件
extract_and_validate() 
{
	local archive_file=$1
	local extract_dir=$2
	local pattern=${3:-".*"}

	[[ -f "$archive_file" ]] || {
		echo "[ERROR] 压缩文件不存在:$archive_file" >&2
		return 1
	}
	
	mkdir -p "$extract_dir" || {
        echo "[ERROR] 无法创建目录: $extract_dir" >&2
        return 1
    }
	
	##############################
    # 预检：检查是否已存在符合要求的条目
	##############################
	local existing_entries=()
	while IFS= read -r -d $'\0' file; do
		existing_entries+=("$file")
	done < <(find "$extract_dir" -maxdepth 1 -mindepth 1 \( -type f -o -type d \) -print0 2>/dev/null)
	
	if [[ ${#existing_entries[@]} -gt 0 ]]; then
		for entry in "${existing_entries[@]}"; do
			local entry_name=$(basename "$entry")
			# 严格全字匹配
			if [[ "$entry_name" =~ ^${pattern}$ ]]; then
				echo "$entry"
                return 0
			fi
		done
	fi

	##############################
	# 记录解压前文件列表
	local pre_list=$(mktemp)
	find "$extract_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z > "$pre_list"
	
	##############################
    # 解压操作
	local archive_name=$(basename "$archive_file")
    echo "正在解压: $archive_name → $extract_dir" >&2
	
	if ! tar -zxvf "$archive_file" -C "$extract_dir" --no-same-owner >/dev/null 2>&1; then
        echo "[ERROR] 解压失败: $archive_name" >&2
        rm -f "$pre_list"
        return 1
    fi
	
	##############################
    # 获取解压后的新增内容列表
	local post_list=$(mktemp)
    find "$extract_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z > "$post_list"
	
	# 计算新增条目
	local new_entries=()
	while IFS= read -r -d $'\0' entry; do
        new_entries+=("$entry")
    done < <(comm -13 -z "$pre_list" "$post_list")
	
    trap 'rm -f "$pre_list" "$post_list"' EXIT
	
	# 检查是否有新增内容
	if [[ ${#new_entries[@]} -eq 0 ]]; then
        echo "[ERROR] 压缩包释放内容为空: $archive_name" >&2
        return 1
    fi
	
	local extracted_entry
	if [[ ${#new_entries[@]} -eq 1 ]]; then
		extracted_entry="${new_entries[0]}"
	else
		local subdir_name="${archive_name%.tar.gz}"
		subdir_name="${subdir_name%.tgz}"
		subdir_name="${subdir_name%.zip}"
			
		local subdir_path="${extract_dir}/${subdir_name}"
		if [[ ! -d "$subdir_path" ]]; then
			mkdir -p "$subdir_path"
			
			for entry in "${new_entries[@]}"; do
				mv -f "$entry" "$subdir_path/" || {
					echo "[ERROR] 移动文件失败: $entry" >&2
					return 1
				}
			done
		fi
		
		extracted_entry="$subdir_path"
	fi
	
	echo "$extracted_entry"
	return 0
}

# 安装运行文件
install_binary()
{
	local src_path=$1
	local dest_path=$2
	local symlink_path=${3:-}
	
	# 校验源路径类型
	[[ -f "${src_path}" || -d "${src_path}" ]] || {
		echo "[ERROR] 源文件不存在,请检查!" >&2
		return 1
	}
	
	if [ ! -z "$dest_path" ]; then
		mkdir -p "${dest_path%/*}" || {
			echo "[ERROR] 无法创建目录,请检查!" >&2
			return 1
		}
		
		# 复制文件/目录
		cp -a "${src_path}" "${dest_path}" || {
			echo "[ERROR] 文件复制失败,请检查!" >&2
			return 1
		}
		
		# 设置可执行权限 (仅文件)
		[[ -f "${dest_path}" ]] && chmod +x "${dest_path}"
		
		# 创建符号链接
		[[ -n "${symlink_path}" ]] && ln -sf "${dest_path}" "${symlink_path}" 2>/dev/null || :
	else
		# 创建符号链接
		[[ -n "${symlink_path}" ]] && ln -sf "${src_path}" "${symlink_path}" 2>/dev/null || :
	fi
	
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
		--output "${dest_path}" "${url}" 2>/dev/null || {
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

# 获取releases api信息
get_github_releases()
{
	local repo=$1
	local version=$2
	
	local release_url
	if [[ "$version" == "latest" ]]; then
		release_url="https://api.github.com/repos/${repo}/releases/latest"
	else
		release_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
	fi
	
	# 获取发布信息
	local response
	response=$(curl -fsSL -w "%{http_code}" "${release_url}" 2>/dev/null) || {
		echo "[WARNING] Releases API请求失败:${release_url}" >&2
		return 1
	}
	
	local http_code=${response: -3}
	local content=${response%???}
	
	# 处理非200响应
	if [[ "$http_code" != 200 ]]; then
		echo "[ERROR] Releases API异常状态码:${http_code}" >&2
		return 2
	fi
	
	# 返回解析后的数据
	jq -c '.' <<< "${content}" 2>/dev/null || {
		echo "[ERROR] Releases数据解析失败,请检查!" >&2
		return 3
	}
	
	return 0
}

# 获取tag api信息
get_github_tag()
{
	local repo=$1
	local version=$2
	
	local tag_name
	local tags_url="https://api.github.com/repos/${repo}/tags"
	
	# 获取tags数据
	local response
	if ! response=$(curl -fsSL -w "%{http_code}" "$tags_url" 2>/dev/null); then
		echo "[WARNING] Tags API请求失败:${tags_url}" >&2
		return 1
	fi
	
	local http_code=${response: -3}
	local content=${response%???}
	
	# 处理非200响应
	if [[ "$http_code" != 200 ]]; then
		echo "[ERROR] Tags API异常状态码:${http_code}" >&2
		return 2
	fi
	
	if [[ "$version" == "latest" ]]; then
		tag_name=$(jq -r '
            map(.name | select(test("^v?[0-9]")))
            | sort_by(. | sub("^v";"") | split(".") | map(tonumber? // 0))
            | reverse
            | .[0] // empty
        ' <<< "$content")
	else
		tag_name=$(jq -r --arg ver "$version" '.[] | select(.name == $ver).name' <<< "$content")
	fi
	
	[[ -n "$tag_name" && "$tag_name" != "null" ]] || {
		echo "[ERROR] 未找到匹配的Tag: $version" >&2
		return 3
	}
	
	echo "$tag_name"
	return 0
}

# 资源匹配
match_github_assets()
{
	local release_info=$1
	local pattern=$2
	local asset_matcher=$3
	
	if [[ -n "${pattern}" && -n "${asset_matcher}" ]]; then
		return 0
	fi
	
	# 下载URL
	local download_url=""
	
	local assets=$(jq -r '.assets[] | @base64' <<< "${release_info}")
	for asset in $assets; do
		_decode() { 
			echo "$asset" | base64 -d | jq -r "$1" 
		}
		
		local name=$(_decode '.name')
		local url=$(_decode '.browser_download_url')
		
		# 双重匹配逻辑
		if [[ -n "$pattern" && "$name" =~ $pattern ]]; then
			download_url="${url}";break
		elif [[ -n "$asset_matcher" ]] && eval "$asset_matcher"; then
			download_url="${url}";break
		fi
	done
	
	if [ -z "${download_url}" ]; then
		echo "[ERROR] 未找到匹配资源,请检查！" >&2
		return 1
	fi
	
	echo "${download_url}"
	return 0
}

# 解析github的API
resolve_github_version()
{
	local repo="$1"
    local version="$2"
    local pattern="$3"
	local asset_matcher="$4"
	local -n __out_tag="$5"    # nameref 输出参数
    local -n __out_url="$6"    # nameref 输出参数
	
	# 获取发布信息
	local release_info tag_name download_url
	
	# 尝试通过 Releases API 解析
	if release_info=$(get_github_releases "$repo" "$version"); then
		tag_name=$(jq -r '.tag_name' <<< "${release_info}")
		
		if [[ -n "$tag_name" && "$tag_name" != "null" ]]; then
			# 资源匹配逻辑
			if download_url=$(match_github_assets "$release_info" "$pattern" "$asset_matcher"); then
				__out_url="$download_url"
			else
				echo "[NOTICE] 资源匹配失败，使用默认地址" >&2
				__out_url="https://github.com/${repo}/archive/refs/tags/${tag_name}.tar.gz"
			fi
			
			__out_tag="$tag_name"
			return 0
		fi
	fi
	
	echo "[WARNING] Releases标签无效，尝试回退Tags API..." >&2
	
	# 回退到 Tags API
	if ! tag_name=$(get_github_tag "$repo" "$version"); then
		return 1
	fi
	
	__out_tag="$tag_name"
	__out_url="$download_url"
	
	return 0
}

# Git 版本解析器
resolve_git_version()
{
	local repo_url="$1"
    local version="$2"
	local -n __out_tag="$3"    # nameref 输出参数
    local -n __out_url="$4"    # nameref 输出参数
	
	# 获取远程引用信息
	local remote_refs=$(git ls-remote --tags --heads --refs "$repo_url" 2>/dev/null) || {
		echo "[ERROR] 无法访问远程仓库信息:$repo_url" >&2
		return 1
	}
	
	local tag_name download_url
	if [[ "$version" = "latest" ]]; then
		tag_name=$(echo "$remote_refs" | awk -F/ '{print $3}' | \
				grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | \
				sort -Vr | \
				head -n1)
			
		[[ -z "$tag_name" ]] && {
			tag_name="master"
		}
	else
		if [[ ! "$version" =~ ^[0-9a-f]{7,40}$ ]]; then
			if ! grep -q "refs/heads/${version}" <<< "$remote_refs"; then
				echo "[ERROR] 远程仓库的分支不存在:$version" >&2
				return 1
			fi
		fi
		
		tag_name="$version"
	fi
	
	#
	local repo_domain repo_path
	[[ "$repo_url" =~ ^(https?://[^/]+)/(.*)\.git$ ]] && {
		repo_domain="${BASH_REMATCH[1]}"
        repo_path="${BASH_REMATCH[2]}"
	}
	
	# 生成归档URL
	download_url="${repo_domain}/${repo_path}/archive/${tag_name}.tar.gz"
	
	__out_tag="$tag_name"
	__out_url="$download_url"
	return 0
}

# 获取github信息
get_github_info()
{
	local json_config=$1
	local -n __result_tag=$2	# nameref 直接引用外部变量
	local -n __result_url=$3
	
	# 解析配置参数
	local repo=$(jq -r '.repo' <<< "$json_config")
	local version=$(jq -r '.version // "latest"' <<< "$json_config")
	local pattern=$(jq -r '.pattern // ""' <<< "$json_config")
	local asset_matcher=$(jq -r '.asset_matcher // ""' <<< "$json_config")

	if [[ -n "$pattern" || -n "$asset_matcher" ]]; then
		if ! resolve_github_api "$repo" "$version" "$pattern" "$asset_matcher" __result_tag __result_url; then
			echo "[ERROR] 无法解析github的API: repo=${repo}, version=${version}" >&2
			return 1
		fi
	else
		local github_repo_url="https://github.com/${repo}.git"
		if ! resolve_git_version "$github_repo_url" "$version" __result_tag __result_url; then
			echo "[ERROR] 无法解析git的版本: repo=${repo}, version=${version}" >&2
			return 1
		fi
		
		__result_url="$github_repo_url"
	fi
	
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

# 克隆仓库
clone_repo()
{
	local json_config=$1
	local downloads_path=$2
	
	local processed_config=$(jq -n \
		--argjson config "$json_config" \
		--arg VERSION "$VERSION" \
		'$config | 
		walk(if type == "string" then 
			gsub("\\${VERSION}"; $VERSION)
		else . end)')
		
	# 解析配置	
	local type=$(jq -r '.type // empty' <<< "$processed_config")
	local name=$(jq -r '.name // empty' <<< "$processed_config")
	local repo=$(jq -r '.repo // empty' <<< "$processed_config")
	local version=$(jq -r '.version // "master"' <<< "$processed_config")
	
	if [[ -z "$type" || -z "$name" || -z "$repo" ]]; then
		echo "[ERROR] 缺少必要的克隆参数: type或repo" >&2
		return 1
	fi
	
	echo "[INFO] 获取${name}版本信息..." >&2
	
	local repo_branch repo_url
	case ${type} in
		"github")
			if ! get_github_info "$processed_config" repo_branch repo_url; then
				return 1
			fi
			;;
		*)
			echo "[ERROR] 不支持的类型下载: ${type}" >&2
			return 3
	esac
	
	# 目标目录
	if [[ "$repo_branch" =~ ^[0-9a-f]{7,40}$ ]]; then
		local target_dir="${downloads_path}/${name}"
	else
		local target_dir="${downloads_path}/${name}-${repo_branch}"
	fi
	
	if [[ -d "$target_dir" ]]; then
		echo "[WARNING] 克隆目录已存在:${target_dir}" >&2
		return 0
	fi
	
	mkdir -p "$target_dir"
	echo "[INFO] 正在克隆仓库: $repo_url" >&2
	
	local index max_retries=3
	for index in $(seq 1 $max_retries); do
		# --depth 1 --branch "$repo_branch"
		if git clone --no-checkout "$repo_url" "$target_dir" 2>/dev/null; then	
			break
		elif [ $index -eq $max_retries ]; then
			echo "[ERROR] 第${index}次克隆失败，放弃重试" >&2
			return 4
		else
			echo "[WARNING] 第${index}次克隆失败，10秒后重试..." >&2
			sleep 10
		fi
	done
	
	# 验证目录是否存在
	if [[ ! -d "$target_dir" ]]; then
		echo "[ERROR] 克隆获取目录失败,请检查!" >&2
		return 5
	else
		if [[ "$repo_branch" != "master" ]]; then
			cd "$target_dir"
			echo "[INFO] 正在检出仓库版本：$repo_branch" >&2
			
			git checkout "$repo_branch" 2>/dev/null || {
				echo "[ERROR] 版本检出失败:$repo_branch"
				return 6
			}
		fi
	fi
	
	local absolute_path
	absolute_path=$(realpath "$target_dir")
	
	# 设置输出变量
	echo "${target_dir}"
	return 0
}

# 增加服务用户
add_service_user()
{
	local user="$1"
	local group="$2"
	local uid="$3"
	local gid="$4"
	
	local addgroup_cmd adduser_cmd
	
	if [ -f /etc/alpine-release ]; then
        addgroup_cmd="addgroup -g $gid $group"
        adduser_cmd="adduser -D -H -G $group -u $uid $user"
    else
        addgroup_cmd="groupadd --gid $gid $group"
        adduser_cmd="useradd --create-home --shell /bin/bash --gid $group --uid $uid $user"
    fi
	
	# 创建组
	if ! getent group $group >/dev/null; then
		$addgroup_cmd || {
			echo "[ERROR] 无法创建组${group}, 请检查!"
			return 1
		}
		
		echo "[DEBUG] 成功创建组${group}"
	fi
	
	# 创建用户
	if ! id -u ${user} >/dev/null 2>&1; then
		$adduser_cmd || {
			echo "[ERROR] 无法创建用户${user}, 请检查!"
			return 1
		}
		
		echo "[DEBUG] 成功创建用户${user}"
	fi
	
	return 0
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