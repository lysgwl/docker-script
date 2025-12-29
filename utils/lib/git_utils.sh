#!/bin/bash
# Git工具模块

if [[ -n "${GIT_UTILS_LOADED:-}" ]]; then
	return 0
fi
export GIT_UTILS_LOADED=1

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