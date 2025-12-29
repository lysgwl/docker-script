#!/bin/bash
# GitHub API工具模块

if [[ -n "${GITHUB_UTILS_LOADED:-}" ]]; then
	return 0
fi
export GITHUB_UTILS_LOADED=1

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