#!/bin/bash
# 网络工具模块

if [[ -n "${NETWORK_UTILS_LOADED:-}" ]]; then
	return 0
fi
export NETWORK_UTILS_LOADED=1

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

# 检查远端存储
check_storage()
{
	local server_ref="$1"
	local protocol_ref="$2"
	local remote_ref="$3"
	local credentials_ref="$4"
	local timeout="$5"
	
	[[ -z "$server_ref" || -z "$protocol_ref" || -z "$remote_ref" ]] && return 1
	
	case "$protocol_ref" in
		nfs)
			print_log "DEBUG" "检查NFS服务: $server_ref:$remote_ref"
			
			# 检查NFS服务是否可用
			{ timeout "$timeout" nc -z -w 1 "$server_ref" 2049 || \
			  timeout "$timeout" rpcinfo -t "$server_ref" 100003 || \
			  timeout "$timeout" rpcinfo -t "$server_ref" nfs; } >/dev/null 2>&1 || {
				print_log "ERROR" "NFS服务不可达: $server_ref, 请检查!"
				return 2
			}
			
			# 验证导出路径
			local export_list found=0
			if ! export_list=$(timeout "$timeout" showmount --no-headers -e "$server_ref" 2>/dev/null); then
				print_log "ERROR" "无法获取NFS导出列表: $server_ref"
				return 3
			fi
			
			while read -r line; do
				[[ -z "$line" || "$line" == *"Export list for"* ]] && continue
				
				# 获取导出路径
				local export_path=$(echo "$line" | awk '{print $1}')
				
				# 检查远程路径是否以导出路径开头
				[[ "$remote_ref" == "$export_path" || "$remote_ref" == "$export_path"/* ]] && found=1 && break
			done <<< "$export_list"
			
			[[ $found -eq 0 ]] && {
				print_log "ERROR" "NFS导出路径不存在: $remote_ref, 请检查!"
				return 4
			}
			;;
		smb)
			print_log "DEBUG" "检查SMB服务: //$server_ref/$remote_ref"
			
			# 检测SMB服务是否可用
			{ timeout "$timeout" ping -c 1 -W 1 "$server_ref" || \
			  timeout "$timeout" nc -z -w 1 "$server_ref" 445; } >/dev/null 2>&1 || {
				print_log "ERROR" "SMB服务不可达: $server_ref, 请检查!"
				return 2
			}
			
			# 验证共享路径
			if command -v smbclient &>/dev/null; then
				# 默认匿名访问
				local auth_params="-N"
				
				if [[ -n "$credentials_ref" && -f "$credentials_ref" ]]; then
					auth_params="-A '$credentials_ref'"
				fi
				
				# 构建smbclient命令
				local smb_cmd="smbclient $auth_params -L '$server_ref'"
				
				if ! eval "timeout '$timeout' $smb_cmd 2>/dev/null" | grep -q "$remote_ref"; then
					print_log "ERROR" "SMB共享路径不存在: $remote_ref, 请检查!"
					return 3
				fi
			fi
			;;
		local)
			print_log "DEBUG" "检查本地存储: $remote_ref"
			
			# 对本地存储的检查
			if [[ ! -e "$remote_ref" ]]; then
				print_log "ERROR" "本地存储路径不存在: $remote_ref, 请检查!"
				return 3
			fi
			;;
		*)
			print_log "ERROR" "不支持的协议: $protocol_ref"
			return 1
			;;
	esac
	
	print_log "DEBUG" "存储检查通过: $server_ref ($protocol_ref)"
	return 0
}