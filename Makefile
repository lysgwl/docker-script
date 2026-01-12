# ==================== 命令行参数解析 ====================
# 支持的项目操作
SUPPORTED_PROJECTS := utils nginx filesync freeswitch
SUPPORTED_ACTIONS := build start stop restart clean status logs

PROJECT ?=
ACTION ?=
EXTRA ?=

ifeq ($(PROJECT),)
    PROJECT := $(word 1,$(filter $(SUPPORTED_PROJECTS),$(MAKECMDGOALS)))
endif

ifeq ($(ACTION),)
    ACTION := $(word 1,$(filter $(SUPPORTED_ACTIONS),$(MAKECMDGOALS)))
endif

ifeq ($(EXTRA),)
    EXTRA := $(word 1,$(filter-out help $(SUPPORTED_PROJECTS) $(SUPPORTED_ACTIONS),$(MAKECMDGOALS)))
endif

ifneq ($(ACTION),)
    $(eval $(ACTION):;@:)
endif

ifneq ($(EXTRA),)
    $(eval $(EXTRA):;@:)
endif

BUILD_UTILS ?= $(call get_param,BUILD_UTILS,false)
CLEAN_BUILD ?= $(call get_param,CLEAN_BUILD,false)
#$(info BUILD_UTILS = $(BUILD_UTILS))
#$(info CLEAN_BUILD = $(CLEAN_BUILD))

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

.PHONY: help
help:
	@echo "Usage: make [project] [action] [extra]"
	@echo "Supported projects: $(SUPPORTED_PROJECTS)"
	@echo "Supported actions: $(SUPPORTED_ACTIONS)"
	@echo ""
	@echo "Examples:"
	@echo "  make utils build          # 构建utils项目"
	@echo "  make utils build alpine   # 构建utils项目，使用alpine平台"
	@echo "  make nginx start          # 启动nginx"
	@echo "  make all                  # 显示帮助信息"
	
.PHONY: utils nginx filesync freeswitch
utils:
	$(call run_project_action,utils,$(UTILS_DIR),$(UTILS_SCRIPT),$(ACTION),$(EXTRA))
	
nginx:
	$(call run_project_action,nginx,$(NGINX_DIR),$(NGINX_SCRIPT),$(ACTION),$(EXTRA))
	
filesync:
	$(call run_project_action,filesync,$(FILESYNC_DIR),$(FILESYNC_SCRIPT),$(ACTION),$(EXTRA))
	
freeswitch:
	$(call run_project_action,freeswitch,$(FREESWITCH_DIR),$(FREESWITCH_SCRIPT),$(ACTION),$(EXTRA))
	
#参数提取
define get_param
$(strip \
  $(let prefix,$(1)=,\
	$(or \
	  $(patsubst $(prefix)%,%,$(filter $(prefix)%,$(MAKECMDGOALS))),\
	  $(patsubst $(prefix)%,%,$(filter $(prefix)%,$(MAKEFLAGS))),\
	  $(2)\
	)\
  )\
)
endef

# 构建脚本参数
define build_script_args
	$(strip \
		$(1) \
		$(if $(2),$(2)) \
		$(if $(filter true,$(BUILD_UTILS)),--build-utils) \
		$(if $(filter true,$(CLEAN_BUILD)),--clean-build) \
	)
endef

# 检查项目目录是否存在
define check_project_dir
	@if [ ! -d "$1" ]; then \
		echo "❌ 项目目录不存在: $1"; \
		exit 1; \
	fi; \
	\
	if [ ! -f "$1/$2" ]; then \
		echo "❌ 管理脚本不存在: $1/$2"; \
		exit 1; \
	fi
endef

# 执行脚本
define execute_script
	script_name="$(1)"; \
	args="$(2)"; \
	\
	if [ ! -f "./$$script_name" ]; then \
		echo "❌ [ERROR] 运行脚本不存在: $$script_name"; \
		exit 1; \
	fi; \
	\
	[ -x "./$$script_name" ] || chmod +x "./$$script_name"; \
	\
	echo "目录: $$(pwd), 执行: ./$$script_name $$args"; \
	\
	if ! ./$$script_name $$args; then \
		exit_code=$$?; \
		echo "❌ [ERROR] 执行失败:$$script_name (退出码: $$exit_code)"; \
		exit $$exit_code; \
	else \
		echo "✅ [INFO] 执行成功: $$script_name"; \
	fi
endef

# 执行项目操作
# 用法: $(call run_project_action,项目名$1,项目目录$2,脚本名$3,动作$4,额外参数$5)
define run_project_action
	$(eval project_name := $(1))
	$(eval project_dir := $(2))
	$(eval script_name := $(3))
	$(eval action := $(4))
	$(eval extra := $(5))
	
	$(eval SCRIPT_ARGS := $(call build_script_args,$(action),$(extra)))
	
	@echo "========================================"
	@echo "🚀 执行项目操作: 项目=$(project_name), 动作=$(action), 目录=$(project_dir)"
	@echo "========================================"
	
	$(call check_project_dir,$(project_dir),$(script_name))
	
	@cd $(project_dir) && \
	UTILS_PLATFORM=$(UTILS_PLATFORM) \
	UTILS_TAG=$(UTILS_TAG) \
	UTILS_IMAGE_NAME=$(UTILS_IMAGE_NAME) \
	BUILD_VERSION=$(VERSION) \
	$(if $(BUILD_UTILS),BUILD_UTILS=$(BUILD_UTILS)) \
	$(if $(CLEAN_BUILD),CLEAN_BUILD=$(CLEAN_BUILD)) \
	$(call execute_script,$(script_name),$(SCRIPT_ARGS))
endef