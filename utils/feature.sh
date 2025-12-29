#!/bin/bash

# 版本信息
UTILS_VERSION="1.0.2025.12.25"

# 获取模块路径
UTILS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${UTILS_ROOT}/lib"

# 模块加载状态
declare -A LOADED_MODULES=()

# 模块依赖关系
declare -A MODULE_DEPEND=(
	["download_utils"]="archive_utils github_utils"
	["git_utils"]="github_utils"
)

# 版本查询
utils_version()
{
	echo "v${UTILS_VERSION}"
}

# 导出函数
_export_functions()
{
	local before_funcs="$1"
	local after_funcs="$2"
	local export="${3:-1}"
	
	[[ "$export" -ne 1 ]] && return 0
	
	# 获取新增的函数
	local new_funcs
	new_funcs=$(comm -13 <(echo "$before_funcs" | sort) <(echo "$after_funcs" | sort))
	
	echo "[DEBUG] 需要导出的函数: $new_funcs" >&2
	
	# 导出每个函数
	while IFS= read -r func_name; do
		[[ -z "$func_name" ]] && continue
		
		echo "[DEBUG] 检查函数: $func_name" >&2
		
		if declare -f "$func_name" >/dev/null 2>&1; then
			echo "[DEBUG] 导出函数: $func_name" >&2
			export -f "$func_name"
		else
			echo "[WARNING] 函数 $func_name 未定义，无法导出" >&2
		fi
	done <<< "$new_funcs"
}

# 加载单个模块
_load_module()
{
	local module_name="$1"
	local export="${2:-1}"
	
	printf "[DEBUG] _load_module开始: name=%s, export=%s, LOADED状态=%s\n" \
		"$module_name" "$export" "${LOADED_MODULES[$module_name]:-未加载}" >&2
	
	[[ ${LOADED_MODULES[$module_name]+_} ]] && {
		printf "[DEBUG] _load_module跳过: name=%s, 已加载\n" "$module_name" >&2
		return 0
	}
	
	# 加载依赖
	local deps="${MODULE_DEPEND[$module_name]:-}"
	printf "[DEBUG] 模块 %s 的依赖: %s\n" "$module_name" "$deps" >&2
	
	for dep in $deps; do
		_load_module "$dep" "$export"
	done
	
	local module_file="${LIB_DIR}/${module_name}.sh"
	if [[ ! -f "$module_file" ]]; then
		echo "[ERROR] 模块不存在: $module_file" >&2
		return 1
	fi
	
	# 获取加载前的函数
	local before_funcs=$(declare -F | awk '{print $3}' | grep -v "^_")
	
	# 加载模块
	source "$module_file" || {
		echo "[ERROR] 加载模块失败: $module_name" >&2
		return 2
	}
	
	# 获取加载后的函数
	local after_funcs=$(declare -F | awk '{print $3}' | grep -v "^_")
	
	# 导出函数
	_export_functions "$before_funcs" "$after_funcs" "$export"
	
	# 标记为已加载
	LOADED_MODULES["$module_name"]=1
	return 0
}

# 加载模块
load_feature()
{
	local export="${1:-1}"	# (1=导出, 0=不导出)
	shift
	
	echo "[DEBUG] load_feature开始: export=$export, 参数=$@" >&2
	echo "[DEBUG] LOADED_MODULES状态: ${!LOADED_MODULES[@]}" >&2
	echo "[DEBUG] UTILS_MODULE_LOADED=${UTILS_MODULE_LOADED:-未设置}" >&2
	echo "[DEBUG] 当前进程: $$" >&2
	
	if [[ $# -eq 0 ]]; then
		echo "[DEBUG] 加载所有模块，LIB_DIR=$LIB_DIR" >&2
		
		local module_count=0
		for module in "${LIB_DIR}"/*.sh; do
			local name=$(basename "$module" .sh)
			echo "[DEBUG] 找到模块文件: $name" >&2
			module_count=$((module_count + 1))
		done
		
		echo "[DEBUG] 总共找到 $module_count 个模块文件" >&2
		
		for module in "${LIB_DIR}"/*.sh; do
			local name=$(basename "$module" .sh)
			_load_module "$name" "$export"
		done
	else
		echo "[DEBUG] 加载指定模块: $@" >&2
		
		for module in "$@"; do
			[[ "$module" != *_utils ]] && module="${module}_utils"
			_load_module "$module" "$export"
		done
	fi
}

# 优先加载日志模块
_load_module "log_utils"

# 导出函数
export -f utils_version load_feature

# 导出模块目录路径
export UTILS_ROOT LIB_DIR