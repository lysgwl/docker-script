#!/bin/bash
# 日志工具模块

if [[ -n "${LOG_UTILS_LOADED:-}" ]]; then
	return 0
fi
export LOG_UTILS_LOADED=1

# 日志级别比较
diff_log_level()
{
	local current_level="$1"
	local configured_level="$2"
	
	_log_level_value() {
		local level="${1^^}"   # 转为大写
		
		case "$level" in
			TRACE)   echo 0 ;;
			DEBUG)   echo 1 ;;
			INFO)    echo 2 ;;
			WARNING) echo 3 ;;
			ERROR)   echo 4 ;;
			NONE)    echo 99 ;;
			SECTION|HEADER|DIVIDER) echo -1 ;;   # 特殊格式
			*)       echo 2 ;;   # 默认 INFO
		esac
	}
	
	local current_value=$(_log_level_value "$current_level")
	local configured_value=$(_log_level_value "$configured_level")
	
	# 特殊格式日志
	if [[ $current_value -lt 0 ]]; then
		return 0
	fi
	
	# 当前级别数值 >= 配置级别数值时记录
	if [[ $current_value -ge $configured_value ]]; then
		return 0
	else
		return 1
	fi
}

# 控制台日志
_console_log()
{
	local log_level="$1"
	local message="$2"
	local func_type="$3"
	local timestamp="$4"
	
	# 初始化颜色变量
	local log_time=""
	local log_level_color=""
	local log_func=""
	local log_message=""
	
	# 时间戳格式
	if [ -n "$timestamp" ]; then
		log_time="\x1b[38;5;208m[${timestamp}]\x1b[0m"
	fi
	
	# 日志级别颜色设置
	case "$log_level" in
		"TRACE")
			log_level_color="\x1b[38;5;76m[TRACE]:\x1b[0m"
			;;
		"DEBUG")
			log_level_color="\x1b[38;5;208m[DEBUG]:\x1b[0m"
			;;
		"WARNING")
			log_level_color="\033[1;43;31m[WARNING]:\x1b[0m"
			;;
		"INFO")
			log_level_color="\x1b[38;5;76m[INFO]:\x1b[0m"
			;;
		"ERROR")
			log_level_color="\x1b[38;5;196m[ERROR]:\x1b[0m"
			;;
		"SECTION")
			log_level_color="\x1b[38;5;51m[SECTION]:\x1b[0m"
			;;
		"HEADER")
			log_level_color="\x1b[38;5;213m[HEADER]:\x1b[0m"
			;;
		"DIVIDER")
			log_level_color="\x1b[38;5;245m[DIVIDER]:\x1b[0m"
			;;
		*)
			log_level_color="\x1b[38;5;87m[${log_level}]:\x1b[0m"
			;;
	esac
	
	# 功能名称
	if [ -n "$func_type" ]; then
		log_func="\x1b[38;5;210m(${func_type})\x1b[0m"
	fi
	
	# 消息内容
	if [ -n "$message" ]; then
		log_message="\x1b[38;5;87m${message}\x1b[0m"
	else
		log_message="\x1b[38;5;87m(No message)\x1b[0m"
	fi
	
	# 构建输出字符串
	local output=""
	[ -n "$log_time" ] && output="${output}${log_time} "
	output="${output}${log_level_color}"
	[ -n "$log_func" ] && output="${output} ${log_func}"
	output="${output} ${log_message}"
	
	printf "${output}\n"
}

# 文件日志输出
_file_log()
{
	local log_level="$1"
	local message="$2"
	local timestamp="$3"
	local log_file="$4"
	
	if [ -z "$log_file" ]; then
		echo "[ERROR] 设置的输出日志文件无效, 请检查!"
		return 1
	fi
	
	# 创建日志目录
	local log_dir=$(dirname "$log_file")
	if [ ! -d "$log_dir" ]; then
		mkdir -p "$log_dir" 2>/dev/null || {
			echo "[ERROR] 创建的日志目录失败, 请检查!"
			return 2
		}
	fi
	
	case "$log_level" in
		"INFO"|"WARNING"|"ERROR"|"TRACE"|"DEBUG")
			echo "[$log_level] $timestamp $message" >> "$log_file"
			;;
		"SECTION")
			echo "=== $message ===" >> "$log_file"
			;;
		"HEADER")
			echo "================= $message =================" >> "$log_file"
			;;
		"DIVIDER")
			echo "------------------------------------------------------------" >> "$log_file"
			;;
		*)
			echo "[$log_level] $timestamp $message" >> "$log_file"
			;;
	esac
}

# 打印日志
print_log()
{
	# 参数验证
	if [ "$#" -lt 2 ] || [ -z "$1" ]; then
		echo "Usage: print_log <log_level> <message> [output_type] [func_type] [log_file]"
		return 1
	fi
	
	local log_level="$1"
	local message="$2"
	local output_type="${3:-console}"
	local func_type="${4:-}"
	local log_file="${5:-}"
	
	# 输入参数验证
	if [ -z "$log_level" ] || [ -z "$message" ]; then
		return 1
	fi
	
	# 检查日志级别
	if ! diff_log_level "$log_level" "$LOG_LEVEL"; then
		return 0
	fi
	
	local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
	
	# 调度处理函数
	case "$output_type" in
		"console")
			_console_log "$log_level" "$message" "$func_type" "$timestamp"
			;;
		"file")
			_file_log "$log_level" "$message" "$timestamp" "$log_file"
			;;
		"both")
			_console_log "$log_level" "$message" "$func_type" "$timestamp"
			_file_log "$log_level" "$message" "$timestamp" "$log_file"
			;;
		*)
			echo "[ERROR] 无效的输出类型, 请检查!" >&2
			return 1
			;;
	esac
}