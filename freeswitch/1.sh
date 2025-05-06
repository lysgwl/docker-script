#!/bin/bash

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

# : <<'COMMENT_BLOCK'
modify_xml_config -f vars.xml -m insert \
	-o '//X-PRE-PROCESS[@data="domain=$${local_ip_v4}"]' \
	-n '<X-PRE-PROCESS cmd="set" data="local_ip_v4=auto"/>' \
	-p before

modify_xml_config -f vars.xml -m replace \
	-o '//X-PRE-PROCESS[@data="external_rtp_ip=stun:stun.freeswitch.org"]' \
	-n '<X-PRE-PROCESS cmd="set" data="external_rtp_ip=192.168.2.15"/>' \
	-p after
	
modify_xml_config -f vars.xml -m replace \
	-o '//X-PRE-PROCESS[@data="external_sip_ip=stun:stun.freeswitch.org"]' \
	-n '<X-PRE-PROCESS cmd="set" data="external_sip_ip=192.168.2.15"/>' \
	-p after
	
modify_xml_config -f vars.xml -m replace \
	-o '//X-PRE-PROCESS[@data="default_password=1234"]' \
	-n '<X-PRE-PROCESS cmd="set" data="default_password=123456"/>' \
	-p after
# COMMENT_BLOCK

modify_xml_config -f "event_socket.conf.xml" -m update \
	-o '//param[@name="listen-ip"]' \
	-n 'value="0.0.0.0"'

modify_xml_config -f "event_socket.conf.xml" -m update \
	-o '//param[@name="password"]' \
	-n 'value="123456"'