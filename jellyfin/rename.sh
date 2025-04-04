#!/bin/bash

# ==========================================
# 功能：按 TheTVDB 分季规则重命名《海贼王》动画文件
# 作者：您的名字
# 日期：YYYY-MM-DD
# ==========================================

# 初始化环境变量
init_env() 
{
	# 分季规则（季号:起始集数-结束集数）
	declare -gA SEASON_RANGES=(
		["01"]="1-61"
		["02"]="62-77"
		["03"]="78-92"
		["04"]="93-130"
		["05"]="131-143"
		["06"]="144-195"
		["07"]="196-228"
		["08"]="229-263"
		["09"]="264-336"
		["10"]="337-381"
		["11"]="382-407"
		["12"]="408-421"
		["13"]="422-458"
		["14"]="459-516"
		["15"]="517-578"
		["16"]="579-628"
		["17"]="629-750"
		["18"]="751-782"
		["19"]="783-891"
		["20"]="892-1000"
	)
	
	# 支持的文件扩展名
    declare -ga FILE_EXTENSIONS=("rmvb" "mkv" "mp4")
	
	# 生成扩展名正则表达式部分
    declare -g ext_regex_part
	ext_regex_part="($(IFS="|"; echo "${FILE_EXTENSIONS[*]}"))"
	
	# 文件重命名规则
	declare -gA RENAME_RULES=(
		[1]="^海贼王([0-9]+)\\.${ext_regex_part}$;One Piece - S{season}E{episode}.{ext}"
		#[2]="^One Piece - S([0-9]{2})E([0-9]{2})\\.${ext_regex_part}$;海贼王{abs_ep}.{ext}"
	)
	
	# 路径相关变量
    declare -g SCRIPT_DIR TARGET_ROOT
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TARGET_ROOT="${1:-$SCRIPT_DIR}"
}

# 处理文件重命名
handle_rename()
{
	local src_file="$1"
	local new_name="$2"
	
	local dirpath=$(dirname "$src_file")
	local dest_file="$dirpath/$new_name"
	
	# 防覆盖检查
	if [[ -e "$dest_file" ]]; then
		local timestamp=$(date +%s)
		
		dest_file="${dest_file%.*}_${timestamp}.${dest_file##*.}"
		echo "[警告] 文件冲突，重命名为：$dest_file"
	fi
	
	# 执行重命名
	mv -n "$src_file" "$dest_file"  2>&1
}

# 处理规则1：旧文件名 -> 新文件名
process_rule1()
{
	local file="$1"
	local template="$2"
	
	local abs_ep="${BASH_REMATCH[1]}"	# 绝对集号（如 062）
    local ext="${BASH_REMATCH[2]}"		# 扩展名（如 rmvb）
    local abs_ep_num=$((10#$abs_ep))	# 转为十进制整数（如 062 → 62）
	
	# 查找匹配的分季
	for season in "${!SEASON_RANGES[@]}"; do
		IFS='-' read -r start end <<< "${SEASON_RANGES[$season]}"
		
		if (( abs_ep_num >= start && abs_ep_num <= end )); then
			# 计算相对集号
			local rel_ep=$((abs_ep_num - start + 1))
			# 生成新文件名
			local new_name="One Piece - S${season}E$(printf "%02d" $abs_ep_num).$ext"
			
			handle_rename "$file" "$new_name"
			break
		fi
	done
}

# 处理规则2：新文件名 -> 旧文件名
process_rule2()
{
	local file="$1"
	local template="$2"
	
	local season="${BASH_REMATCH[1]}"	# 季号（如 02）
    local rel_ep="${BASH_REMATCH[2]}"	# 相对集号（如 01）
    local ext="${BASH_REMATCH[3]}"		# 扩展名（如 rmvb）
	
	# 根据分季规则计算绝对集号
	IFS='-' read -r start end <<< "${SEASON_RANGES[$season]}"
	if [[ -z "$start" ]]; then
		echo "[错误] 未找到季 $season 的分季规则！"
		return 1
	fi
	
    local abs_ep_num=$((start + 10#$rel_ep - 1))	# 绝对集号（如 62）
	local abs_ep=$(printf "%03d" "$abs_ep_num")		# 格式化为三位数（如 062）
	
	# 替换模板变量
	local new_name=$(echo "$template" | sed \
		-e "s/{abs_ep}/$abs_ep/g" \
		-e "s/{ext}/$ext/g")
		
	handle_rename "$file" "$new_name"
}

# 处理文件
process_file()
{
	local file="$1"
    local filename=$(basename "$file")

	# 遍历所有重命名规则
	for rule_id in "${!RENAME_RULES[@]}"; do
		IFS=';' read -r regex template <<< "${RENAME_RULES[$rule_id]}"

		if [[ "$filename" =~ $regex ]]; then
			case "$rule_id" in
				1) process_rule1 "$file" "$template";;
				2) process_rule2 "$file" "$template";;
			esac
			
			break
		fi
	done
}

# 主程序流程
main()
{
	# 初始化环境
	init_env "$@"
	
	# 构建季目录列表
	local season_dirs=()
	for str in "${!SEASON_RANGES[@]}"; do
		season_dirs+=("$TARGET_ROOT/Season $str")
	done
	
	# 按数字顺序排序季目录（解决关联数组无序问题）
	IFS=$'\n' sorted_season_dirs=($(sort <<<"${season_dirs[*]}"))
	unset IFS
	
	# 遍历目录处理文件
	for season_dir in "${sorted_season_dirs[@]}"; do
		[[ ! -d "$season_dir" ]] && continue
		
		# 执行查找并处理文件
		find "$season_dir" -type f -print0 | while IFS= read -r -d $'\0' file; do
			# 处理文件
			process_file "$file"
		done
	done
}

# 执行主程序
main "$@"