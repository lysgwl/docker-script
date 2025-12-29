#!/bin/bash
# 定时任务工具模块

if [[ -n "${CRON_UTILS_LOADED:-}" ]]; then
	return 0
fi
export CRON_UTILS_LOADED=1

# 匹配 cron 格式字段
match_cron_field() 
{
	local value="$1"
	local field="$2"
	
	# 若字段为通配符，直接匹配
	if [[ "$field" == "*" ]]; then
		return 0
	fi
	
	# 处理逗号分隔的列表
	IFS=',' read -ra parts <<< "$field"
	for part in "${parts[@]}"; do
		# 若部分值等于当前值，匹配成功
		if [[ "$part" == "$value" ]]; then
			return 0
		fi
	done
	
	return 1 # 无匹配
}

# 获取 cron 表达式时间戳
get_next_cron_time()
{
	local schedule="$1"
	
	# 解析 cron 表达式
	local cron_min cron_hour cron_dom cron_month cron_dow
	IFS=' ' read -r cron_min cron_hour cron_dom cron_month cron_dow <<< "$schedule"
	
	# 获取当前时间
	local now_sec=$(date +%s)
	
	local now_min now_hour now_day now_month now_year now_dow
	IFS=' ' read -r now_min now_hour now_day now_month now_year now_dow <<< $(date -d "@$now_sec" +"%-M %-H %-d %-m %-Y %-w")
	
	# 计算下一分钟的起始时间戳
	local time_sec=$(( (now_sec / 60) * 60 + 60 ))
	
	# 最大尝试次数
	local max_attempts=$(( 5 * 365 * 24 * 60 ))

	local attempt=0
	while (( attempt++ < max_attempts )); do
		local min hour day month year dow
		IFS=' ' read -r min hour day month year dow <<< $(date -d "@$time_sec" +"%-M %-H %-d %-m %-Y %-w")
		
		# 快速跳过无效月份
		if [[ "$cron_month" != "*" ]]; then
			local month_match=0
			match_cron_field "$month" "$cron_month" || month_match=1
			
			if (( month_match != 0 )); then
				# 跳到下个月1日 00:00
				time_sec=$(date -d "$year-$month-01 00:00:00 +1 month" +%s)
				continue
			fi
		fi
		
		# 快速跳过无效小时
		if [[ "$cron_hour" != "*" ]]; then
			local hour_match=0
			match_cron_field "$hour" "$cron_hour" || hour_match=1
			
			if (( hour_match != 0 )); then
				# 跳到下一小时0分
				time_sec=$(date -d "$year-$month-$day $hour:00:00 +1 hour" +%s)
				continue
			fi
		fi
		
		# 检查分钟、日期、星期
		if match_cron_field "$min" "$cron_min"; then
			local dom_match=0 dow_match=0
			match_cron_field "$day" "$cron_dom" && dom_match=1
			match_cron_field "$dow" "${cron_dow//7/0}" && dow_match=1
			
			# cron匹配规则
			if { [[ "$cron_dom" = "*" ]] || (( dom_match == 1 )); } && \
			   { [[ "$cron_dow" = "*" ]] || (( dow_match == 1 )); }; then
				echo "$time_sec"
				return 0
			fi
		fi
		
		time_sec=$((time_sec + 60))
	done
	
	return 1
}
