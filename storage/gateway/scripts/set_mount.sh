#!/bin/bash

# 定义挂载配置数组
declare -A mount_config=(
	["config_file"]="${CONFIG_FILE:-}"
	["builtin_cfg"]="true"
	["remote_timeout"]=5
	["check_interval"]=60
	["mount_dir"]="${MOUNT_DIR:-/mnt}"
	["log_file"]="${LOG_FILE:-/var/log/mount.log}"
	["pid_file"]="/var/run/mount.pid"
	["script_name"]="set_mount"
	["script_path"]=""
)

# 内置挂载配置
MOUNT_PAIRS=(
	"/mnt/nas_share/files:192.168.2.15:nfs:files:/volume1/files:/app/data/config/smb/nas.cred"
	#"/mnt/nas_share/project:192.168.2.15:nfs:project:/volume1/project:"
	#"/mnt/nas_share/media:192.168.2.15:nfs:media:/volume1/media:"
)

# 日志封装
if ! declare -f print_log >/dev/null 2>&1; then
	diff_log_level() {
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
	
	print_log() {
		local log_level="$1"
		local message="$2"
		local output_type="${3:-console}"
		local func_type="${4:-}"
		local log_file="${5:-}"
		
		if ! diff_log_level "$log_level" "$LOG_LEVEL"; then
			return 0
		fi
		
		local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
		
		local prefix=""
		[[ -n "$func_type" ]] && prefix="[$func_type] "
		
		local log_entry="[$timestamp] [$log_level] ${prefix}$message"
		echo "$log_entry"
	}
fi

# 检查挂载状态
check_mount()
{
	local mount_point="$1"
	local config="${2:-}"
	
	if [[ -n "$config" ]]; then
		local mount_method=$(echo "$config" | jq -r '.mount_method // "script"')
		
		if [[ "$mount_method" = "docker" ]]; then
			local volume_name=$(echo "$config" | jq -r '.volume_name // ""')
			[[ -n "$volume_name" ]] && docker volume inspect "$volume_name" >/dev/null 2>&1 || return 1
			
			return 0
		else
			local local_path=$(get_mount_path "$config")
			mount_point="$local_path"
		fi
	fi
	
	[[ -z "$mount_point" || "$mount_point" != /* ]] && return 1
	
	if command -v mountpoint &>/dev/null; then
		mountpoint -q "$mount_point" 2>/dev/null || return 1
	else
		awk -v dir="$mount_point" '$2 == dir {exit 0} END {exit 1}' /proc/mounts || return 1
	fi
	
	return 0
}

# 检查配置文件
check_config()
{
	print_log "INFO" "检查挂载配置文件"
	
	if [ -n "${mount_config[config_file]}" ] && [ -f "${mount_config[config_file]}" ]; then
		if ! jq empty "${mount_config[config_file]}" 2>/dev/null; then
			print_log "ERROR" "配置文件格式有误: ${mount_config[config_file]}"
			return 1
		fi
		
		mount_config["builtin_cfg"]="false"
		print_log "INFO" "使用外置挂载配置: ${mount_config[config_file]}"
	else
		mount_config["builtin_cfg"]="true"
		print_log "INFO" "使用内置挂载配置"
	fi
	
	print_log "INFO" "配置文件检查通过"
	return 0
}

# 检测进程运行
check_process()
{
	local operation="$1"
	local script_path="${2:-}"
	local target_pid="${3:-}"
	local timeout="${4:-10}"
	
	case "$operation" in
		check)
			[[ -z "$script_path" ]] && return 1
			
			# 精确匹配完整的命令行
			local script_name=$(basename "$script_path")
			local pids=$(pgrep -f "start --monitor" 2>/dev/null || true)
			
			[[ -z "$pids" ]] && return 1
			
			for pid in $pids; do
				# 排除当前进程
				[[ "$pid" = "$$" ]] && continue
				
				# 获取进程的完整命令行
				local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
				local state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ' || true)
				
				# 精确匹配并排除僵尸进程
				if echo "$cmdline" | grep -q "$script_name.*start --monitor" && [[ "$state" != "Z" ]]; then
					echo "$pid"
					return 0
				fi
			done
			
			return 1  # 未找到有效进程
			;;
		verify)
			# 验证进程启动
			[[ -z "$target_pid" ]] && return 1
			
			# 等待进程启动并验证
			local wait_for_time=0
			while ! kill -0 "$target_pid" 2>/dev/null; do
				sleep 1
				
				((wait_for_time++))
				[[ $wait_for_time -ge $timeout ]] && return 1
			done
			
			# 额外检查进程状态
			local state=$(ps -o state= -p "$target_pid" 2>/dev/null | tr -d ' ' || true)
			[[ "$state" = "Z" ]] && return 1
			
			return 0
			;;
		*)
			return 2
			;;
	esac
}

# 检查远端存储
check_storage()
{
	local config="$1"
	local timeout=${mount_config[remote_timeout]}
	
	local server=$(echo "$config" | jq -r '.server')
	local protocol=$(echo "$config" | jq -r '.type')
	local remote_path=$(echo "$config" | jq -r '.remote_path')
	local credentials=$(echo "$config" | jq -r '.credentials // ""')
	
	if [[ -z "$server" || -z "$protocol" || -z "$remote_path" ]]; then
		return 1
	fi
	
	case "$protocol" in
		nfs)
			print_log "DEBUG" "检查NFS服务: $server:$remote_path"
			
			# 检查NFS服务是否可用
			{ timeout "$timeout" nc -z -w 1 "$server" 2049 || \
			  timeout "$timeout" rpcinfo -t "$server" 100003 || \
			  timeout "$timeout" rpcinfo -t "$server" nfs; } >/dev/null 2>&1 || {
				print_log "ERROR" "NFS服务不可达: $server, 请检查!"
				return 2
			}
			
			# 验证导出路径存在
			timeout "$timeout" showmount -e "$server" 2>/dev/null | grep -q "$remote_path" || {
				print_log "ERROR" "NFS导出路径不存在: $remote_path, 请检查!"
				return 3
			}
			;;
		smb)
			print_log "DEBUG" "检查SMB服务: //$server/$remote_path"
			
			# 检测SMB服务是否可用
			{ timeout "$timeout" ping -c 1 -W 1 "$server" || \
			  timeout "$timeout" nc -z -w 1 "$server" 445; } >/dev/null 2>&1 || {
				print_log "ERROR" "SMB服务不可达: $server, 请检查!"
				return 2
			}
			
			# 验证共享路径
			if command -v smbclient &>/dev/null; then
				# 默认匿名访问
				local auth_params="-N"
				
				if [[ -n "$credentials" && -f "$credentials" ]]; then
					auth_params="-A '$credentials'"
				fi
				
				# 构建smbclient命令
				local smb_cmd="smbclient $auth_params -L '$server'"
				
				if ! eval "timeout '$timeout' $smb_cmd 2>/dev/null" | grep -q "$remote_path"; then
					print_log "ERROR" "SMB共享路径不存在: $remote_path, 请检查!"
					return 3
				fi
			fi
			;;
		local)
			print_log "DEBUG" "检查本地存储: $remote_path"
			
			# 对本地存储的检查
			if [[ ! -e "$remote_path" ]]; then
				print_log "ERROR" "本地存储路径不存在: $remote_path, 请检查!"
				return 3
			fi
			;;
		*)
			print_log "ERROR" "不支持的协议: $protocol"
			return 1
			;;
	esac
	
	print_log "DEBUG" "存储检查通过: $server ($protocol)"
	return 0
}

# 解析内置配置项
parse_builtin_config()
{
	local config="$1"
	IFS=':' read -r mount_point server protocol share_name nfs_path credentials <<< "$config"
	
	cat << EOF
{
    "name": "$share_name",
    "type": "$protocol",
    "server": "$server",
    "remote_path": "$nfs_path",
    "local_path": "$mount_point",
    "credentials": "$credentials",
    "enabled": true,
    "required": true,
    "mount_method": "script"
}
EOF
}

# 加载挂载配置
load_mount_config()
{
	if [ "${mount_config[builtin_cfg]}" = "true" ]; then
		print_log "DEBUG" "加载内置挂载配置" >&2
		
		# 使用内置配置
		for config in "${MOUNT_PAIRS[@]}"; do	
			parse_builtin_config "$config" | jq -c .
		done
	else
		print_log "DEBUG" "加载外部挂载配置: ${mount_config[config_file]}" >&2
		
		# 使用JSON配置文件
		jq -c '.mounts[] | select(.enabled == true)' "${mount_config[config_file]}" 2>/dev/null
	fi
}

# 获取脚本绝对路径
get_script_path()
{
	local script_path="${1:-}"
	
	# 优先使用外部路径
	if [[ -n "$script_path" && -f "$script_path" ]]; then
		echo "$(realpath "$script_path")"
		return 0
	fi
	
	if [ -n "${BASH_SOURCE[0]}" ]; then
		script_path="$(realpath "${BASH_SOURCE[0]}")"
	elif [ -n "$0" ] && [ "$0" != "bash" ]; then
		script_path="$(realpath "$0")"
	fi
	
	echo "$script_path"
}

# 获取挂载路径
get_mount_path()
{
	local config="$1"
	
	if [ "${mount_config[builtin_cfg]}" = "true" ]; then
		# 内置配置：直接使用 local_path 绝对路径
		echo "$config" | jq -r '.local_path'
	else
		# 外部配置：基于 base_dir + local_path
		echo "${mount_config[mount_dir]}$(echo "$config" | jq -r '.local_path')"
	fi
}

# 设置挂载环境
set_mount_env()
{
	print_log "INFO" "设置挂载环境配置"
	
	# 创建基础目录
	print_log "DEBUG" "创建基础目录: ${mount_config[mount_dir]}"
	if ! mkdir -p "${mount_config[mount_dir]}" 2>/dev/null; then
		print_log "ERROR" "创建挂载目录失败: ${mount_config[mount_dir]}, 请检查!" 
		return 1
	fi
	
	# 创建挂载点目录
	if [ "${mount_config[builtin_cfg]}" = "false" ]; then
		while IFS= read -r config; do
			if [ -z "$config" ]; then
				continue
			fi
			
			local local_path=$(get_mount_path "$config")
			if ! mkdir -p "$local_path" 2>/dev/null; then
				print_log "WARNING" "创建挂载点目录失败: $local_path, 请检查!"
				
			else
				print_log "DEBUG" "创建挂载点目录: $local_path"
			fi
		done <<< "$(load_mount_config)"
	fi
	
	print_log "INFO" "挂载环境配置设置完成"
	return 0
}

# 脚本方式挂载
mount_with_script()
{
	local config="$1"
	
	local name=$(echo "$config" | jq -r '.name')
	local type=$(echo "$config" | jq -r '.type')
	local server=$(echo "$config" | jq -r '.server')
	local remote_path=$(echo "$config" | jq -r '.remote_path')
	local local_path=$(get_mount_path "$config")
	local options=$(echo "$config" | jq -r '.options // ""')
	
	print_log "INFO" "执行脚本挂载: $name"
	print_log "DEBUG" "本地路径: $local_path"
	print_log "DEBUG" "远程路径: $server:$remote_path"
	print_log "DEBUG" "协议类型: $type"
	
	# 检查是否已挂载
	if check_mount "$local_path"; then
		print_log "INFO" "挂载点已存在: $local_path, 请检查!"
		return 0
	fi
	
	# 创建本地目录
	print_log "DEBUG" "创建本地目录: $local_path"
	if ! mkdir -p "$local_path" 2>/dev/null; then
		print_log "ERROR" "创建本地目录失败: $local_path, 请检查!"
		return 1
	fi
	
	# 设置默认选项
	case "$type" in
		nfs)
			local default_options="rw,hard,intr,vers=3,timeo=100,retrans=2"
			[ -z "$options" ] && options="$default_options"
			
			# nolock 逻辑检测
			if { [[ -f /etc/alpine-release ]] || [[ -f /.dockerenv ]] || ! command -v rpc.statd >/dev/null 2>&1; } && [[ "$options" != *"nolock"* ]]; then
				options="${options},nolock"
				print_log "DEBUG" "添加 nolock 选项"
			fi
			
			print_log "DEBUG" "NFS挂载选项: $options"
			
			# 尝试挂载
			if ! mount -t nfs -o "$options" "$server:$remote_path" "$local_path" 2>/dev/null; then
				print_log "WARNING" "直接挂载失败，尝试挂载父目录"
				
				# 尝试挂载父目录
				local remote_parent_path=$(dirname "$remote_path")
				local local_parent_path="/tmp/nfs_parent_${name}_$(date +%s)"
				
				# 创建临时目录
				mkdir -p "$local_parent_path" 2>/dev/null || {
					print_log "ERROR" "创建临时目录失败, 请检查!"
					return 2
				}
				
				print_log "DEBUG" "尝试挂载父目录: $server:$remote_parent_path"
					
				# 挂载父目录
				if ! mount -t nfs -o "$options" "$server:$remote_parent_path" "$local_parent_path" 2>/dev/null; then
					print_log "ERROR" "父目录挂载失败, 请检查!"
					rm -rf "$local_parent_path" 2>/dev/null
					return 2
				fi
				
				# 检查子目录
				local subdir_name=$(basename "$remote_path")
				if [[ -d "$local_parent_path/$subdir_name" ]]; then
					print_log "DEBUG" "绑定挂载子目录: $subdir_name"
					
					# 绑定挂载将子目录映射到目标位置
					if ! mount --bind "$local_parent_path/$subdir_name" "$local_path" 2>/dev/null; then
						print_log "ERROR" "绑定挂载失败, 请检查!"
						
						umount "$local_parent_path" 2>/dev/null
						rmdir "$local_parent_path" 2>/dev/null
						return 3
					fi
				fi
				
				umount "$local_parent_path" 2>/dev/null
				rmdir "$local_parent_path" 2>/dev/null
				print_log "INFO" "通过父目录方式挂载成功"
			else
				print_log "INFO" "直接挂载成功"
			fi
			;;
		smb)
			local default_options="vers=3.0,guest,uid=0,gid=0,file_mode=0644,dir_mode=0755"
			[ -z "$options" ] && options="$default_options"
			
			# 处理凭证
			local credentials=$(echo "$config" | jq -r '.credentials // ""')
			if [ -n "$credentials" ] && [ -f "$credentials" ]; then
				options="${options},credentials=$credentials"
				print_log "DEBUG" "使用凭证文件: $credentials"
			else
				print_log "DEBUG" "使用匿名访问"
			fi
			
			print_log "DEBUG" "SMB挂载选项: $options"
			
			if ! mount -t cifs -o "$options" "//$server/$remote_path" "$local_path"; then
				print_log "ERROR" "SMB挂载失败, 请检查!"
				return 1
			fi
			
			print_log "INFO" "SMB挂载成功"
			;;
		*)
			print_log "ERROR" "不支持的挂载类型: $type"
			return 1
			;;
	esac
	
	print_log "INFO" "挂载完成: $local_path"
	return 0
}

# Docker方式挂载
mount_with_docker()
{
	local config="$1"
	
	# 内置配置不支持Docker挂载
	[[ "${mount_config[builtin_cfg]}" = "true" ]] && {
		print_log "WARNING" "内置配置不支持Docker挂载方式"
		return 1
	}
	
	print_log "INFO" "尝试Docker方式挂载"
	
	# 检查Docker环境
	if ! command -v docker >/dev/null 2>&1; then
		print_log "WARNING" "Docker命令不存在, 请检查!"
		return 1
	fi
	
	if ! docker info >/dev/null 2>&1; then
		print_log "WARNING" "Docker服务不可用, 请检查!"
		return 1
	fi
	
	# 提取配置参数
	local name=$(echo "$config" | jq -r '.name')
	local volume_name=$(echo "$config" | jq -r '.volume_name // ""')
	local driver=$(echo "$config" | jq -r '.docker_options.driver // "local"')
	local driver_opts=$(echo "$config" | jq -r '.docker_options.driver_opts // {}')

	print_log "DEBUG" "Docker卷名称: $volume_name"
	print_log "DEBUG" "驱动类型: $driver"
	
	# 验证必要参数
	[[ -z "$volume_name" ]] && {
		print_log "ERROR" "Docker卷名称未配置, 请检查!"
		return 1
	}
	
	# 创建或检查Docker卷
	if docker volume inspect "$volume_name" >/dev/null 2>&1; then
		print_log "INFO" "Docker卷已存在: $volume_name"
	else
		print_log "INFO" "创建Docker卷: $volume_name"
		local create_cmd="docker volume create --driver $driver --name $volume_name"
		
		# 添加驱动选项
		if [ "$driver_opts" != "{}" ]; then
			for key in $(echo "$driver_opts" | jq -r 'keys[]'); do
				local value=$(echo "$driver_opts" | jq -r --arg key "$key" '.[$key]')
				
				[[ -n "$value" ]] && create_cmd="$create_cmd --opt $key=$value"
			done
		fi
		
		print_log "DEBUG" "执行命令: $create_cmd"
		
		# 执行创建命令
		if ! eval "$create_cmd" >/dev/null 2>&1; then
			print_log "ERROR" "Docker卷创建失败: $volume_name"
			return 1
		fi
		
		print_log "INFO" "Docker卷创建成功: $volume_name"
	fi
	
	return  0
}

mount_storage()
{
	local config="$1"
	local method="${2:-auto}"
	
	local name=$(echo "$config" | jq -r '.name')
	print_log "INFO" "执行存储挂载: $name"
	
	if [ "${mount_config[builtin_cfg]}" = "true" ]; then
		# 内置配置只支持脚本挂载
		print_log "DEBUG" "使用脚本挂载方式(内置配置)"
		mount_with_script "$config"
	else
		local mount_method=$(echo "$config" | jq -r '.mount_method // "auto"')
		
		local final_method="$method"
		if [ "$method" = "auto" ]; then
			final_method="$mount_method"
		fi
		
		print_log "DEBUG" "挂载方式: $final_method"
		
		case "$final_method" in
			script)
				mount_with_script "$config"
				;;
			docker)
				 mount_with_docker "$config"
				;;
			auto)
				print_log "DEBUG" "尝试自动选择挂载方式"
				
				if ! mount_with_docker "$config"; then
					print_log "INFO" "Docker方式失败，尝试脚本方式"
					mount_with_script "$config"
				fi
				;;
			*)
				print_log "ERROR" "不支持的挂载方式: $final_method"
				return 1
				;;
		esac
	fi
	
	return $?
}

umount_storage()
{
	local config="$1"
	local local_path=$(get_mount_path "$config")
	local name=$(echo "$config" | jq -r '.name')
	
	print_log "INFO" "卸载存储: $name"
	print_log "DEBUG" "卸载路径: $local_path"

	if check_mount "$local_path"; then
		print_log "DEBUG" "执行卸载操作"
		
		if ! umount -l "$local_path" 2>/dev/null; then
			return 1
		fi
		
		print_log "INFO" "卸载成功: $local_path"
	else
		print_log "INFO" "挂载点不存在或未挂载: $local_path"
	fi
	
	return 0
}

process_mounts()
{
	local operation="$1"
	print_log "INFO" "处理挂载操作: $operation"
	
	while IFS= read -r config; do
		if [ -z "$config" ]; then
			continue
		fi
		
		if [ "$operation" = "mount" ]; then
			print_log "INFO" "挂载存储: $name"
			
			if ! mount_storage "$config"; then
				print_log "ERROR" "挂载失败: $name, 请检查!"
				return 1
			fi
		else
			print_log "INFO" "卸载存储: $name"
			
			if ! umount_storage "$config"; then
				print_log "ERROR" "卸载失败: $name, 请检查!"
				return 1
			fi
		fi
	done <<< "$(load_mount_config)"
	
	print_log "INFO" "所有挂载操作处理完成"
	return 0
}

# 监控循环
monitor_loop()
{
	local mode="${1:-monitor}"
	print_log "INFO" "进入监控循环模式: $mode"
	
	case "$mode" in
		mount)
			print_log "INFO" "执行挂载操作"
			process_mounts "mount"
			;;
		umount)
			print_log "INFO" "执行卸载操作"
			process_mounts "umount"
			;;
		monitor)
			declare -A mount_states
			local check_interval=${mount_config[check_interval]}
			
			print_log "INFO" "启动挂载监控服务"
			print_log "INFO" "检查间隔: ${check_interval}秒"
			
			# 初始化状态
			while IFS= read -r config; do
				if [ -n "$config" ]; then
					local name=$(echo "$config" | jq -r '.name')
					mount_states["$name"]="unknown"
					
					print_log "DEBUG" "监控挂载点: $name"
				fi
			done <<< "$(load_mount_config)"
			
			print_log "INFO" "开始监控循环"
			
			while true; do
				local state_changed=0
				while IFS= read -r config; do
					if [ -z "$config" ]; then
						continue
					fi
					
					local name=$(echo "$config" | jq -r '.name')
					local required=$(echo "$config" | jq -r '.required // "true"')
					
					# 检查服务可用性
					if check_storage "$config"; then
						# 服务可用，确保挂载
						if [ "${mount_states[$name]}" != "mounted" ]; then
							if ! check_mount "" "$config"; then
								print_log "INFO" "尝试挂载: $name"
								
								if mount_storage "$config"; then
									mount_states["$name"]="mounted"
									state_changed=1
									
									print_log "INFO" "挂载成功: $name"
								else
									print_log "ERROR" "挂载失败: $name"
								fi
							else
								mount_states["$name"]="mounted"
							fi
						fi
					else
						# 服务不可用，卸载（仅对必需挂载）
						if [ "$required" = "true" ] && [ "${mount_states[$name]}" != "unmounted" ]; then
							if check_mount "" "$config"; then
								print_log "WARN" "服务不可用，尝试卸载: $name"
								
								if umount_storage "$config"; then
									mount_states["$name"]="unmounted"
									state_changed=1
									
									print_log "INFO" "卸载成功: $name"
								else
									print_log "ERROR" "卸载失败: $name"
								fi
							else
								mount_states["$name"]="unmounted"
							fi
						fi
					fi
				done <<< "$(load_mount_config)"

				local sleep_interval=$(( state_changed ? 5 : check_interval ))
				print_log "DEBUG" "监控循环休眠: ${sleep_interval}秒"
				sleep $sleep_interval
			done
			;;
	esac
}

# 启动守护进程
start_daemon()
{
	print_log "INFO" "启动挂载守护进程"
	local arg="$1"
	
	case "$arg" in
		--daemon)
			local script_path="${mount_config[script_path]}"
			if [ -z "$script_path" ]; then
				print_log "ERROR" "脚本路径未设置, 请检查!"
				return 1
			fi
			
			print_log "DEBUG" "脚本路径: $script_path"
			
			# 检查是否已运行
			print_log "DEBUG" "检查是否已有进程运行"
			if existing_pid=$(check_process check "$script_path"); then
				print_log "INFO" "进程已在运行，PID: $existing_pid"
				return 0
			fi
			
			# 启动守护进程
			print_log "INFO" "启动守护进程"
			nohup "$script_path" start --monitor >> "${mount_config[log_file]}" 2>&1 &
			
			local daemon_pid=$!
			echo "$daemon_pid" > "${mount_config[pid_file]}"
			print_log "INFO" "守护进程PID: $daemon_pid"
			
			# 验证进程启动
			if ! check_process "verify" "" "$daemon_pid"; then
				print_log "ERROR" "进程启动验证失败, 请检查!"
				
				rm -f "${mount_config[pid_file]}"
				kill "$daemon_pid" 2>/dev/null || true
				return 1
			fi
			
			print_log "INFO" "守护进程启动成功"
			;;
		--mount)
			print_log "INFO" "执行挂载操作"
			monitor_loop "mount"
			;;
		--umount)
			print_log "INFO" "执行卸载操作"
			monitor_loop "umount"
			;;
		--monitor|*)
			print_log "INFO" "启动监控模式"
			monitor_loop "monitor"
			;;
	esac
	
	return 0
}

# 停止守护进程
stop_daemon()
{
	print_log "INFO" "停止挂载守护进程"
	local script_path="${mount_config[script_path]}"
	
	print_log "DEBUG" "查找运行进程"
	local pids=$(check_process check "$script_path")
	if [ -z "$pids" ]; then
		print_log "INFO" "未找到运行进程, 请检查!"
		return 0
	fi
	
	print_log "INFO" "找到运行进程，PID: $pids"
	
	# 尝试正常终止
	print_log "INFO" "发送终止信号"
	kill "$pids" 2>/dev/null
	
	# 等待进程正常退出
	local wait_time=0
	local max_wait=5
	
	while kill -0 "$pids" 2>/dev/null && [ $wait_time -lt $max_wait ]; do
		print_log "DEBUG" "等待进程退出 ($wait_time/$max_wait 秒)"
		
		sleep 1
		((wait_time++))
	done
	
	# 如果进程仍然存在，强制终止
	if kill -0 "$pids" 2>/dev/null; then
		print_log "WARN" "进程未正常退出，强制终止"
		kill -9 "$pids" 2>/dev/null
		
		sleep 1
	fi
	
	# 验证进程是否已终止
	if kill -0 "$pids" 2>/dev/null; then
		print_log "ERROR" "进程终止失败, 请检查!"
		return 1
	fi
	
	print_log "INFO" "进程已终止"
	
	rm -f "${mount_config[pid_file]}"
	print_log "DEBUG" "删除PID文件: ${mount_config[pid_file]}"
	
	return 0
}

# 显示状态
show_status()
{
	print_log "INFO" "显示挂载状态"
	
	# 颜色定义
	local GREEN='\033[0;32m'
	local RED='\033[0;31m'
	local NC='\033[0m' # No Color
	
	#printf "%-20s %-10s %-15s %-30s %s\n" "名称" "协议" "服务器" "本地路径" "状态"
	printf "%-16s %-8s %-15s %-25s %s\n" "Name" "Protocol" "Server" "Local Path" "Status"
	echo "--------------------------------------------------------------------------------"
	
	while IFS= read -r config; do
		if [ -z "$config" ]; then
			continue
		fi
		
		local name=$(echo "$config" | jq -r '.name')
		local server=$(echo "$config" | jq -r '.server // "local"')
		local protocol=$(echo "$config" | jq -r '.type')
		local local_path=$(get_mount_path "$config")
		local enabled=$(echo "$config" | jq -r '.enabled // "true"')
		
		if [ "$enabled" != "true" ]; then
			continue
		fi
		
		local status
		if check_mount "" "$config"; then
			status="${GREEN}已挂载${NC}"
		else
			status="${RED}未挂载${NC}"
		fi
		
		printf "%-16s %-8s %-15s %-25s %b\n" \
				"$name" "$protocol" "$server" "$local_path" "$status"
	done <<< "$(load_mount_config)"
	
	echo "--------------------------------------------------------------------------------"
}

# 重启挂载
restart_mount()
{
	local action="${1:---monitor}"
	print_log "INFO" "重启挂载服务"

	# 停止守护进程
	print_log "INFO" "停止守护进程"
	if ! stop_daemon; then
		print_log "ERROR" "停止守护进程失败, 请检查!"
	fi
	
	# 清理残留进程
	local pids=$(check_process check "${mount_config[script_path]}" 2>/dev/null || true)
	[[ -n "$pids" ]] && {
		print_log "WARNING" "清理残留进程: $pids"
		kill -9 $pids 2>/dev/null
	}
	
	# 确保PID文件被清理
	rm -f "${mount_config[pid_file]}"
	
	# 启动守护进程
	print_log "INFO" "启动守护进程"
	if ! start_daemon "$action"; then
		print_log "ERROR" "启动守护进程失败, 请检查!"
		return 1
	fi
	
	print_log "INFO" "重启完成"
}

# 初始化挂载
init_mount()
{
	local script_path="${1:-}"
	print_log "INFO" "初始化${mount_config[script_name]}服务"
	
	# 获取脚本路径
	if [ -z "$script_path" ]; then
		script_path=$(get_script_path)
	fi
	
	# 存储脚本路径
	mount_config["script_path"]="$script_path"
	print_log "DEBUG" "脚本路径: $script_path"
	
	print_log "INFO" "检查配置文件 ..."
	if ! check_config; then
		print_log "ERROR" "配置文件检查失败, 请检查!"
		return 1
	fi
	
	print_log "INFO" "设置挂载环境 ..."
	if ! set_mount_env; then
		print_log "ERROR" "挂载环境设置失败, 请检查!"
		return 2
	fi
	
	print_log "INFO" "${mount_config[script_name]}服务初始化成功"
	return 0
}

# 执行挂载
run_mount()
{
	local action="${1:-start}"
	local arg="${2:-}"
	
	print_log "INFO" "执行挂载操作: $action $arg"
	case "$action" in
		start)
			start_daemon "$arg"
			;;
		stop)
			stop_daemon
			;;
		restart)
			restart_mount "$arg"
			;;
		status)
			show_status
			;;
		monitor)
			monitor_loop "monitor"
			;;
		mount)
			monitor_loop "mount"
			;;
		umount)
			monitor_loop "umount"
			;;
		*)
			echo "用法: $0 {start|stop|restart|status|monitor|mount|umount} [--daemon|--mount|--umount|--monitor] [script_path]"
			return 1
			;;
	esac
}

main()
{
	local action="${1:-start}"
	local arg="${2:-}"
	local script_path="${3:-}"
	
	# 初始化环境
	echo "=== 初始化挂载服务 ==="
	if ! init_mount "$script_path"; then
		print_log "ERROR" "系统服务初始化失败, 请检查!"
		exit 1
	fi
	
	# 执行挂载
	echo "=== 启动挂载服务 ==="
	if ! run_mount "$action" "$arg"; then
		print_log "ERROR" "挂载服务启动失败, 请检查!"
		exit 2
	fi
	
	return 0
}

# 如果直接执行脚本，调用主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi