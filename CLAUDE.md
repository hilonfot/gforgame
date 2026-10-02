# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

gforgame：jforgame（Java 手游框架）的 Go 语言实现，一套轻量级高性能手游服务端框架。融入了 Java 游戏服务端思想并用 Go 特性（CSP/Actor）改写。

- 服务端 Go：`github.com/forfun/gforgame`（Go 1.26，单模块，根目录 `go.mod`）。
- 客户端：`client/cocos`（Cocos Creator 3.8.x，推荐）、`client/unity`、`client/go`（Go 测试客户端）。
- 通信协议：json（默认）、protobuf、struct 反射三选一。

## 常用命令

```bash
make                # 编译本机 game + gate 到 bin/
make game           # 仅编译 cmd/game
make build-linux    # 交叉编译 Linux/amd64（部署用），build-arm64 同理
make clean          # rm -rf bin
make info           # 查看当前编译目标 / 版本号

go generate ./cmd/game   # 重新生成路由与协议代码（改协议后必跑，建议部署前执行）
go run ./internal/tools/gen all    # 等价于 go generate（all|proto|route 三选一）

go run ./cmd/game     # 启动游戏服务器（需先配置 config/config-game.yml 的 MySQL）
go run ./cmd/gate     # 启动网关（需先起后端服务器；配置见 config/config-gate.yml）

go test ./...                         # 跑全部单测
go test ./actor -run TestActor        # 单测：指定包 + 用例
go vet ./...
```

单测主要散落在 `data/`、`actor/`、`common/`、`codec/`、`cache/`、`internal/service/rank/container/` 等包。

## 架构与核心约定

### 入口（两个可执行程序）

- `cmd/game`：逻辑/游戏服务器（业务主入口）。**不要乱改这里。**
- `cmd/gate`：网关。生产环境建议客户端 → 网关 → 游戏服务器 的三段式；开发环境可直连 `cmd/game`。网关与服务器内部走 socket。垂直标接口由 `gateway/contract` 定义。

### 消息路由——“约定大于配置”（最重要）

路由不写显式处理函数表，而是**扫描方法签名**：任何满足特定签名的导出方法自动成为消息处理器（见 `network/handler.go` 的 `parseHandlerSignature`）。支持几种签名（第一个参数 session 或 playerId，可选 index，最后一个参数是 `*protos.ReqXxx`）：

```go
func (rs PlayerController) ReqPlayerLogin(s *network.Session, msg *protos.ReqPlayerLogin) *protos.ResPlayerLogin
func (rs PlayerController) ReqPlayerLogin(s *network.Session, index int32, msg *protos.ReqPlayerLogin) *protos.ResPlayerLogin
```

- 方法名（`ReqXxx`）与返回结构体（`ResXxx`）由代码生成器推导关联。
- 消息 `Cmd`（int32，注册在 `internal/protos/message.go`）通过请求结构体类型名映射（`protocol.GetMessageCmdFromType`）。

### 三类文件组织（新增/修改业务前先读这个对应关系）

| 职责 | 位置 | 说明 |
|------|------|------|
| 消息定义 | `internal/protos/<mod>.go` | 结构体 + 在 `message.go` 里加 `Cmd*` 常量。**`message.go` 里不要加注释，否则解析会出错** |
| 业务逻辑 | `internal/service/<mod>/<mod>_service.go` | 纯逻辑，不直接接触协议 |
| 路由薄层 | `internal/route/<mod>.go` | 处理器方法，组装请求→调用 service→返回响应 |

### 静态路由代码生成（改协议后必须重新生成）

- 运行时路由是**静态调用**（非反射），热路径性能好。生成产物：`cmd/game/route_dispatch_gen.go`。
- 生成顺序固定（见 `internal/bootstrap/startup.go` 的 `//go:generate` 注释）：先 `protocolgen`（导出 TS 客户端协议 + 生成 `register_gen.go`），再 `routedispatch`（读 `register_gen.go` 生成 `route_dispatch_gen.go`）。
- 修改了 `internal/protos` 下的消息、或 `internal/route` 的方法签名之后，**务必**重新 `go generate`/`go run ./internal/tools/gen all`，否则路由不更新、构建可能报错或运行期找不到 handler。

### 并发模型：Actor + 派发器

- 玩家、排行榜、公会等每个实体是一个 actor，各自独立 goroutine，互不干扰（基于 CSP 原语，参考 `actor/` 包）。
- 玩家相关操作通过 `internal/service/dispatch/player_task_dispatcher.go`（PlayerTaskDispatcher）做任务派发，保证同一玩家串行处理。

### 持久化与缓存

- MySQL + GORM。ORM 表结构分别在 `internal/infra/persistence/po`（PO 结构体）与 `internal/infra/repository/`。
- 数据有变更时先更新内存缓存（如 `cache/`、`internal/infra` 的缓存实现），定期/定时全量持久化到 DB。启动时 `internal/config.InitConfig()` 加载业务配置。

### 配置

- `config/*.yml`：`config-game.yml`（游戏服务器）、`config-gate.yml`（网关）、`default.yml`（默认）。`config` 包（viper）+ `serverconfig.ServerConfig` 读取。

### AI 开发辅助（README “AI 赋能”）

仓库内 `server/.trae/skills/` 下有两个可复用的开发工作流（trae 技能；Claude 里按需手写同样的步骤）：
- `service-scaffold`：新增一个模块的服务骨架（Service+Route+Protos 三文件占位）。
- `route-req-autocomplete`：为 route 下补全全部 `Req*` 处理方法。

新模块典型接入：按 `service-scaffold` 建骨架，在 `cmd/game/main.go` 的 `modules` 列表里加 `route.NewXxxRoute(...)`；随 `bootstrap.InitRouteModules(router, modules)`（内部调用 `router.RegisterMessageHandlers`）自动扫描注册方法签名；`protos` 下加消息并把 `Cmd` 写进 `message.go`，再 `go generate`。

## 简要目录参考（读代码时的导航）

- `network/`：WebSocket/socket 共用的网络层、消息编解码、`MessageRoute` 与 `Handler`。
- `codec/`：`json`/`protobuf`/`struct` 三种序列化器。
- `common/`：通用工具、日志、容器、调度、事件总线、`conv` 等。
- `internal/`：游戏服务器主体（模块、服务、路由、数据库、业务「账号/英雄/背包/邮件/排行榜/红点」）。
- `internal/tools/`：协议导出与代码生成工具（`gen`/`protocolgen`/`routedispatch`）。
- `client/`：三种客户端；`client/cocos` 与 `client/unity` 支持 websocket/socket 双接入。TS 协议定义由 `protocolgen` 输出。
- `data/`：excel 配置读取（jforgame-data 思想）。