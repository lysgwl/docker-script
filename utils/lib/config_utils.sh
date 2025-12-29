#!/bin/bash
# 配置工具模块

if [[ -n "${CONFIG_UTILS_LOADED:-}" ]]; then
	return 0
fi
export CONFIG_UTILS_LOADED=1

# perl修改XML节点
set_xml_perl()
{
	local file="$1" mode="$2" xpath="$3" new_xml="$4" position="$5"
	
	perl - "$file" "$mode" "$xpath" "$new_xml" "$position" <<'EOF_PERL'
use strict;
use warnings;
use XML::LibXML;
use XML::LibXML::PrettyPrint;

# 转义 XPath 中的单引号
sub escape_xpath_value {
	my ($value) = @_;
	$value =~ s/'/''/g;  	# 单引号转义为两个单引号
	return $value;
}

my ($file, $mode, $xpath, $new_xml, $position) = @ARGV;

# 解析 XML 并保留格式
my $parser = XML::LibXML->new({
	keep_blanks => 1,
	expand_entities => 0,
	load_ext_dtd => 0
});

my $doc = eval { $parser->parse_file($file) };	# die "XML 解析失败: $@" if $@;
if ($@) {
	warn "[ERROR] XML 解析失败: $@";
	exit 1;
}

if ($mode eq 'update') {
	my ($target) = $doc->findnodes($xpath);
	if (!$target) {
		warn "[WARNING] 目标节点未找到: $xpath";
		exit 0;
	}
	
	# 解析新属性的键值对
	my %new_attrs = $new_xml =~ /(\w+)="([^"]*)"/g;
	foreach my $attr (keys %new_attrs) {
		$target->setAttribute($attr, $new_attrs{$attr});
	}
} else {
	# 解析新节点
	my $new_node;
	eval {
		$new_node = XML::LibXML->load_xml(string => $new_xml)->documentElement;
	};
	if ($@) {
		warn "[ERROR] 新节点的 XML 语法错误: $@";
		exit 1;
	}
	
	# 构造检查 XPath
	my $tag_name = $new_node->nodeName;
	my %attrs = map { $_->name => $_->value } $new_node->attributes;
	
	my @conditions;
	foreach my $attr (keys %attrs) {
		my $escaped_value = escape_xpath_value($attrs{$attr});
		push @conditions, sprintf("\@%s='%s'", $attr, $escaped_value);
	}
	
	my $xpath_check = @conditions ? 
		"//*[local-name()='$tag_name' and " . join(" and ", @conditions) . "]" :
		"//*[local-name()='$tag_name']";
		
	# 检查节点是否已存在
	my ($existing_node) = $doc->findnodes($xpath_check);
	if ($existing_node) {
		print "[INFO] 新增节点已存在: $new_xml\n";
		exit 0;
	}
	
	# 定位目标节点
	my ($target) = $mode eq 'insert' 
		? $doc->findnodes($xpath) 
		: $doc->findnodes("${xpath}[not(ancestor::comment())]");
	if (!$target) {
		warn "[WARNING] 目标节点未找到: $xpath";
		exit 0;
	}
	
	# 操作节点
	my $parent = $target->parentNode;
	if ($mode eq 'insert') {
		$position eq 'before' ? 
			$parent->insertBefore($new_node, $target) :
			$parent->insertAfter($new_node, $target);
	} elsif ($mode eq 'replace') {
		my $comment = $doc->createComment(" " . $target->toString . " ");
		$parent->replaceChild($comment, $target);
		$parent->insertAfter($new_node, $comment);
	}
}

# 格式化 XML（添加缩进和换行）
my $pp = XML::LibXML::PrettyPrint->new(indent_string => "  ");
$pp->pretty_print($doc);

# 写入文件
$doc->toFile($file);
exit 0;
EOF_PERL
}

# 修改XML配置
modify_xml_config() 
{
	local OPTIND file mode old_pattern new_config position
	mode="replace"
	position="before"
	
	# 参数解析
	while getopts "f:m:o:n:c:p:d" opt; do
		case "$opt" in
			f) file="$OPTARG" ;;
			m) mode="$OPTARG" ;;
			o) old_pattern="$OPTARG" ;;
			n) new_config="$OPTARG" ;;
			p) position="$OPTARG" ;;
			*) echo "Usage: ${FUNCNAME[0]} -f file [-m replace|insert] -o pattern -n new_config [-p before|after]"; return 1 ;;
		esac
	done
	
	[[ -z "$file" || ! -f "$file" ]] && { echo "[ERROR] 文件不存在: $file" >&2; return 1; }
	[[ -z "$new_config" ]] && { echo "[ERROR] 输入新的配置！" >&2; return 1; }
	
	set_xml_perl "$file" "$mode" "$old_pattern" "$new_config" "$position" || {
		echo "[ERROR] 操作XML文件失败: $file (错误码: $?)" >&2
		return 1
	}
	
	return 0
}

# 检查 nginx 配置
check_nginx_conf()
{
	local conf_file="$1"
	local status_code=0
	
	# 判断awk命令是否存在
	local awk_cmd
	if command -v gawk &>/dev/null; then
		awk_cmd="gawk"
	elif command -v awk &>/dev/null; then
		awk_cmd="awk"
	else
		echo "[ERROR] awk命令不存在，请检查系统环境！" >&2
		return 1
	fi

	status_code=$($awk_cmd '
	BEGIN {
		stack_idx = 0          # 括号堆栈索引
		has_http = 0           # 存在未注释的http块
		has_server = 0         # 存在未注释的server块
		invalid_config = 0     # 配置是否无效
		line_num = 0           # 当前行号
		delete stack           # 初始化堆栈
	}

	{
		line_num++
		$0 = gensub(/#.*/, "", "g")  # 去除行内注释
		$0 = gensub(/^[[:blank:]]+|[[:blank:]]+$/, "", "g")  # 清理首尾空格
		if ($0 ~ /^[[:blank:]]*$/) next  # 跳过空行
	}

	# 检测块开始
	#match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+(.*)[ \t]*\{/, arr) {
	match($0, /^([a-zA-Z_][a-zA-Z0-9_-]*)[ \t]+([^{}]*)[ \t]*\{[ \t]*$/, arr) {
		block_type = arr[1]
		block_param = arr[2]

		if (block_type == "location") {
			sub(/^[[:space:]]*[=~*]+[[:space:]]*/, "", block_param)  # 移除前缀修饰符
		}

		block_value=block_param
		if (block_value == "") {
			block_value=block_type
		}

		stack[++stack_idx] = block_value			  # 推入堆栈
		
		if (block_type == "http" || block_type == "server") {
			has_http += (block_type == "http")       # 标记存在http块
			has_server += (block_type == "server")   # 标记存在server块
		}
		next
	}

	# 检测闭合符
	/^[[:blank:]]*\}/ {
		if (stack_idx == 0) {
			invalid_config = 1
			next
		}

		current_block = stack[stack_idx]
		stack_idx--
		next
	}

	END {
		# 错误优先级：括号不匹配 > 块存在性
		if (invalid_config || stack_idx != 0) {
			if (stack_idx > 0) {
				current_block = stack[stack_idx]
				if (current_block == "http") {
					print "[ERROR] http块未闭合" > "/dev/stderr"
				} else if (current_block == "server") {
					print "[ERROR] server块未闭合" > "/dev/stderr"
				} else {
					printf "[ERROR] %s块未闭合\n", current_block > "/dev/stderr"
				}
			}
			print 3
			exit
		}

		# 有效配置判断
		if (has_http && has_server)	{ print 0 }		# 完整配置
		else if (has_http)			{ print 2 }		# 仅有http块
		else if (has_server)		{ print 3 }		# server块不在http内
		else						{ print 4 }		# 无有效块
	}
	' "$conf_file")
	
	# 捕获awk错误状态
	local awk_exit=$?
	
	# 错误处理
	if [ $awk_exit -ne 0 ]; then
		echo "[ERROR] awk处理配置文件失败(退出码: $awk_exit)" >&2
		return 1
	fi
	
	case $status_code in
		0)
			echo "[INFO] 配置文件完整且有效" >&2
			;;
		2)
			echo "[WARNING] 配置文件中仅有http块，未包含server块" >&2
			;;
		3)
			echo "[WARNING] 配置文件中server块未包含在http块内" >&2
			;;
		4)
			echo "[ERROR] 配置文件无效，未包含有效的http或server块" >&2
			;;
		*)
			echo "[ERROR] 未知错误"
			;;
	esac

	return $status_code
}

