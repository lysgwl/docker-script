#!/bin/bash
# 日志工具模块

if [[ -n "${LOG_UTILS_LOADED:-}" ]]; then
	return 0
fi
export LOG_UTILS_LOADED=1

# 日志级别定义
declare -A LOG_LEVEL_VALUES=(
	["TRACE"]=0		# 最详细的调试信息
	["DEBUG"]=1		# 调试信息
	["INFO"]=2		# 常规操作信息
	["WARNING"]=3	# 警告信息
	["ERROR"]=4		# 错误信息
	["NONE"]=99		# 不记录任何日志
)

# 日志函数配置
: "${UTILS_LOG_FUNC:=print_log}"

# 特殊日志级别
export SPECIAL_LEVELS="TITLE|SECTION|HEADER|SUBTITLE|DIVIDER|BLANK|TEXT"

# 日志调用接口
utils_log() 
{
	if declare -f "$UTILS_LOG_FUNC" >/dev/null; then
		"$UTILS_LOG_FUNC" "$@"
	else
		print_log "$@"
	fi
}

# 日志级别比较
diff_log_level()
{
	local current_level="${1^^}"
	local configured_level="${LOG_LEVEL:-INFO}"
	
	# 转为大写
	configured_level="${configured_level^^}"
	
	# 特殊格式日志总是输出
	[[ "$current_level" =~ ^($SPECIAL_LEVELS)$ ]] && return 0
	
	local current_value="${LOG_LEVEL_VALUES[$current_level]:-2}"
	local configured_value="${LOG_LEVEL_VALUES[$configured_level]:-2}"
	
	# 当前级别数值 >= 配置级别数值时记录
	[[ $current_value -ge $configured_value ]]
}

# 日志输出
_write_log()
{
	local log_level="$1"
	local message="$2"
	local func_type="$3"
	local timestamp="$4"
	local log_file="$5"
	
	# 默认时间
	[[ -z "$timestamp" ]] && timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	
	# 文本日志
	local log_entry="[$timestamp] [$log_level]"
	[[ -n "$func_type" ]] && log_entry+=" ($func_type)"
	log_entry+="${message:-No message}"
	
	# 颜色定义
	local reset="\x1b[0m"
	local time_color="\x1b[38;5;208m"
	local func_color="\x1b[38;5;210m"
	local msg_color="\x1b[38;5;87m"
	
	local level_color
	case "$log_level" in
		"TRACE"|"INFO")   level_color="\x1b[38;5;76m" ;;
		"DEBUG")          level_color="\x1b[38;5;208m" ;;
		"WARNING")        level_color="\033[1;43;31m" ;;
		"ERROR")          level_color="\x1b[38;5;196m" ;;
		"SECTION")        level_color="\x1b[38;5;51m" ;;
		"HEADER")         level_color="\x1b[38;5;213m" ;;
		"DIVIDER")        level_color="\x1b[38;5;245m" ;;
		*)                level_color="\x1b[38;5;87m" ;;
	esac
	
	# 终端输出
	local output
	[[ -n "$timestamp" ]] && output="${time_color}[$timestamp]$reset"
	output+="${level_color}[$log_level]$reset"
	[[ -n "$func_type" ]] && output+=" ${func_color}($func_type)$reset"
	output+="${msg_color}${message:-No message}$reset"
	
	printf '%b\n' "$output"
	
	# 文件输出
	if [[ -n "$log_file" ]]; then
		printf '%s\n' "$log_entry" >> "$log_file" 2>/dev/null || true
	fi
}

# 格式输出
_format_log()
{
	local log_level="$1"
	local message="$2"
	local log_file="$3"
	
	# 构建日志条目
	local log_entry=""
	
	case "$log_level" in
		"TITLE")	# 程序/模块边界
			log_entry="******************************************"
			;;
		"SECTION")	# 主要章节模块开始
			log_entry="===== $message ====="
			;;
		"HEADER")	# 重要标题/功能模块
			log_entry="================= $message ================="
			;;
		"SUBTITLE")	# 子标题/次级功能
			log_entry="---------- $message ----------"
			;;
		"DIVIDER")	# 内容分隔线
			log_entry="------------------------------------------------------------"
			;;
		"BLANK")	# 空白行
			log_entry=""
			;;
		"TEXT")
			log_entry="$message"
			;;
		*)
			log_entry="$message"
			;;
	esac
	
	# 终端输出
	printf '%s\n' "$log_entry"
	
	# 文件输出
	if [[ -n "$log_file" ]]; then
		printf '%s\n' "$log_entry" >> "$log_file" 2>/dev/null || true
	fi
}

# 打印日志
print_log()
{
	# 参数验证
	if [ "$#" -lt 2 ] || [ -z "$1" ]; then
		echo "Usage: print_log <log_level> <message> [func_type] [log_file]"
		return 1
	fi
	
	local log_level="$1"
	local message="$2"
	local func_type="${3:-}"
	local log_file="${4:-}"
	
	# 输入参数验证
	if [ -z "$log_level" ]; then
		return 1
	fi
	
	# 检查日志级别
	if ! diff_log_level "$log_level"; then
		return 0
	fi
	
	# 判断是否为特殊格式
	if [[ "$log_level" =~ ^($SPECIAL_LEVELS)$ ]]; then
		_format_log "$log_level" "$message" "$log_file"
	else
		local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
		_write_log "$log_level" "$message" "$func_type" "$timestamp" "$log_file"
	fi
}

print_title()
{
	local log_file="${1:-}"
	print_log "TITLE" "" "" "$log_file"
}

print_section()
{
	local message="$1" log_file="${2:-}"
	print_log "SECTION" "$message" "" "$log_file"
}

print_header()
{
	local message="$1" log_file="${2:-}"
	print_log "HEADER" "$message" "" "$log_file"
}

print_subtitle()
{
	local message="$1" log_file="${2:-}"
	print_log "SUBTITLE" "$message" "" "$log_file"
}

print_divider() 
{
	local log_file="${1:-}"
	print_log "DIVIDER" "" "" "$log_file"
}

export -f _write_log _format_log