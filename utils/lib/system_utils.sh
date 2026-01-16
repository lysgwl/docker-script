#!/bin/bash
# 系统工具模块

if [[ -n "${SYSTEM_UTILS_LOADED:-}" ]]; then
	return 0
fi
export SYSTEM_UTILS_LOADED=1

# 安装运行文件
install_binary()
{
	local src_path=$1
	local dest_path=$2
	local symlink_path=${3:-}
	
	# 处理通配符
	local has_wildcard=0
	[[ "$src_path" == *[\*\?\[]* ]] && has_wildcard=1
	
	local sources=()
	if [[ $has_wildcard -eq 1 ]]; then
		for file in $src_path; do
			[[ -e "$file" ]] && sources+=("$file")
		done
		
		# 检查是否匹配到任何文件
		if [[ ${#sources[@]} -eq 0 ]]; then
			echo "[ERROR] 通配符未匹配到任何文件: $src_path" >&2
			return 1
		fi
	else
		# 校验源路径类型
		if [[ ! -e "$src_path" ]]; then
			echo "[ERROR] 源文件$src_path不存在,请检查!" >&2
			return 1
		fi
		
		sources=("$src_path")
	fi
	
	if [[ -z "$dest_path" ]]; then
		# 创建符号链接
		if [[ -n "$symlink_path" ]]; then
			ln -sfn "${sources[0]}" "$symlink_path" 2>/dev/null || {
				echo "[ERROR] 创建符号链接失败: $symlink_path" >&2
				return 4
			}
		fi
	else
		mkdir -p "$dest_path" || {
			echo "[ERROR] 无法创建目录 $dest_path !" >&2
			return 2
		}
		
		# 复制文件/目录
		for source in "${sources[@]}"; do
			local target_name=$(basename "$source")
			local target_path="$dest_path/$target_name"
			
			# 删除已存在的目标
			rm -rf "$target_path"
			
			# 复制源到目标
			if [[ -d "$source" ]]; then
				# 复制整个目录
				cp -a "$source" "$dest_path/" || {
					echo "[ERROR] 目录复制失败: $source" >&2
					return 3
				}
			else
				# 复制单个文件
				cp -a "$source" "$target_path" || {
					 echo "[ERROR] 文件复制失败: $source" >&2
					 return 3
				}
				
				# 设置可执行权限
				chmod +x "$target_path"
			fi
		done
		
		# 创建符号链接
		if [[ -n "$symlink_path" ]]; then
			local symlink_target="$dest_path"
			if [[ ${#sources[@]} -eq 1 && ! -d "${sources[0]}" ]]; then
				symlink_target="$dest_path/$(basename "${sources[0]}")"
			fi
			
			ln -sfn "$symlink_target" "$symlink_path" 2>/dev/null || {
				echo "[ERROR] 创建符号链接失败: $symlink_path" >&2
				return 4
			}
		fi
	fi
	
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

# 时间管理
time_manager() 
{
	local action="$1"
	local value="${2:-}"
	
	case "$action" in
		"start")
			# 返回当前Unix时间戳
			echo $(date +%s)
			;;
		"calculate")
			[[ -z "$value" ]] && return 1
			
			local start_time=$value
			local end_time=$(date +%s)
			local duration=$((end_time - start_time))
			
			local minutes=$((duration / 60))
			local seconds=$((duration % 60))
			
			if [[ $minutes -gt 0 ]]; then
				echo "${minutes}分${seconds}秒"
			else
				echo "${duration}秒"
			fi
			;;
	esac
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

# 锁文件管理
lock_manager() 
{
	local action="$1"
	local lock_file="$2"
	
	case "$action" in
		"check")
			# 检查锁是否存在
			if [ -f "$lock_file" ]; then
				utils_log "WARNING" "锁文件已存在: $lock_file，进程可能正在运行中"
				return 1
			fi
			
			return 0
			;;
		"create")
			# 先检查锁是否已存在
			if [ -f "$lock_file" ]; then
				utils_log "ERROR" "无法创建锁文件，锁已存在: $lock_file"
				return 1
			fi
			
			# 创建锁文件
			if ! touch "$lock_file" 2>/dev/null; then
				utils_log "ERROR" "无法创建锁文件: $lock_file"
				return 1
			fi
			
			echo "PID: $$" > "$lock_file"
			echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')" >> "$lock_file"
			echo "Command: $0" >> "$lock_file"
			
			utils_log "INFO" "锁文件创建成功: $lock_file"
			return 0
			;;
		"remove")
			# 移除锁文件
			if [ ! -f "$lock_file" ]; then
				utils_log "WARNING" "锁文件不存在: $lock_file"
				return 0
			fi
			
			if ! rm -f "$lock_file"; then
				utils_log "ERROR" "无法移除锁文件: $lock_file"
				return 1
			fi
			
			utils_log "INFO" "锁文件已移除: $lock_file"
			return 0
			;;
	esac
}

# 获取脚本路径
get_script_path()
{
	local script_path="${1:-}"
	
	# 优先使用外部路径
	if [[ -n "$script_path" && -f "$script_path" ]]; then
		echo "$(realpath "$script_path")"
		return 0
	fi
	
	# 获取调用者脚本路径
	if [ ${#BASH_SOURCE[@]} -gt 1 ]; then
		# BASH_SOURCE[1] 是调用者的源文件
		script_path="$(realpath "${BASH_SOURCE[1]}")"
	elif [ -n "${BASH_SOURCE[0]}" ]; then
		# 如果没有调用者，用当前源文件
		script_path="$(realpath "${BASH_SOURCE[0]}")"
	elif [ -n "$0" ] && [ "$0" != "bash" ]; then
		script_path="$(realpath "$0")"
	fi
	
	echo "$script_path"
}

# 检测进程运行
check_process()
{
	local operation="$1"
	local target_pid="${2:-}"
	local script_path="${3:-}"
	local timeout="${4:-10}"
	
	case "$operation" in
		check)
			if [[ -n "$target_pid" && -f "$target_pid" ]]; then
				local pids=$(< "$target_pid") 2>/dev/null || return 1

				# 检查PID是否有效
				if kill -0 "$pids" 2>/dev/null 2>&1; then
					local state=$(ps -o state= -p "$pids" 2>/dev/null | tr -d ' ')
					[[ "$state" != "Z" ]] && echo "$pids" && return 0
				fi
				
				# 清理无效PID文件
				rm -f "$target_pid"
				return 1
			fi
			
			if [[ -n "$script_path" && -f "$script_path" ]]; then
				local script_name=$(basename "$script_path")

				# 定义匹配模式-$script_name.*start.*--daemon
				local pattern="start --daemon|start --monitor|monitor_loop"
				
				# 使用pattern查找进程
				local pids=$(pgrep -f "$pattern" 2>/dev/null || true)
				
				# 获取当前进程
				local current_pid=$$
				
				# 获取父进程
				local parent_pid=$PPID
				
				for pid in $pids; do
					# 排除当前进程
					[[ "$pid" == "$current_pid" ]] && continue
					
					# 排除父进程
					[[ "$pid" == "$parent_pid" ]] && continue
					
					# 检查进程目录是否存在
					[[ -d "/proc/$pid" ]] || continue
					
					# 排除僵尸进程
					local state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ' || true)
					[[ -z "$state" || "$state" == "Z" ]] && continue
					
					# 获取命令行
					local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
					[[ -z "$cmdline" ]] && continue
					
					echo "$cmdline" | grep -q "$script_name" || continue
					echo "$cmdline" | grep -qE "$pattern" || continue

					echo "$cmdline" | grep -qE "(pgrep|grep.*$pattern)" && continue
					echo "$cmdline" | grep -qE "^/(usr/)?bin/(bash|sh)" || continue
					
					echo "$pid"
					return 0
				done
			fi
			
			return 1
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

# 检查挂载状态
check_mount()
{
	local mount_point="$1"
	
	# 验证路径
	[[ -z "$mount_point" || "$mount_point" != /* ]] && return 1
	
	# 规范化路径
	mount_point="${mount_point%/}"
	
	# 挂载状态
	local is_mounted=0
	
	# 检查是否挂载
	# awk -v dir="$mount_point" '$2 == dir {exit 0} END {exit 1}' /proc/mounts
	
	if grep -q " $mount_point " /proc/mounts 2>/dev/null; then
		is_mounted=1
	else
		if command -v mountpoint &>/dev/null; then
			if timeout 1 mountpoint -q "$mount_point" 2>/dev/null; then
				is_mounted=1
			fi
		fi
	fi
	
	if [[ $is_mounted -eq 0 ]]; then
		return 1
	fi
	
	# 检查可访问性
	timeout 2 ls "$mount_point" &>/dev/null || return 2
	return 0
}

# 脚本方式挂载
mount_with_script()
{
	local name_ref="$1"
	local type_ref="$2"
	local server_ref="$3"
	local remote_ref="$4"
	local local_ref="$5"
	local options_ref="$6"
	
	utils_log "INFO" "执行脚本挂载: $name_ref"
	utils_log "DEBUG" "本地路径: $local_ref"
	utils_log "DEBUG" "远程路径: $server_ref:$remote_ref"
	utils_log "DEBUG" "协议类型: $type_ref"
	
	# 检查是否已挂载
	if check_mount "$local_ref"; then
		utils_log "WARNING" "挂载点已存在: $local_ref, 请检查!"
		return 0
	fi
	
	utils_log "DEBUG" "创建本地目录: $local_ref"
	
	# 创建本地目录
	if ! mkdir -p "$local_ref" 2>/dev/null; then
		utils_log "ERROR" "创建本地目录失败: $local_ref, 请检查!"
		return 1
	fi
	
	# 设置默认选项
	case "$type_ref" in
		nfs)
			local default_options="rw,hard,intr,vers=3,timeo=100,retrans=2"
			[ -z "$options_ref" ] && options_ref="$default_options"
			
			# nolock 逻辑检测
			if { [[ -f /etc/alpine-release ]] || [[ -f /.dockerenv ]] || ! command -v rpc.statd >/dev/null 2>&1; } && [[ "$options_ref" != *"nolock"* ]]; then
				options_ref="${options_ref},nolock"
				utils_log "DEBUG" "添加 nolock 选项"
			fi
			
			utils_log "DEBUG" "NFS挂载选项: $options_ref"
			
			# 尝试挂载
			if ! mount -t nfs -o "$options_ref" "$server_ref:$remote_ref" "$local_ref" 2>/dev/null; then
				utils_log "WARNING" "直接挂载失败, 尝试挂载父目录"
				
				# 尝试挂载父目录
				local remote_parent_path=$(dirname "$remote_ref")
				local local_parent_path="/tmp/nfs_parent_${name_ref}_$(date +%s)"
				
				# 创建临时目录
				mkdir -p "$local_parent_path" 2>/dev/null || {
					utils_log "ERROR" "创建临时目录失败, 请检查!"
					return 2
				}
				
				utils_log "DEBUG" "尝试挂载父目录: $server_ref:$remote_parent_path"
					
				# 挂载父目录
				if ! mount -t nfs -o "$options_ref" "$server_ref:$remote_parent_path" "$local_parent_path" 2>/dev/null; then
					utils_log "ERROR" "父目录挂载失败, 请检查!"
					
					rm -rf "$local_parent_path" 2>/dev/null
					return 2
				fi
				
				# 检查子目录
				local subdir_name=$(basename "$remote_ref")
				if [[ -d "$local_parent_path/$subdir_name" ]]; then
					utils_log "DEBUG" "绑定挂载子目录: $subdir_name"
					
					# 绑定挂载将子目录映射到目标位置
					if ! mount --bind "$local_parent_path/$subdir_name" "$local_ref" 2>/dev/null; then
						utils_log "ERROR" "绑定挂载失败, 请检查!"
						
						umount "$local_parent_path" 2>/dev/null
						rmdir "$local_parent_path" 2>/dev/null
						return 3
					fi
				fi
				
				umount "$local_parent_path" 2>/dev/null
				rmdir "$local_parent_path" 2>/dev/null
				
				utils_log "INFO" "通过父目录方式挂载成功"
			else
				utils_log "INFO" "直接挂载成功"
			fi
			;;
		smb)
			local default_options="vers=3.0,guest,uid=0,gid=0,file_mode=0644,dir_mode=0755"
			[ -z "$options_ref" ] && options_ref="$default_options"
			
			# 处理凭证
			local credentials=$(echo "$config" | jq -r '.credentials // ""')
			if [ -n "$credentials" ] && [ -f "$credentials" ]; then
				options_ref="${options_ref},credentials=$credentials"
				utils_log "DEBUG" "使用凭证文件: $credentials"
			else
				utils_log "DEBUG" "使用匿名访问"
			fi
			
			utils_log "DEBUG" "SMB挂载选项: $options_ref"
			
			local mount_output
			mount_output=$(mount -t cifs -o "$options_ref" "//$server_ref/$remote_ref" "$local_ref" 2>&1)
			
			local exit_code=$?
			if [ $exit_code -ne 0 ]; then
				utils_log "ERROR" "SMB挂载失败, 错误码: $exit_code"
				
				if [ -n "$output" ]; then
					utils_log "ERROR" "挂载错误输出: $output"
				fi
				
				return 1
			fi
			
			utils_log "INFO" "SMB挂载成功"
			;;
		*)
			utils_log "ERROR" "不支持的挂载类型: $type_ref"
			return 1
			;;
	esac
	
	utils_log "TRACE" "挂载完成: $local_ref"
	return 0
}

# Docker方式挂载
mount_with_docker()
{
	utils_log "TRACE" "尝试Docker方式挂载"
	
	local name_ref="$1"
	local volume_ref="$2"
	local driver_ref="$3"
	local options_ref="$4"

	# 检查Docker环境
	if ! command -v docker >/dev/null 2>&1; then
		utils_log "WARNING" "Docker命令不存在, 请检查!"
		return 1
	fi
	
	if ! docker info >/dev/null 2>&1; then
		utils_log "WARNING" "Docker服务不可用, 请检查!"
		return 1
	fi
	
	utils_log "DEBUG" "Docker卷名称: $volume_ref"
	utils_log "DEBUG" "驱动类型: $driver_ref"
	
	# 验证必要参数
	[[ -z "$volume_ref" ]] && {
		utils_log "ERROR" "Docker卷名称未配置, 请检查!"
		return 1
	}
	
	# 创建或检查Docker卷
	if docker volume inspect "$volume_ref" >/dev/null 2>&1; then
		utils_log "WARNING" "Docker卷已存在: $volume_ref"
	else
		utils_log "INFO" "创建Docker卷: $volume_ref"
		local create_cmd="docker volume create --driver_ref $driver_ref --name_ref $volume_ref"
		
		# 添加驱动选项
		if [ "$options_ref" != "{}" ]; then
			for key in $(echo "$options_ref" | jq -r 'keys[]'); do
				local value=$(echo "$options_ref" | jq -r --arg key "$key" '.[$key]')
				
				[[ -n "$value" ]] && create_cmd="$create_cmd --opt $key=$value"
			done
		fi
		
		utils_log "DEBUG" "执行命令: $create_cmd"
		
		# 执行创建命令
		if ! eval "$create_cmd" >/dev/null 2>&1; then
			utils_log "ERROR" "Docker卷创建失败: $volume_ref"
			return 1
		fi
		
		utils_log "INFO" "Docker卷创建成功: $volume_ref"
	fi
	
	return  0
}
