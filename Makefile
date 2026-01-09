# ==================== 命令行参数解析 ====================
# 支持的项目操作
SUPPORTED_PROJECTS := utils nginx filesync freeswitch
SUPPORTED_ACTIONS := build start stop restart clean status logs

# 获取命令行中的所有目标
TARGETS := $(MAKECMDGOALS)

# 解析项目名和动作
PROJECT := $(firstword $(TARGETS))
ACTION  := $(word 2,$(TARGETS))
EXTRA	:= $(word 3,$(TARGETS))

$(eval $(ACTION):;@:)
$(eval $(EXTRA):;@:)

# ==================== 全局配置 ====================
REGISTRY ?=

# 项目根目录
PROJECT_ROOT := $(CURDIR)

# 版本号
VERSION ?= latest

# utils 配置
UTILS_PLATFORM ?= alpine
UTILS_TAG ?= latest
UTILS_IMAGE_NAME ?= docker-utils
UTILS_DIR := $(PROJECT_ROOT)/utils
UTILS_SCRIPT :=build.sh

# ==================== 项目配置 ====================

# nginx 配置
NGINX_IMAGE_NAME := nginx-image
NGINX_DIR := $(PROJECT_ROOT)/network/nginx
NGINX_SCRIPT := build.sh

# filesync 配置
FILESYNC_IMAGE_NAME := filesync-image
FILESYNC_DIR := $(PROJECT_ROOT)/storage/filesync
FILESYNC_SCRIPT := build.sh

# freeswitch 配置
FREESWITCH_IMAGE_NAME := freeswitch-image
FREESWITCH_DIR := $(PROJECT_ROOT)/network/freeswitch
FREESWITCH_SCRIPT := build.sh

.PHONY: all
all:
	@# 验证项目是否支持
	$(if $(filter $(PROJECT),utils nginx filesync freeswitch),,\
		$(error 不支持的项目: $(PROJECT)。支持的项目: utils nginx filesync freeswitch))
	
	@# 验证动作是否支持
	$(if $(filter $(ACTION),$(SUPPORTED_ACTIONS)),,\
		$(error 不支持的动作: $(ACTION)。支持的动作: $(SUPPORTED_ACTIONS)))
	
	@# 执行对应操作
	$(MAKE) $(PROJECT) ACTION=$(ACTION) EXTRA=$(EXTRA)
	
.PHONY: utils
utils:
	@echo "✅ 执行 Utils 项目..."
	$(call run_project_action,utils,$(UTILS_DIR),$(UTILS_SCRIPT),$(ACTION),$(EXTRA))
	
.PHONY: nginx
nginx:
	@echo "✅ 执行 Nginx 项目..."
	$(call run_project_action,nginx,$(NGINX_DIR),$(NGINX_SCRIPT),$(ACTION),$(EXTRA))
	
filesync:
	@echo "✅ 执行 FileSync 项目..."
	$(call run_project_action,filesync,$(FILESYNC_DIR),$(FILESYNC_SCRIPT),$(ACTION),$(EXTRA))
	
freeswitch:
	@echo "✅ 执行 FreeSwitch 项目..."
	$(call run_project_action,freeswitch,$(FREESWITCH_DIR),$(FREESWITCH_SCRIPT),$(ACTION),$(EXTRA))

# 检查项目目录是否存在
define check_project_dir
	@if [ ! -d "$1" ]; then \
		echo "❌ 项目目录不存在: $1"; \
		exit 1; \
	fi; \
	\
	if [ ! -f "$1/build.sh" ]; then \
		echo "❌ 管理脚本不存在: $1/build.sh"; \
		exit 1; \
	fi
endef

# 执行脚本函数
# 用法: $(call execute_script,脚本名$1,动作$2,额外参数$3,utils镜像名$4)
define execute_script
	script_name="$(1)"; \
	action="$(2)"; \
	extra="$(3)"; \
	\
	if [ -n "$$extra" ]; then \
		echo "执行: ./$$script_name $$action $$extra"; \
		./$$script_name $$action $$extra; \
	else \
		echo "执行: ./$$script_name $$action"; \
		./$$script_name $$action; \
	fi
endef

# 执行项目操作
# 用法: $(call run_project_action,项目名$1,项目目录$2,脚本名$3,动作$4,额外参数$5)
define run_project_action
	$(call check_project_dir,$(2))
	@echo "========================================"
	@echo "🚀 执行项目操作: 项目=$(1), 动作=$(4), 目录=$(2)"
	@echo "========================================"
	@cd $(2) && \
	UTILS_PLATFORM=$(UTILS_PLATFORM) \
	UTILS_TAG=$(UTILS_TAG) \
	UTILS_IMAGE_NAME=$(UTILS_IMAGE_NAME) \
	BUILD_VERSION=$(VERSION) \
	CLEAN_BUILD=$(CLEAN_BUILD) \
	$(call execute_script,$3,$4,$5)
endef