# 修改 nginx location块
modify_nginx_location()
{
	local conf_file="$1"
	local location_path="$2"
	local reference_content="$3"
	local new_content="$4"
	local comment_reference="${5:-true}"
	
	# 验证参数
	if [[ -z "$conf_file" || -z "$location_path" || -z "$reference_content" || -z "$new_content" ]]; then
		echo "[ERROR] 必要参数不能为空,请检查!" >&2
		return 1
	fi
	
	# 检查配置文件
	if [[ ! -f "$conf_file" ]]; then
		echo "[ERROR] 配置文件不存在,请检查!" >&2
		return 1
	fi
	
	local awk_cmd
	if command -v gawk &>/dev/null; then
		awk_cmd="gawk"
	elif command -v awk &>/dev/null; then
		awk_cmd="awk"
	else
		echo "[ERROR] awk命令不存在，请检查系统环境!" >&2
		return 1
	fi
	
	# 创建备份文件
	local backup_file="${conf_file}.bak"
	if ! cp "$conf_file" "$backup_file"; then
		 echo "[ERROR] 创建备份文件失败: $backup_file" >&2
		 return 1
	fi
	
	# 创建临时文件
	local temp_file
	temp_file=$(mktemp)
	
	# awk 处理配置文件
	$awk_cmd -v loc_path="$location_path" \
		-v ref_cont="$reference_content" \
		-v new_cont="$new_content" \
		-v comment_ref="$comment_reference" \
	'
	function trim_line(line) {
		# 移除首尾空格
		sub(/^[[:space:]]+/, "", line)
		sub(/[[:space:]]+$/, "", line)
		
		# 移除行尾注释但保留分号
		sub(/[[:space:]]*#.*$/, "", line)
		sub(/;[[:space:]]*$/, ";", line)
		return line
	}
	
	# 获取行首缩进
	function get_indent(line) {
		match(line, /^[[:space:]]*/)
		return substr(line, 1, RLENGTH)
	}
	
	BEGIN {
		in_server = 0				# 是否在 server 块中
		in_target_location = 0		# 是否在目标 location 块中
		server_brace_depth = 0		# server 块花括号深度
		location_brace_depth = 0	# location 块花括号深度
		
		# 多行匹配状态
		match_index = 1
		
		# 分割参考内容
		ref_count = split(ref_cont, ref_lines, "\n")
	}
	
	# 检测 server 块开始
	/^[[:space:]]*server[[:space:]]*\{/ {
		in_server = 1
		server_brace_depth = 1
	}
	
	# 在 server 块中
	in_server && !in_target_location {
		# 更新花括号深度
		if (/{/) server_brace_depth++
		if (/}/) server_brace_depth--
		
		# 检测 server 块结束
		if (server_brace_depth == 0) {
			in_server = 0
			print
			next
		}
		
		# 检测目标 location 块
		#if ($0 ~ "location[[:space:]]+" loc_path "[[:space:]]*\{") {
		if ($0 ~ "location[[:space:]]+" loc_path "[[:space:]]*\\{") {
			in_target_location = 1
			location_brace_depth = 1
		}
	}
	
	# 在目标location块中
	in_target_location {
		# 更新 location 花括号深度
		if (/{/) location_brace_depth++
		if (/}/) location_brace_depth--
		
		# 检测location块结束
		if (location_brace_depth == 0) {
			in_target_location = 0
			print
			next
		}
		
		# 尝试匹配参考内容
		if (match_index <= ref_count) {
			current_line=$0
			current_trim=trim_line(current_line)
			
			if (current_trim == trim_line(ref_lines[match_index])) {
				# 存储原始行
				original_lines[match_index] = current_line
				match_index++
				
				# 全部匹配成功
				if (match_index > ref_count) {
					# 注释原始内容
					if (comment_ref == "true") {
						for (i = 1; i <= ref_count; i++) {
							line = original_lines[i]
							indent = get_indent(line)
							print indent "#" substr(line, length(indent) + 1)
						}
					}
					
					# 添加新内容
					split(new_cont, new_lines, "\n")
					for (i = 1; i <= length(new_lines); i++) {
						print indent new_lines[i]
					}
					
					# 重置状态
					match_index = 1
					next
				} else {
					next
				}
			} else {
				# 匹配失败时恢复已匹配行
				for (i = 1; i < match_index; i++) {
					print original_lines[i]
				}
				match_index = 1
			}
		}
		
		print
		next
	}
	
	# 打印其他行
	{ print }
	' "$conf_file" > "$temp_file" 2>&1
	
	# 捕获awk错误状态
	local awk_exit=$?
	
	# 错误处理
	if [ $awk_exit -ne 0 ]; then
		echo "[ERROR] awk处理配置文件失败(退出码: $awk_exit)" >&2
		
		echo "=== awk错误输出 ===" >&2
		cat "$temp_file"
		echo "==================" >&2
		
		# 恢复备份
		if cp "$backup_file" "$conf_file"; then
			echo "[INFO] 备份恢复配置文件: $backup_file -> $conf_file" >&2
		else
			echo "[WARNING] 恢复备份失败! 请手动恢复: $backup_file" >&2
		fi

		rm "$temp_file"
		return 1
	fi
	
	if ! cp "$temp_file" "$conf_file"; then
		echo "[ERROR] 配置文件替换失败，恢复备份!" >&2
		
		cp "$backup_file" "$conf_file"
		rm "$temp_file"
		
		return 1
	fi

	rm "$temp_file"
	echo "[INFO] 配置文件修改成功! $conf_file" >&2
	
	return 0
}