#!/bin/bash

# 查找版本的压缩包
find_latest_archive()
{
	local search_dir=$1
	local pattern=$2
	
	# 匹配项数组
	local matched_entries=()
	
	# 查找并处理匹配项
	while IFS= read -r -d $'\0' filepath; do
		local filetype="unknown"
		local filename=$(basename "$filepath")
		
		[[ -f "$filepath" ]] && filetype="file"
		[[ -d "$filepath" ]] && filetype="directory"
		
		local suffix="" name="$filename"
		if [[ "$filename" =~ \.([[:alpha:]]{3,})\.([[:alpha:]]{2,3})$ ]]; then
			# 匹配两段式后缀（如 .tar.gz）
			suffix=".${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			base_name="${filename%$suffix}"
		elif [[ "$filename" =~ \.([[:alpha:]]{2,})$ ]]; then
			# 匹配单一段式后缀（如 .gz）
			suffix=".${BASH_REMATCH[1]}"
			base_name="${filename%$suffix}"
		fi
		
		# 获取修改时间戳
		local mtime
		if [[ "$OSTYPE" == "darwin"* ]]; then
			mtime=$(stat -f %m "$filepath")
		else
			mtime=$(stat -c %Y "$filepath")
		fi
		
		local json_config=$(jq -n \
				--arg name "$name" \
				--arg filename "$filename" \
				--arg filepath "$filepath" \
				--arg filetype "$filetype" \
				--argjson mtime "$mtime" \
				'{
					name: $name,
					filename: $filename,
					filepath: $filepath,
					filetype: $filetype,
					mtime: $mtime
				}')
		
		matched_entries+=("$json_config")
	done < <(find "$search_dir" -maxdepth 1 -regex ".*/$pattern" -print0 2>/dev/null)
	
	if [[ ${#matched_entries[@]} -eq 0 ]]; then
		return 1
	fi
	
	# 按修改时间降序排序
	IFS=$'\n' sorted=($(
		printf '%s\n' "${matched_entries[@]}" | 
		jq -s 'sort_by(-.mtime)'	# 直接按 mtime 降序排序
	))
	
	# 构建 JSON 输出
	local json_output=$(printf '%s\n' "${sorted[@]}" | jq '.[0]')
	
	echo "$json_output"
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
	
	local extracted_entry
	if [[ ! "$archive_name" =~ \.(tar\.gz|tar)$ ]]; then
		if mv -f "$archive_file" "$extract_dir/"; then
			extracted_entry="$extract_dir/$archive_name"
		fi
	else
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
		
		if [[ ${#new_entries[@]} -eq 1 ]]; then
			extracted_entry="${new_entries[0]}"
		else
			local subdir_name="${archive_name%.tar.gz}"
			subdir_name="${subdir_name%.tgz}"
			subdir_name="${subdir_name%.zip}"
				
			local subdir_path="$extract_dir/$subdir_name"
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
	[[ -f "$src_path" || -d "$src_path" ]] || {
		echo "[ERROR] 源文件不存在,请检查!" >&2
		return 1
	}
	
	if [ ! -z "$dest_path" ]; then
		mkdir -p "${dest_path%/*}" || {
			echo "[ERROR] 无法创建目录,请检查!" >&2
			return 1
		}
		
		# 复制文件/目录
		cp -a "$src_path" "$dest_path" || {
			echo "[ERROR] 文件复制失败,请检查!" >&2
			return 1
		}
		
		# 设置可执行权限 (仅文件)
		[[ -f "$dest_path" ]] && chmod +x "$dest_path"
		
		# 创建符号链接
		[[ -n "$symlink_path" ]] && ln -sf "$dest_path" "$symlink_path" 2>/dev/null || :
	else
		# 创建符号链接
		[[ -n "$symlink_path" ]] && ln -sf "$src_path" "$symlink_path" 2>/dev/null || :
	fi
	
	return 0
}

# 下载文件
download_file()
{
	local url=$1
	local dest_path=$2
	
	if [ -z "$url" ]; then
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
		--output "$dest_path" "$url" 2>/dev/null || {
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
	response=$(curl -fsSL -w "%{http_code}" "$release_url" 2>/dev/null) && [ -n "$response" ] || {
		echo "[WARNING] Releases API请求失败: $release_url" >&2
		return 1
	}
	
	local http_code=${response: -3}
	local content=${response%???}
	
	# 处理非200响应
	if [[ "$http_code" != 200 ]]; then
		echo "[ERROR] Releases API异常状态码:$http_code" >&2
		return 2
	fi
	
	# 返回解析后的数据
	jq -c '.' <<< "$content" 2>/dev/null || {
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
	response=$(curl -fsSL -w "%{http_code}" "$tags_url" 2>/dev/null) && [ -n "$response" ] || {
		echo "[WARNING] Tags API请求失败: $tags_url" >&2
		return 1
	}
	
	local http_code=${response: -3}
	local content=${response%???}

	# 处理非200响应
	if [[ "$http_code" != 200 ]]; then
		echo "[ERROR] Tags API异常状态码:$http_code" >&2
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
	
	if [[ -n "$pattern" && -n "$asset_matcher" ]]; then
		return 0
	fi
	
	local assets download_url=""
	assets=$(jq -r '.assets[] | @base64' <<< "$release_info")
	for asset in $assets; do
		_decode() { 
			echo "$asset" | base64 -d | jq -r "$1" 
		}
		
		local name=$(_decode '.name')
		local url=$(_decode '.browser_download_url')
		
		# 双重匹配逻辑
		if [[ -n "$pattern" && "$name" =~ $pattern ]]; then
			download_url="$url";break
		elif [[ -n "$asset_matcher" ]] && eval "$asset_matcher"; then
			download_url="$url";break
		fi
	done
	
	if [ -z "$download_url" ]; then
		echo "[ERROR] 未找到匹配资源,请检查！" >&2
		return 1
	fi
	
	echo "$download_url"
	return 0
}

# 解析github的API
resolve_github_version()
{
	local json_config="$1"
	local -n __out_tag="$2"		# nameref 输出参数
	local -n __out_url="$3"		# nameref 输出参数
	
	local repo=$(jq -r '.repo // empty' <<< "$json_config")
	local version=$(jq -r '.version // "latest"' <<< "$json_config")
	local pattern=$(jq -r '.pattern // empty' <<< "$json_config")
	local asset_matcher=$(jq -r '.asset_matcher // empty' <<< "$json_config")
	local tags_value=$(jq -r '.tags // empty' <<< "$json_config")
	
	# 获取发布信息
	local release_info tag_name download_url
	
	# 尝试 Releases API 解析
	if ! release_info=$(get_github_releases "$repo" "$version"); then
		echo "[WARNING] 尝试使用Tags API请求..." >&2
		
		# 尝试 Tags API 解析
		if ! tag_name=$(get_github_tag "$repo" "$version"); then
			return 2
		fi
	else
		tag_name=$(jq -r '.tag_name' <<< "$release_info")
	fi
	
	if [[ -z "$tag_name" || "$tag_name" == "null" ]]; then
		echo "[ERROR] 解析Github Tags名称失败:$repo" >&2
		return 1
	fi
	
	if [ -n "$release_info" ]; then
		download_url=$(match_github_assets "$release_info" "$pattern" "$asset_matcher")	
	fi
	
	if [ -z "$download_url" ]; then
		if [[ "$tags_value" = "" || "$tags_value" = "release" ]]; then
			echo "[ERROR] Releases API 资源匹配失败:$repo" >&2
			return 3
		elif [[ "$tags_value" = "sources" ]]; then
			download_url="https://github.com/$repo/archive/refs/tags/$tag_name.tar.gz"
			echo "[NOTICE] Releases API 资源信息获取失败,默认地址:$download_url" >&2
		fi
	fi
	
	__out_tag="$tag_name"
	__out_url="$download_url"
	
	return 0
}

# Git 版本解析器
resolve_git_version()
{
	local json_config="$1"
	local -n __out_tag="$2"
	local -n __out_url="$3"
	
	local repo_url=$(jq -r '.url // empty' <<< "$json_config")
	local version=$(jq -r '.version // "master"' <<< "$json_config")
	
	if [[ -z "$repo_url" || -z "$version" ]]; then
		echo "[ERROR] 远程仓库信息不能为空:url=$repo_url,version=$version" >&2
		return 1
	fi
	
	echo "[INFO] 获取远程仓库信息:$repo_url" >&2
	
	# 获取远程引用信息
	local remote_refs
	remote_refs=$(git ls-remote --tags --heads --refs "$repo_url" 2>/dev/null) && [ -n "$remote_refs" ] || {
		echo "[ERROR] 无法访问远程仓库信息:$repo_url" >&2
		return 2
	}
	
	local tag_name
	if [[ "$version" = "latest" ]]; then
		tag_name=$(echo "$remote_refs" | awk -F/ '{print $3}' | \
				grep -E '^(v|.*-)[0-9]+\.[0-9]+(\.[0-9]+)?$' | \
				sort -Vr | \
				head -n1)
		
		[[ -z "$tag_name" ]] && {
			tag_name="master"
		}
	else
		if [[ ! "$version" =~ ^[0-9a-f]{7,40}$ ]]; then
			if ! grep -q "refs/heads/$version" <<< "$remote_refs"; then
				echo "[ERROR] 远程仓库的分支不存在:$version" >&2
				return 1
			fi
		fi
		
		tag_name="$version"
	fi
	
: <<'COMMENT_BLOCK'
		local repo_domain repo_path
		[[ "$repo_url" =~ ^(https?://[^/]+)/(.*)\.git$ ]] && {
			repo_domain="${BASH_REMATCH[1]}"
			repo_path="${BASH_REMATCH[2]}"
		}
		
		# 生成归档URL
		local download_url="$repo_domain/$repo_path/archive/$tag_name.tar.gz"
COMMENT_BLOCK

	__out_tag="$tag_name"
	__out_url="$repo_url"
	return 0
}

# 获取github信息
get_github_info()
{
	local json_config=$1
	local -n __result_tag=$2	# nameref 直接引用外部变量
	local -n __result_url=$3
	
	if jq -e 'has("pattern") or has("asset_matcher")' <<< "$json_config" >/dev/null 2>&1; then
		if ! resolve_github_version "$json_config" __result_tag __result_url; then
			return 1
		fi
	else
		if ! resolve_git_version "$json_config" __result_tag __result_url; then
			return 1
		fi
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
			gsub("\\$SYSTEM_ARCH"; $SYSTEM_ARCH) |
			gsub("\\$SYSTEM_TYPE"; $SYSTEM_TYPE) |
			gsub("\\$VERSION"; $VERSION)
		else . end)')

	# 解析配置	
	local type=$(echo "$processed_config" | jq -r '.type // empty')
	local name=$(echo "$processed_config" | jq -r '.name // empty')
	
	case $type in
		"static")
			local url=$(jq -r '.url // empty' <<< "${processed_config}")
			
			local filename="${name:-$(basename "$url")}"
			local dest_file="$downloads_path/$filename"
			
			download_file "$url" "$dest_file" || return 2
			;;
		"github")
			local repo_branch repo_url
			if ! get_github_info "$processed_config" repo_branch repo_url; then
				return 3
			fi
			
			# 原始文件名
			local filename=$(basename "$repo_url")
			
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
			local new_filename=""
			
			if [ -n "$name" ]; then
				new_filename="$name-$repo_branch.$extension"
			else
				new_filename="$filename"
				
				# 检查原始文件名是否已包含版本号
				if [[ "$new_filename" != *"$repo_branch"* ]]; then
					if [[ "$new_filename" =~ \.tar\.gz$ ]]; then
						local new_base="${base_name%.tar}"
						new_filename="$new_base-$repo_branch.tar.gz"
					else
						new_filename="$base_name-$repo_branch.$extension"
					fi
				fi
			fi
			
			local dest_file="$downloads_path/$new_filename"
			download_file "$repo_url" "$dest_file" || return 2
			;;
		*)
			echo "[ERROR] 不支持的类型下载: $type" >&2
			return 1
			;;
	esac
	
	# 设置输出变量
	echo "$dest_file"
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
			gsub("\\$VERSION"; $VERSION)
		else . end)')
		
	# 解析配置	
	local type=$(jq -r '.type // empty' <<< "$processed_config")
	local name=$(jq -r '.name // empty' <<< "$processed_config")

	if [[ -z "$type" || -z "$name" ]]; then
		echo "[ERROR] 缺少必要的克隆参数: type或repo" >&2
		return 1
	fi
	
	local repo_branch repo_url
	echo "[INFO] 获取${name}版本信息..." >&2
	
	case ${type} in
		"github")
			if ! get_github_info "$processed_config" repo_branch repo_url; then
				return 2
			fi
			;;
		*)
			echo "[ERROR] 不支持的类型下载: $type" >&2
			return 1
	esac
	
	# 定义新文件名
	local new_filename="$name"
	if [[ -z "$name" || ! "$repo_branch" =~ ^[0-9a-f]{7,40}$ ]]; then
		if [[ "$repo_branch" == *"$name"* ]]; then
			new_filename="$repo_branch"
		else
			new_filename="$name-$repo_branch"
		fi
	fi
	
	local target_dir="$downloads_path/$new_filename"
	if [[ -d "$target_dir" ]]; then
		echo "[WARNING] 克隆目录已存在:$target_dir" >&2
		return 0
	fi
	
	local index max_retries=3
	for index in $(seq 1 $max_retries); do
		echo "[INFO] 正在克隆仓库: $repo_url" >&2
		
		# --depth 1 --branch "$repo_branch"
		if git clone --no-checkout "$repo_url" "$target_dir" 2>/dev/null; then
			break
		elif [ $index -eq $max_retries ]; then
			echo "[ERROR] 第$index次克隆失败,放弃重试" >&2
			return 3
		else
			echo "[WARNING] 第$index次克隆失败,10秒后重试..." >&2
			sleep 10
		fi
	done
	
	# 验证目录是否存在
	if [[ ! -d "$target_dir" ]]; then
		echo "[ERROR] 克隆获取目录失败,请检查!" >&2
		return 1
	else
		if [[ "$repo_branch" != "master" ]]; then
			cd "$target_dir" && echo "[INFO] 正在检出仓库版本：$repo_branch" >&2

			git checkout "$repo_branch" &>/dev/null || {
				echo "[ERROR] 仓库版本检出失败:$repo_branch" >&2
				return 4
			}
			
		fi
	fi

: <<'COMMENT_BLOCK'
	local absolute_path
	absolute_path=$(realpath "$target_dir")
COMMENT_BLOCK
	
	# 设置输出变量
	echo "$target_dir"
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
	if ! id -u $user >/dev/null 2>&1; then
		$adduser_cmd || {
			echo "[ERROR] 无法创建用户$user, 请检查!"
			return 1
		}
		
		echo "[DEBUG] 成功创建用户$user"
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
	if [ ! -f "$sshd_file" ]; then
		echo "[ERROR] SSH服务没有安装,请检查!"
		return 1
	fi
	
	# 备份配置
	cp -f "$sshd_file" "$sshd_file.bak"
	
	# 设置ssh端口号
	if [ -n "$sshd_port" ]; then
		local ssh_port=$(grep -E '^(#?)Port [[:digit:]]*$' "$sshd_file")
		if [ -n "$ssh_port" ]; then
			sed -E -i "s/^(#?)Port [[:digit:]]*$/Port $sshd_port/" "$sshd_file"
		else
			echo -e "Port $sshd_port" >> "$sshd_file"
		fi
	else
		sed -i -E '/^Port[[:space:]]+[0-9]+/s/^/#/' "$sshd_file"
	fi
	
	# 设置监听IP地址
	if [ -n "$sshd_listen_address" ]; then
		# grep -Po '^.*ListenAddress\s+([^\s]+)' "${sshd_file}" | grep -Po '([0-9]{1,3}\.){3}[0-9]{1,3}'
		# grep -Eo '^.*ListenAddress[[:space:]]+([^[:space:]]+)' ${sshd_file} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
		local ipv4_address=$(awk '/ListenAddress[[:space:]]+/ {print $2}' $sshd_file | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		if [ -n "$ipv4_address" ]; then
			sed -i -E 's/^(\s*)#?(ListenAddress)\s+([0-9]{1,3}\.){3}[0-9]{1,3}/\1\2 '"$sshd_listen_address"'/' "$sshd_file"
		else
			echo "ListenAddress $sshd_listen_address" >> "$sshd_file"
		fi
	else
		sed -i -E '/^ListenAddress\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/s/^/#/' "$sshd_file"
	fi
	
	# 设置ssh密钥KEY
	if [ ! -f "$sshd_rsakey" ]; then
		ssh-keygen -t rsa -N "" -f "$sshd_rsakey"
	fi
	
	# 注释密钥ssh_host_ecdsa_key
	if [ -z "`sed -n '/^#.*HostKey .*ecdsa_key/p' $sshd_file`" ]; then
		sed -i '/^HostKey .*ecdsa_key$/s/^/#/' "$sshd_file"
	fi
	
	# 注释密钥ssh_host_ed25519_key
	if [ -z "`sed -n '/^#.*HostKey .*ed25519_key/p' $sshd_file`" ]; then
		sed -i '/^HostKey .*ed25519_key$/s/^/#/' "$sshd_file"
	fi
	
	# 设置PermitRootLogin管理员权限登录
	if grep -q -E "^#?PermitRootLogin" "$sshd_file"; then
		sed -i -E 's/^(#?PermitRootLogin).*/PermitRootLogin yes/' "$sshd_file"
	else
		echo "PermitRootLogin yes" >> "$sshd_file"
	fi
	
	# 设置PasswordAuthentication密码身份验证
	if grep -q -E "^#?PasswordAuthentication" "$sshd_file"; then
		sed -i -E 's/^(#?PasswordAuthentication).*/PasswordAuthentication yes/' "$sshd_file"
	else
		echo "PasswordAuthentication yes" >> "$sshd_file"
	fi
	
	# 设置SSHD进程pid文件路径
	if [ -z "$(awk '/#PidFile /{getline a; print a}' "$sshd_file" | sed -n '/^PidFile \/var\/run\/sshd.pid/p')" ]; then
		sed -i '/^#PidFile / a\PidFile \/var\/run\/sshd.pid' "$sshd_file"
	fi
	
	local ssh_dir="/root/.ssh"
	if [ ! -d "$ssh_dir" ]; then
		mkdir -p "$ssh_dir"
	fi
	
	chmod 700 "$ssh_dir"
	return 0
}

# 端口检测函数
wait_for_ports()
{
	local default_host="127.0.0.1"
	local default_timeout="60"
	local default_interval="0.5"
	local default_max_interval="5"
	
	local host="$default_host"
	local timeout="$default_timeout"
	local interval="$default_interval"
	local max_interval="$default_max_interval"
	
	# 判断参数数量
	if [[ $# -eq 0 ]]; then
		echo "[ERROR] 至少需要指定一个端口"
		return 1
	fi
	
	local options_list="" ports_list="" 
	if [[ $# -eq 1 ]]; then
		ports_list="$1"
	else
		options_list="$1"
		shift 1
		ports_list="$@"
	fi
	
	if [[ -n "$options_list" && "$options_list" == *":"* ]]; then
		IFS=":" read -r -a arg_parts <<< "$options_list"
		local num_parts="${#arg_parts[@]}"
		if [[ "$num_parts" -gt 4 ]]; then
			echo "[ERROR] 选项参数的格式错误,请检查!"
			return 1
		fi
		
		local host="${arg_parts[0]:-$default_host}"
		local timeout="${arg_parts[1]:-$default_timeout}"
		local interval="${arg_parts[2]:-$default_interval}"
		local max_interval="${arg_parts[3]:-$default_max_interval}"
	fi
	
	# 提取参数
	local ports=()
	if [[ -z "$ports_list" ]]; then
		echo "[ERROR] 端口列表不能为空,请检查!"
		return 1
	else
		IFS=':,\ ' read -ra ports <<< "$ports_list"
		if [[ ${#ports[@]} -eq 0 ]]; then
			echo "[ERROR] 未检测到有效的端口,请检查!" >&2
			return 1
		fi
	fi

	local counter=0
	local all_ready=false
	local total_elapsed=0

	while true; do
		counter=$((counter + 1))

		all_ready=true
		local closed_ports=()	# 记录当前未就绪的端口
		
		# 检查执行端口
		for port in "${ports[@]}"; do
			if ! nc -z -w 1 "$host" "$port" &> /dev/null; then 
				all_ready=false
				closed_ports+=("$port")
				break
			fi
		done
		
		if $all_ready; then
			printf "[SUCCESS] 所有端口在 %.1f 秒内就绪（尝试 %d 次）\n" "$total_elapsed" "$counter"
			break
		fi
		
		# 超时判断
		if (( $(echo "$total_elapsed >= $timeout" | bc -l) )); then
			echo "[ERROR] 等待端口超过 ($timeout) 秒,未就绪端口: ${closed_ports[*]}" >&2
			break
		fi
		
		# 动态计算剩余时间和调整间隔
		local remaining=$(echo "$timeout - $total_elapsed" | bc -l)
		local next_interval=$(echo "if ($interval > $remaining) $remaining else $interval" | bc -l)
		
		next_interval=$(echo "if ($next_interval > $max_interval) $max_interval else $next_interval" | bc -l)
		printf "等待中...[已等待 %.1f 秒, 剩余 %.1f 秒] 未就绪端口: %s，下次检测间隔 %.1f 秒\n" "$total_elapsed" "$remaining" "${closed_ports[*]}" "$next_interval"
		
		sleep $next_interval
		total_elapsed=$(echo "$total_elapsed + $next_interval" | bc -l)
		
		# 指数退避调整间隔
		interval=$(echo "$interval * 2" | bc -l)
	done
	
	$all_ready && return 0 || return 1
}

# 等待进程 id
wait_for_pid()
{
	local timeout=${1:-10}
	local pid_source=${2:-}
	local process_name=${3:-}
		
	local max_attempts=$timeout
	local process_pid=""
	local elapsed=0
	
	local result=0
	local last_status="启动中..."
	
	if [[ -z "$pid_source" && -z "$process_name" ]]; then
		echo -e "\033[31m❌ [ERROR] 未提供 PID 源或进程名\033[0m"
		return 1
	fi
	
	# 显示开始信息
	echo -e "\033[34m⏳ 等待进程启动 | 超时: ${timeout}秒\033[0m"
	
	while ((elapsed <= max_attempts)); do
		local remaining=$((max_attempts - elapsed))
		echo -e "\033[33m🕒 已等待: ${elapsed}秒 | 剩余: ${remaining}秒 | 状态: ${last_status}\033[0m"
		
		if [[ -n "$pid_source" ]]; then
			if [[ -f "$pid_source" ]]; then
				process_pid=$(tr -d '[:space:]' < "$pid_source" 2>/dev/null)
			elif [[ "$pid_source" =~ ^[0-9]+$ ]]; then
				process_pid="$pid_source"
			fi
		elif [[ -n "$process_name" ]]; then
			process_pid=$(pgrep -f "$process_name" | head -n1)
		fi
		
		# 验证 PID
		if [[ -z "$process_pid" ]]; then
			result=2
			last_status="未获取到 PID"
		elif ! [[ "$process_pid" =~ ^[0-9]+$ ]]; then
			result=3
			last_status="PID无效: $process_pid"
		elif ! kill -0 "$process_pid" >/dev/null 2>&1; then
			result=4
			last_status="PID不存在: $process_pid"
		elif [[ -n "$process_name" ]]; then
			local actual_name=$(ps -p "$process_pid" -o comm= 2>/dev/null)
			if [[ ! "$actual_name" =~ $process_name ]]; then
				result=5
				last_status="进程不匹配: '$process_name'≠'$actual_name'"
			else
				result=0
				break
			fi
		else
			result=0
			break
		fi
		
		sleep 1
		((elapsed++))
	done
	
	if ((elapsed >= timeout)); then
		result=6
		last_status="运行超时"
	fi
	
	if ((result == 0)); then
		echo -e "\033[32m✅ 进程启动成功! PID: $process_pid | 耗时: ${elapsed}秒\033[0m"
	else
		echo -e "\033[31m❌ 进程启动失败! | 超时: ${timeout}秒 | 最后状态: ${last_status}\033[0m"
	fi
	
	return $result
}

# perl修改XML节点
set_xml_perl()
{
	local file="$1" mode="$2" xpath="$3" new_xml="$4" position="$5"
	
	perl - "$file" "$mode" "$xpath" "$new_xml" "$position" <<'EOF_PERL'
use strict;
use warnings;
use XML::LibXML;
use XML::LibXML::PrettyPrint;

# 转义 XPath 中的单引号
sub escape_xpath_value {
	my ($value) = @_;
	$value =~ s/'/''/g;  	# 单引号转义为两个单引号
	return $value;
}

my ($file, $mode, $xpath, $new_xml, $position) = @ARGV;

# 解析 XML 并保留格式
my $parser = XML::LibXML->new({
	keep_blanks => 1,
	expand_entities => 0,
	load_ext_dtd => 0
});

my $doc = eval { $parser->parse_file($file) };	# die "XML 解析失败: $@" if $@;
if ($@) {
	warn "[ERROR] XML 解析失败: $@";
	exit 1;
}

if ($mode eq 'update') {
	my ($target) = $doc->findnodes($xpath);
	if (!$target) {
		warn "[WARNING] 目标节点未找到: $xpath";
		exit 0;
	}
	
	# 解析新属性的键值对
	my %new_attrs = $new_xml =~ /(\w+)="([^"]*)"/g;
	foreach my $attr (keys %new_attrs) {
		$target->setAttribute($attr, $new_attrs{$attr});
	}
} else {
	# 解析新节点
	my $new_node;
	eval {
		$new_node = XML::LibXML->load_xml(string => $new_xml)->documentElement;
	};
	if ($@) {
		warn "[ERROR] 新节点的 XML 语法错误: $@";
		exit 1;
	}
	
	# 构造检查 XPath
	my $tag_name = $new_node->nodeName;
	my %attrs = map { $_->name => $_->value } $new_node->attributes;
	
	my @conditions;
	foreach my $attr (keys %attrs) {
		my $escaped_value = escape_xpath_value($attrs{$attr});
		push @conditions, sprintf("\@%s='%s'", $attr, $escaped_value);
	}
	
	my $xpath_check = @conditions ? 
		"//*[local-name()='$tag_name' and " . join(" and ", @conditions) . "]" :
		"//*[local-name()='$tag_name']";
		
	# 检查节点是否已存在
	my ($existing_node) = $doc->findnodes($xpath_check);
	if ($existing_node) {
		print "[INFO] 新增节点已存在: $new_xml\n";
		exit 0;
	}
	
	# 定位目标节点
	my ($target) = $mode eq 'insert' 
		? $doc->findnodes($xpath) 
		: $doc->findnodes("${xpath}[not(ancestor::comment())]");
	if (!$target) {
		warn "[WARNING] 目标节点未找到: $xpath";
		exit 0;
	}
	
	# 操作节点
	my $parent = $target->parentNode;
	if ($mode eq 'insert') {
		$position eq 'before' ? 
			$parent->insertBefore($new_node, $target) :
			$parent->insertAfter($new_node, $target);
	} elsif ($mode eq 'replace') {
		my $comment = $doc->createComment(" " . $target->toString . " ");
		$parent->replaceChild($comment, $target);
		$parent->insertAfter($new_node, $comment);
	}
}

# 格式化 XML（添加缩进和换行）
my $pp = XML::LibXML::PrettyPrint->new(indent_string => "  ");
$pp->pretty_print($doc);

# 写入文件
$doc->toFile($file);
exit 0;
EOF_PERL
}

modify_xml_config() 
{
	local OPTIND file mode old_pattern new_config position
	mode="replace"
	position="before"
	
	# 参数解析
	while getopts "f:m:o:n:c:p:d" opt; do
		case "$opt" in
			f) file="$OPTARG" ;;
			m) mode="$OPTARG" ;;
			o) old_pattern="$OPTARG" ;;
			n) new_config="$OPTARG" ;;
			p) position="$OPTARG" ;;
			*) echo "Usage: ${FUNCNAME[0]} -f file [-m replace|insert] -o pattern -n new_config [-p before|after]"; return 1 ;;
		esac
	done
	
	[[ -z "$file" || ! -f "$file" ]] && { echo "[ERROR] 文件不存在: $file" >&2; return 1; }
	[[ -z "$new_config" ]] && { echo "[ERROR] 输入新的配置！" >&2; return 1; }
	
	set_xml_perl "$file" "$mode" "$old_pattern" "$new_config" "$position" || {
		echo "[ERROR] 操作XML文件失败: $file (错误码: $?)" >&2
		return 1
	}
	
	return 0
}

# 检查 nginx 配置
check_nginx_conf()
{
	local conf_file="$1"
	local status_code=0
	
	# 判断awk命令是否存在
	local awk_cmd
	if command -v gawk &>/dev/null; then
		awk_cmd="gawk"
	elif command -v awk &>/dev/null; then
		awk_cmd="awk"
	else
		echo "[ERROR] awk命令不存在，请检查系统环境！"
		return 1
	fi

	status_code=$($awk_cmd '
	BEGIN {
		stack_idx = 0          # 括号堆栈索引
		has_http = 0           # 存在未注释的http块
		has_server = 0         # 存在未注释的server块
		invalid_config = 0     # 配置是否无效
		line_num = 0           # 当前行号
		delete stack           # 初始化堆栈
	}

	{
		line_num++
		$0 = gensub(/#.*/, "", "g")  # 去除行内注释
		$0 = gensub(/^[[:blank:]]+|[[:blank:]]+$/, "", "g")  # 清理首尾空格
		if ($0 ~ /^[[:blank:]]*$/) next  # 跳过空行
	}

	# 检测块开始
	#match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+(.*)[ \t]*\{/, arr) {
	match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+([^{}]*)[ \t]*\{[ \t]*$/, arr) {
		block_type = arr[1]
		block_param = arr[2]

		if (block_type == "location") {
			sub(/^[[:space:]]*[=~*]+[[:space:]]*/, "", block_param)  # 移除前缀修饰符
		}

		block_value=block_param
		if (block_value == "") {
			block_value=block_type
		}

		stack[++stack_idx] = block_value			  # 推入堆栈
		
		if (block_type == "http" || block_type == "server") {
			has_http += (block_type == "http")       # 标记存在http块
			has_server += (block_type == "server")   # 标记存在server块
		}
		next
	}

	# 检测闭合符
	/^[[:blank:]]*\}/ {
		if (stack_idx == 0) {
			invalid_config = 1
			next
		}

		current_block = stack[stack_idx]
		stack_idx--
		next
	}

	END {
		# 错误优先级：括号不匹配 > 块存在性
		if (invalid_config || stack_idx != 0) {
			if (stack_idx > 0) {
				current_block = stack[stack_idx]
				if (current_block == "http") {
					print "[ERROR] http块未闭合" > "/dev/stderr"
				} else if (current_block == "server") {
					print "[ERROR] server块未闭合" > "/dev/stderr"
				} else {
					printf "[ERROR] %s块未闭合\n", current_block > "/dev/stderr"
				}
			}
			print 3
			exit
		}

		# 有效配置判断
		if (has_http && has_server)	{ print 0 }		# 完整配置
		else if (has_http)			{ print 2 }		# 仅有http块
		else if (has_server)		{ print 3 }		# server块不在http内
		else						{ print 4 }		# 无有效块
	}
	' "$conf_file")
	
	# 捕获awk错误状态
	local awk_exit=$?
	
	# 错误处理
	if [ $awk_exit -ne 0 ]; then
		echo "[ERROR] awk处理配置文件失败(退出码: $awk_exit)"
		return 1
	fi
	
	case $status_code in
		0)
			echo "[INFO] 配置文件完整且有效"
			;;
		2)
			echo "[WARNING] 配置文件中仅有http块，未包含server块"
			;;
		3)
			echo "[WARNING] 配置文件中server块未包含在http块内"
			;;
		4)
			echo "[ERROR] 配置文件无效，未包含有效的http或server块"
			;;
		*)
			echo "[ERROR] 未知错误"
			;;
	esac

	return $status_code
}

