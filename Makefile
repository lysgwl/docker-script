.PHONY: utils filesync 

REGISTRY ?=
PROJECT_ROOT := $(CURDIR)

VERSION ?= latest

# utils 配置
UTILS_PLATFORM ?= alpine
UTILS_TAG ?= latest
UTILS_IMAGE_NAME ?= docker-utils
UTILS_DIR := $(PROJECT_ROOT)/utils

# filesync 配置
FILESYNC_IMAGE_NAME := filesync-image
FILESYNC_DIR := $(PROJECT_ROOT)/storage/filesync

# nginx 配置
NGINX_IMAGE_NAME := filesync-image
NGINX_DIR := $(PROJECT_ROOT)/network/nginx

FREESWITCH_DIR := $(PROJECT_ROOT)/network/freeswitch

utils:
	@echo "🚀 构建 utils 镜像: $(UTILS_IMAGE_NAME):$(UTILS_PLATFORM)-$(UTILS_TAG)"
	@cd $(UTILS_DIR) && \
	./build-utils.sh $(UTILS_PLATFORM) $(UTILS_TAG) $(UTILS_IMAGE_NAME) 
	@echo "✅ Utils 镜像构建完成: $(UTILS_IMAGE_NAME):$(UTILS_PLATFORM)-$(UTILS_TAG)"
	
utils-all:
	@echo "🚀 构建所有平台的 utils 镜像..."
	@cd $(UTILS_DIR) && \
	./build-utils.sh all $(UTILS_TAG) $(UTILS_IMAGE_NAME)
	@echo "✅ 所有平台 Utils 镜像构建完成"
	
filesync: utils
	@echo "$构建 Filesync 镜像..."
	cd $(FILESYNC_DIR) && \
	UTILS_PLATFORM=$(UTILS_PLATFORM) \
	UTILS_TAG=$(UTILS_TAG) \
	UTILS_IMAGE_NAME=$(UTILS_IMAGE_NAME) \
	BUILD_VERSION=$(VERSION) \
	IMAGE_NAME=$(FILESYNC_IMAGE_NAME) \
	./build.sh
	@echo "✅ Filesync 镜像构建完成: $(FILESYNC_IMAGE_NAME):$(VERSION)"
	
nginx: utils
	@echo "$构建 Nginx 镜像..."
	cd $(NGINX_DIR) && \
	UTILS_PLATFORM=$(UTILS_PLATFORM) \
	UTILS_TAG=$(UTILS_TAG) \
	UTILS_IMAGE_NAME=$(UTILS_IMAGE_NAME) \
	BUILD_VERSION=$(VERSION) \
	IMAGE_NAME=$(NGINX_IMAGE_NAME) \
	./build.sh
	@echo "✅ Nginx 镜像构建完成: $(NGINX_IMAGE_NAME):$(VERSION)"