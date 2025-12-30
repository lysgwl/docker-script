#!/bin/bash
# 压缩包处理工具模块

if [[ -n "${ARCHIVE_UTILS_LOADED:-}" ]]; then
	return 0
fi
export ARCHIVE_UTILS_LOADED=1

# 解析文件扩展名
get_file_extension()
{
	local filename="$1"
	
	# 优先匹配常见压缩格式扩展名
	local extension=$(echo "$filename" | grep -oE '\.tar\.(gz|xz|bz2|lzma|Z)$|\.tar$|\.tgz$|\.tbz2$|\.zip$|\.gz$|\.xz$|\.bz2$')
	
	# 如果优先匹配没有找到
	if [[ -z "$extension" && "$filename" =~ \.[^./]*$  ]]; then
		extension="${BASH_REMATCH[0]}"
		
		# 避免把纯数字当作扩展名
		if [[ "$extension" =~ ^\.[0-9]+$ ]]; then
			extension=""
		fi
	fi

: <<'COMMENT_BLOCK'
	if [[ "$filename" =~ ^(.*)\.([^.]+)\.([^.]+)$ ]]; then
		# 处理复合扩展名（如 .tar.gz）
		extension=".${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
	else
		# 处理单扩展名或无扩展名
		extension="${filename##*.}"
		# 确保扩展名以点开头
		if [ "$extension" = "$filename" ]; then
			extension=""  # 没有扩展名
		else
			extension=".$extension"
		fi
	fi
COMMENT_BLOCK
	
	# 确保扩展名不为null
	echo "${extension:-}"
}

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
		local name="$filename"
		
		[[ -f "$filepath" ]] && filetype="file"
		[[ -d "$filepath" ]] && filetype="directory"
		
		local suffix="" base_name=""
		if [[ "$filename" =~ \.([[:alpha:]]{3,})\.([[:alpha:]]{2,3})$ ]]; then
			# 匹配两段式后缀（如 .tar.gz）
			suffix=".${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			base_name="${filename%$suffix}"
			name="$base_name"
		elif [[ "$filename" =~ \.([[:alpha:]]{2,})$ ]]; then
			# 匹配单一段式后缀（如 .gz）
			suffix=".${BASH_REMATCH[1]}"
			base_name="${filename%$suffix}"
			name="$base_name"
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