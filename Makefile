# gforgame 构建脚本
# 用法:
#   make                   编译本机 game + gate 到 bin/
#   make game / make gate  单独编译
#   make build-linux       交叉编译 linux/amd64 (由 Mac 部署到 Linux 服务器)
#   make build-arm64       交叉编译 linux/arm64
#   make run               启动 game（ENV=game，加载 config-game.yml）
#   make run-gate          启动 gate（ENV=gate，加载 config-gate.yml）
#   make clean             清理 bin/

BIN_DIR   := bin
GO        ?= go
GOOS      ?=
GOARCH    ?=
CGO_ENABLED ?= 0
BUILD_INFO := $(shell git describe --tags --always 2>/dev/null)
LDFLAGS   := -s -w -X "main.Version=$(BUILD_INFO)"

# 交叉编译(仅部署到非本机平台时需显式指定)
CROSS    ?= true

.PHONY: all game gate build-linux build-arm64 build-darwin info version run run-gate clean

all: game gate

game:
	@echo ">> build game [$(GOOS)/$(GOARCH)] $(BUILD_INFO)"
	@mkdir -p $(BIN_DIR)
	@if [ "$(CROSS)" = "true" ] && [ -n "$(GOOS)" ]; then CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/game ./cmd/game; \
	else CGO_ENABLED=$(CGO_ENABLED) $(GO) build -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/game ./cmd/game; fi

gate:
	@echo ">> build gate $(GOOS)/$(GOARCH) $(BUILD_INFO)"
	@mkdir -p $(BIN_DIR)
	@if [ "$(CROSS)" = "true" ] && [ -n "$(GOOS)" ]; then CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/gate ./cmd/gate; else CGO_ENABLED=$(CGO_ENABLED) $(GO) build -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/gate ./cmd/gate; fi

# 预置平台目标:直接覆盖 GOOS/GOARCH 走通用 build
build-linux:   GOOS=linux
build-linux:   GOARCH=amd64
build-linux:   build

build-arm64:   GOOS=linux
build-arm64:   GOARCH=arm64
build-arm64:   build

build-darwin:  GOOS=darwin
build-darwin:  GOARCH=amd64
build-darwin:  build

build: all

info:
	@echo "GO=$(GO) GOOS=$(GOOS) GOARCH=$(GOARCH) CGO=$(CGO_ENABLED) version=$(BUILD_INFO)"

version: info

run: game
	ENV=game $(BIN_DIR)/game

run-gate: gate
	ENV=gate $(BIN_DIR)/gate

clean:
	rm -rf $(BIN_DIR)