# 修改 nginx location块
modify_nginx_location()
{
	local conf_file="$1"
	local location_path="$2"
	local reference_content="$3"
	local new_content="$4"
	local comment_reference="${5:-true}"
	
	# 验证参数
	if [[ -z "$conf_file" || -z "$location_path" || -z "$reference_content" || -z "$new_content" ]]; then
		echo "[ERROR] 必要参数不能为空,请检查!"
		return 1
	fi
	
	# 检查配置文件
	if [[ ! -f "$conf_file" ]]; then
		echo "[ERROR] 配置文件不存在,请检查!"
		return 1
	fi
	
	local awk_cmd
	if command -v gawk &>/dev/null; then
		awk_cmd="gawk"
	elif command -v awk &>/dev/null; then
		awk_cmd="awk"
	else
		echo "[ERROR] awk命令不存在，请检查系统环境！"
		return 1
	fi
	
	# 创建备份文件
	local backup_file="${conf_file}.bak"
	if ! cp "$conf_file" "$backup_file"; then
		 echo "[ERROR] 创建备份文件失败: $backup_file"
		 return 1
	fi
	
	# 创建临时文件
	local temp_file
	temp_file=$(mktemp)
	
	# awk 处理配置文件
	$awk_cmd -v loc_path="$location_path" \
		-v ref_cont="$reference_content" \
		-v new_cont="$new_content" \
		-v comment_ref="$comment_reference" \
	'
	function trim_line(line) {
		# 移除首尾空格
		sub(/^[[:space:]]+/, "", line)
		sub(/[[:space:]]+$/, "", line)
		
		# 移除行尾注释但保留分号
		sub(/[[:space:]]*#.*$/, "", line)
		sub(/;[[:space:]]*$/, ";", line)
		return line
	}
	
	# 获取行首缩进
	function get_indent(line) {
		match(line, /^[[:space:]]*/)
		return substr(line, 1, RLENGTH)
	}
	
	BEGIN {
		in_server = 0				# 是否在 server 块中
		in_target_location = 0		# 是否在目标 location 块中
		server_brace_depth = 0		# server 块花括号深度
		location_brace_depth = 0	# location 块花括号深度
		
		# 多行匹配状态
		match_index = 1
		
		# 分割参考内容
		ref_count = split(ref_cont, ref_lines, "\n")
	}
	
	# 检测 server 块开始
	/^[[:space:]]*server[[:space:]]*\{/ {
		in_server = 1
		server_brace_depth = 1
	}
	
	# 在 server 块中
	in_server && !in_target_location {
		# 更新花括号深度
		if (/{/) server_brace_depth++
		if (/}/) server_brace_depth--
		
		# 检测 server 块结束
		if (server_brace_depth == 0) {
			in_server = 0
			print
			next
		}
		
		# 检测目标 location 块
		#if ($0 ~ "location[[:space:]]+" loc_path "[[:space:]]*\{") {
		if ($0 ~ "location[[:space:]]+" loc_path "[[:space:]]*\\{") {
			in_target_location = 1
			location_brace_depth = 1
		}
	}
	
	# 在目标location块中
	in_target_location {
		# 更新 location 花括号深度
		if (/{/) location_brace_depth++
		if (/}/) location_brace_depth--
		
		# 检测location块结束
		if (location_brace_depth == 0) {
			in_target_location = 0
			print
			next
		}
		
		# 尝试匹配参考内容
		if (match_index <= ref_count) {
			current_line=$0
			current_trim=trim_line(current_line)
			
			if (current_trim == trim_line(ref_lines[match_index])) {
				# 存储原始行
				original_lines[match_index] = current_line
				match_index++
				
				# 全部匹配成功
				if (match_index > ref_count) {
					# 注释原始内容
					if (comment_ref == "true") {
						for (i = 1; i <= ref_count; i++) {
							line = original_lines[i]
							indent = get_indent(line)
							print indent "#" substr(line, length(indent) + 1)
						}
					}
					
					# 添加新内容
					split(new_cont, new_lines, "\n")
					for (i = 1; i <= length(new_lines); i++) {
						print indent new_lines[i]
					}
					
					# 重置状态
					match_index = 1
					next
				} else {
					next
				}
			} else {
				# 匹配失败时恢复已匹配行
				for (i = 1; i < match_index; i++) {
					print original_lines[i]
				}
				match_index = 1
			}
		}
		
		print
		next
	}
	
	# 打印其他行
	{ print }
	' "$conf_file" > "$temp_file" 2>&1
	
	# 捕获awk错误状态
	local awk_exit=$?
	
	# 错误处理
	if [ $awk_exit -ne 0 ]; then
		echo "[ERROR] awk处理配置文件失败(退出码: $awk_exit)"
		
		echo "=== awk错误输出 ==="
		cat "$temp_file"
		echo "=================="
		
		# 恢复备份
		if cp "$backup_file" "$conf_file"; then
			echo "[INFO] 备份恢复配置文件: $backup_file -> $conf_file"
		else
			echo "[WARNING] 恢复备份失败! 请手动恢复: $backup_file"
		fi

		rm "$temp_file"
		return 1
	fi
	
	if ! cp "$temp_file" "$conf_file"; then
		echo "[ERROR] 配置文件替换失败，恢复备份!"
		
		cp "$backup_file" "$conf_file"
		rm "$temp_file"
		
		return 1
	fi

	rm "$temp_file"
	echo "[INFO] 配置文件修改成功! $conf_file"
	
	return 0
}