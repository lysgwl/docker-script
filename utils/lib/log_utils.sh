#!/bin/bash
# 日志工具模块

if [[ -n "${LOG_UTILS_LOADED:-}" ]]; then
	return 0
fi
export LOG_UTILS_LOADED=1

# 日志函数配置
: "${UTILS_LOG_FUNC:=print_log}"
: "${LOG_LEVEL:=INFO}"

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

# 获取日志级别
_log_level_value()
{
	local level="${1^^}"
	
	# 允许直接传数字
	if [[ "$level" =~ ^-?[0-9]+$ ]]; then
		printf '%d\n' "$level"
		return 0
	fi
	
	# 特殊格式
	if [[ "$level" =~ ^($SPECIAL_LEVELS)$ ]]; then
		# 特殊格式返回 -1，表示总是输出
		printf '%d\n' -1
		return 0
	fi
	
	# 常规日志级别
	case "$level" in
		"TRACE")	printf '%d\n' 0 ;;		# 详细的调试信息
		"DEBUG")	printf '%d\n' 1 ;;		# 调试信息
		"INFO")		printf '%d\n' 2 ;;		# 常规操作信息
		"NOTICE")	printf '%d\n' 3 ;;		# 重要通知信息
		"WARNING")	printf '%d\n' 4 ;;		# 警告信息
		"ERROR")	printf '%d\n' 5 ;;		# 错误信息
		"FATAL")	printf '%d\n' 6 ;;		# 致命错误
		"NONE")		printf '%d\n' 99 ;;		# 不记录任何日志
		*)			printf '%d\n' 2 ;;
	esac
}

# 日志级别比较
_diff_log_level()
{
	local current_level="${1^^}"
	local configured_level="${LOG_LEVEL:-INFO}"
	
	# 转为大写
	configured_level="${configured_level^^}"
	
	# 特殊格式 (总是输出)
	#[[ "$current_level" =~ ^($SPECIAL_LEVELS)$ ]] && return 0
	
	# 获取级别数值
	local current_value=$(_log_level_value "$current_level")
	local configured_value=$(_log_level_value "$configured_level")
	
	# 特殊格式 (总是输出)
	[[ "$current_value" -eq -1 ]] && return 0
	
	# NONE级别 (无需输出)
	[[ "$configured_value" -eq 99 ]] && return 1
	
	#echo "test1 $current_level - $configured_level"
	#echo "test2 $current_value - $configured_value"
	
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
	local time_color="\x1b[38;5;208m"		# 橙色
	local func_color="\x1b[38;5;210m"		# 浅橙色
	local msg_color="\x1b[38;5;87m"			# 青色
	
	local level_color
	case "$log_level" in
		"TRACE")			level_color="\x1b[38;5;246m" ;;		# 灰色
		"DEBUG")			level_color="\x1b[38;5;208m" ;;		# 橙色
		"INFO")				level_color="\x1b[38;5;76m"  ;;		# 绿色
		"NOTICE")			level_color="\x1b[38;5;39m"  ;;		# 蓝色
		"WARNING")			level_color="\033[1;43;31m" ;;		# 黄色加粗
		"ERROR")			level_color="\x1b[38;5;196m" ;;		# 红色
		"FATAL")			level_color="\x1b[1;37;41m"  ;;		# 白字红底加粗
		*)					level_color="\x1b[38;5;87m" ;;		# 青色
	esac
	
	# 终端输出
	local output
	[[ -n "$timestamp" ]] && output="${time_color}[$timestamp]$reset"
	output+="${level_color}[$log_level]$reset"
	[[ -n "$func_type" ]] && output+=" ${func_color}($func_type)$reset"
	output+="${msg_color}${message:-No message}$reset"
	
	# 根据级别选择输出流
	case "$log_level" in
		"ERROR"|"FATAL"|"WARNING")	printf '%b\n' "$output" >&2 ;;	# 错误类输出到stderr
		*)	printf '%b\n' "$output" ;; 		# 其他输出到stdout
	esac
	
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
	if ! _diff_log_level "$log_level"; then
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

export -f _diff_log_level _log_level_value _write_log _format_log