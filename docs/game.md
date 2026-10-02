# gforgame 逻辑服（cmd/game）说明

`cmd/game` 是游戏的**逻辑/游戏服务器**：承载全部业务逻辑、玩家数据、排行榜、公会、背包、邮件等模块。生产环境为三段式 **客户端 → 网关 → 逻辑服**，客户端不直连逻辑服；开发环境可省略网关直连 `cmd/game`。本文从入口 `main.go` 反推其完整执行流程：**启动加载 → 网络接入 → 路由分发 → 业务处理 → 持久化 → 优雅停服/数据恢复**。

```
        客户端
          │  WebSocket(直连模式) 或 经网关转发
          ▼
     cmd/game（逻辑服）
  ┌─────────────────────────────────────────────┐
  │ ws 服务器  → Session(读/写循环)  →  IoDispatch  │
  │                │ 解包/心跳/超时        │        │
  │          路由分发(Actor串行)           │        │
  │                │                      ▼        │
  │           业务 Service ◄─────── 缓存 Cache     │
  │                │                      │        │
  │        AsyncDBService(异步落库)        │        │
  └────────────────┼──────────────────────────────┘
                   ▼
               MySQL(GORM)
```

---

## 1. 角色与定位

- **进程**：`cmd/game`，一个独立可执行程序，是业务主入口。
- **对外（直连模式）**：WebSocket 服务，监听地址 `serverconfig.ServerConfig.ServerUrl`。
- **对外（网关模式）**：作为逻辑服节点，与 `cmd/gate` 各维持一条长连接（`serverconfig.ServerConfig.UseGateMode` 为 `true` 时），本服不直接对客户端收连接，只对网关。
- **对内**：MySQL 持久化 + 进程内缓存 + Actor 并发模型。
- 所有业务逻辑、数据读写在逻辑服完成；网关只做转发。

---

## 2. 启动与运行

```bash
make game            # 编译本机 game 到 bin/game
make build-linux     # 交叉编译 linux/amd64（部署用）

go run ./cmd/game    # 源码直接跑（需先配好 config/config-game.yml 的 MySQL）
```

- **配置**：`config/config-game.yml`（逻辑服配置）+ 全局 `config/default.yml`（`servers` 节点表）。`serverconfig.ServerConfig` 读取。
- **启动关键配置**：`db.url`（MySQL DSN）、`server.url`（WS 监听地址）、`server.useGateMode`（是否网关模式）、`http.url`（后台 HTTP 管理服务地址）、`pprof.addr`（性能监控）。

---

## 2.1 启动流程与数据恢复（main.go）

`cmd/game/main.go` 的启动顺序即"数据恢复"的顺序，**加载配置 → 建库表 → 载入业务配置 → 预热玩家资料索引 → 启动定时任务 → 启动网络**。

1. **读配置**：`config.Load()` 加载 `config-game.yml`、`default.yml`，填充 `serverconfig.ServerConfig`。
2. **初始化 DB**：`persistence.InitMysql()` 用 GORM + MySQL DSN 打开全局单例 `persistence.Db`（带慢查询日志，阈值 1s）。
3. **建表（DDL 迁移）**：`bootstrap.InitMysqlDdl()` 对 `PlayerPO`、`FriendPO`、`SystemParameterEnt` 依次 `AutoMigrate`（不足则建表）。
4. **初始化运行时进程（进程内 config 表）**：`config.InitConfig()` 从 Excel 配置加载业务静态数据（配置 item/hero/mail 等）。
5. **装配服务**：`bootstrap.InitServices()` 用 `dig` 依赖注入容器装配全部 Service/Repository/基础服务（`ActorSystem`、`CacheManager`、`AsyncDBService`、`PlayerTaskDispatcher`、`OnlinePlayerRegistry`），并对实现了 `ServiceModule.Init()` 的模块统一执行启动初始化。
6. **预热 + 任务恢复**：
   - `InitBusiness(s)`：调用 `PlayerProfile.LoadPlayerProfiles()` —— 从 DB `SELECT id,name,level,...` 预加载全部玩家资料摘要，重建 `id→profile`、`id↔name` 两张内存索引（供聊天/好友/榜单快速查询，**启动即恢复，不需要逐个拉全量存档**）；并 `Activity.ScheduleAllActivity()` 排定活动。
   - `StartSchedulers(s)`：`System.StartSystemTask()` 启动系统任务（每日/每周/每月重置、开服等 cron 任务，基于 `common/schedule` 的表达式调度器）。
7. **注册路由**：构造 `network.NewMessageRoute()`，把所有 route 模块 `RegisterMessageHandlers` 注册进路由表（扫描方法签名）。
8. **构建 IO 派发链**：`NewGameTaskHandler(router, actorSystem)` + 共享匿名 Actor；网关模式下再插入 `NewGateTransformHandler()`（拆 `TransferGateToLogic` 外层），`dispatch.BaseIoDispatch` 管线。
9. **启动 WebSocket 服务**：`ws.NewServer(...).Start()`，阻塞在 `startListen`（HTTP/WS 升级），之后启动后台 管理 HTTP + pprof。
10. **阻塞等待退出**：`signal.Notify` 捕获 `os.Interrupt`/`SIGTERM`，或 `node.RunningChan()`（`/api/stop` 触发的关服）。
11. **优雅停服**：`node.Stop()` 关闭监听与连接 → `s.DbService.Shutdown()` 冲刷所有未落库缓存数据（见第 6 节）。

```
 ┌───────────────── 启动/数据恢复 ─────────────────┐
 │ InitMysql → InitMysqlDdl → InitConfig             │
 │ InitServices(dig装配) → InitBusiness(索引恢复)    │
 │ StartSchedulers(定时任务) → 注册路由 → ws.Start() │
 └───────────────────────────────────────────────┘
         ▲ 阻塞等待信号
    SIGTERM / /api/stop ─→ node.Stop() → DbService.Shutdown()
```

---

## 3. 网络接入：连接、解包、心跳、断线

### 3.1 WebSocket 服务（network/ws・server.go）

`ws.NewServer` 在 `server.url` 上用 `net/http` + `gorilla/websocket` 升级 TCP 连接为 WebSocket，每个连接 `newWSConn` 后 `go dispatch.CreateServeSession(conn, codec, ioDispatch, PayloadMode)`。

`dispatch.CreateServeSession` 流程：

1. `session.NewSessionWithProtocol(conn, messageCodec, ProtocolTypeBinary)` 创建 **BaseSession**：内置两条通道 `dataToSend`（出站，带缓冲 queue）与 `DataReceived`（入站带缓冲），`$` 私有协议编解码器 `BinaryProtocolAdapter`，默认 `PayloadModeDecode`。
2. `ServeSession` → 触发 **OnSessionCreated**（在此存入 `io.SetGateSession` 等），随后 `go session.Read()` **go session.Write()` 分别启动读写两个协程。
3. 阻塞在 `eventLoop`，直到会话结束才 `OnSessionClosed` 并 `conn.Close()`。

### 3.2 读循环 / 解包（session/io.go, protocol/protocol.go）

- WebSocket 走 `readWebSocketStream`：`ReadMessage()` 阻塞读一整帧；首个帧决定协议类型（文本 → JSON 协议栈，默认二进制）；`MarkReadActivity()` 维护最后活跃时间供心跳检测。
- 二进制解包逻辑在 `protocol.Protocol.Decode`：固定 12 字节头 `[Size(4)|Index(4)|Cmd(4)]` + 消息体。逐帧从缓冲取头、校验 `Size ≤ 64KB`、取足 body 后产出多个 `Packet`，每个 Packet → 按 `Cmd` 反射出对应的 `*protos.ReqXxx` 用 `MessageCodec.Decode` 解码成 `RequestDataFrame{Header, Msg}`，投递进 `DataReceived` 通道。
- 写循环 `Write()`：从 `DataReceived` 出队把编码好的帧写入 `net.Conn`，出错即 `Close()`。

### 3.3 心跳与空闲超时（network/dispatch/dispatch.go）

- 心跳：客户端定时发 `HeartBeat` 消息（Cmd 见 `protos/message.go`），`eventLoop` 的 `idleCheckTicker`（每 1 分钟）读取 `session.LastReadAt()`，超过 `DefaultSessionIdleTimeout`（10 分钟）无读取即认为心跳超时，日志并主动 `session.Close()`。
- 心跳消息本身走正常路由（`HeartBeat` 有 handler，返回心跳回包），不特殊处理，仅用于刷新 `lastRecvUnixNano`。

### 3.4 断线 / 顶号 / 断线与重连

- **主动顶号**：重复登录时（`DoLogin` 见 §5），`OnlinePlayerRegistry` 发现旧 session，旧连接发 `SendAndClose(PushReplacingLogin{})` 顶掉。
- **断线恢复（session 层）**：关闭后 `OnSessionClosed`，若会话绑定的 `playerId` 与当前注册表一致则解绑玩家；`session.Unbind` 清理 `ownerId→sid` 映射。客户端重连需重新登录，逻辑服不保留断线现场（纯状态在内存，重连=重启会话）。
- **网关模式重连**：`OnSessionClosed` 由 `MyMessageDispatch` 处理（`processor/io`），解绑在线玩家，等待网关重连后重新建立 `gateSession`。

---

## 4. 路由分发与消息处理（核心）

### 4.1 会话级消息链：IoDispatch（`network/dispatch`）

`CreateServeSession` 生成的每封 `DataReceived` 帧，经 `eventLoop` 交由 `IoDispatch.OnMessageReceived` → `BaseIoDispatch` 的 `Pipeline`（有序处理器链）逐段执行，任一返回 `false` 终止本帧处理：

```
pipeline = [GateTransformHandler(仅网关模式) → GameSessionMsgHandler]
```

### 4.2 GateTransformHandler（网关模式）

把网关转发的 `TransferGateToLogic` 外层拆解出来——取出内层 `Cmd/Index/PlayerId/Body`，用 `json` 解码出真正的 `ReqXxx`，回填 `frame.Header.Cmd/Index/Payload` 后放行给下一段；非 `TransferGateToLogic` 消息直接放行。

### 4.3 GameTaskHandler（cmd/game/dispatch.go）——通常的处理链

1. **补齐 playerId**：`fillPayloadFromSession`，若帧没带，从 session 的 `ownerId` 取（登录后已绑定）。
2. **拿 handler**：`router.GetHandler(cmd)` 从路由表查 `network.Handler`。
3. **参数校验**：若 handler 带 `NeedValidate`，用 `validator.ValidateStruct` 校验 `ReqXxx`，失败则回 `I18N_COMMON_PROTOCOL_VALIDATION_FAILED` 错误码并终止。
4. **日志**：`logInboundMessage` 打印入站消息（忽略心跳）。
5. **Actor 串行投递**：决定目标 Actor 并 `ref.Tell()`：
   - 登录消息（`CmdReqPlayerLogin`）→ 投给共享的 `SharedAnonymousActor`（`game/gate/shared`，账号注册前无 playerId）。
   - 其余消息 → `game/player/<playerId>` 的**玩家 Actor**（`GetOrCreate`，不存在则 `NewPlayerActor(...)` 懒创建）。玩家 Actor 保证同一玩家的所有消息**单协程串行处理**。
   - 邮箱满（256）或关闭则丢弃该帧。
6. **dispatchMessage**：在 Actor 的 `OnMessage` 内执行，`callGeneratedRouteHandler`（静态生成的 `route_dispatch_gen.go`）首选，缺失则 `callRoute` 走反射兜底；带 panic 回收与 `handleRoutePanic`。
7. **回包**：`sendResponse(ResponseData)` —— 直连模式 `session.Send`；网关模式走 `io.NotifyByPlayerId`（见 §4.5）。

### 4.4 静态路由（约定 > 配置）

`network/handler.go` 扫描导出方法签名自动登记为处理器：`(receiver, [playerId], [session], [index, reqIndex] 最后一个参数为 Ptr)` 的方法即为 handler；由 `register` 把 `Cmd` 与 `network.Handler` 存入 `Handlers map[int32]*Handler`。方法名 `ReqXxx` 与返回 `ResXxx` 由代码生成器关联。`cmd/game/route_dispatch_gen.go` 为静态派发表（运行时非反射、热路径快），**改动协议/签名后必须 `go generate ./cmd/game`，否则路由不更新**，确保 `register_gen.go` 与 `route_dispatch_gen.go` 一致。

### 4.5 推送通道（`internal/io/notify`）

- `NotifyByPlayerId(playerID, index, resp)`：直连 → `session.Send`；网关模式 → 封装成 `TransferGateToServer` 经 `gateSession` 发回网关，由网关回客户端。

---

## 5. 登录认证（DoLogin）

`internal/route/player.go` 的 `ReqPlayerLogin` → `PlayerService.DoLogin`：

1. 校验 `msg.PlayerId` 非空。
2. `newCreated = profileIndex 中不存在`。
3. `GetOrCreatePlayer`：`repo.GetPlayer`（命中内存/数据库恢复），无则新建并 `SavePlayer`（写 Index DB）。
4. **重复登录/顶号**（直连模式）：`OnlinePlayerRegistry` 找到旧 session 则 `SendAndClose(PushReplacingLogin)`；网关模式的重复登录在网关端判断。
5. `s.SetOwnerId(player.Id)` + `session.Bind(sid, id)` 绑定会话，`AddOnlinePlayer` 登记在线。
6. 异步 goroutine：登录后每日/每周重置检测（系统参数，离线段会补），发布 `PlayerLogin` 事件，`PushLoadComplete` 通知客户端切主界面。
7. 返回 `ResPlayerLogin`（玩家 id/等级/名字等）。

> 认证的"身份绑定"实际上靠 `session.Bind`（`ownerId↔sid` 双向映射）与 `OnlinePlayerRegistry`。登录之后 `frame.Payload` 即为 playerId，路由与推送都依赖它。

---

## 6. 缓存与 MySQL 持久化

### 6.1 缓存层（`cache` / 内存索引）

- **进程内缓存 `manager.go`** 表：`m_` 缓存 30 分钟、清理间隔 10 秒的缓存（`Cache`）`Get/Set`，未命中调 loader 回源。
- **玩家资料索引** `PlayerProfileService`：启动时从 DB 预载全部摘要，供列表/好友/匹配读。
- **玩家聚合缓存**：`PlayerRepository`（`GetPlayer`）优先内存 Map、未命中从 DB `GetPlayerByID` 加载后填充缓存；`SavePlayer` 写缓存 + `AsyncDBService.SaveToDb` 落库。
- **OnlinePlayerRegistry**：`playerId→session` 与 `onlinePlayerIDs` 在线集合（心跳、推送、每日重置遍历所用）。

### 6.2 回写链路（异步持久化，`persist` 包）

写家流程：业务改玩家 → 事件总线发布 `PlayerAttrChange`/`PlayerEntityChange` → `PlayerService.SavePlayer`/`repository.SavePlayer` → `PlayerPO` 快照 → `AsyncDBService.SaveToDb`（player 走 `PersistContainerGroup`，common 走 `QueueContainer`）→ `EntitySavingStrategy.DoSave` → `Db.Save / Db.Delete`。

`AsyncDBService` 分工：
- **playerWorker**：`PersistContainerGroup`，按 `NumCPU()` 个**延时容器**分片（同 id 哈希取模落到同一片，天然保序），每个分片对同一玩家 3 秒内合并为**一份最新快照**（`delay_container.go`），到期才落一次库，显著减 DB 压力。`快照在落库期间再被更新`会重新调度一次，保证最终一致性。
- **commonWorker**：`QueueContainer`，逐条串行，适合非玩家类实体。
- `EntitySavingStrategy.DoSave`：`IsDeleted()` → `Db.Delete`；否则 `Db.Save(upsert)`。
- 失败重试 + 每 5 分钟一次错误日志降噪。

### 6.3 优雅停服：冲刷所有缓存（`Shutdown`）

```
node.Stop()（先停收新连接）
   → AsyncDBService.Shutdown()
        playerWorker.ShutdownGraceful()  // 停 DelayContainer
        commonWorker.ShutdownGraceful()  // 停 QueueContainer
```

每个 `DelayContainer.ShutdownGraceful`：`running=false` → `wg.Wait()` 等已调度的延时任务执行完 → `Range` 把 `pending` 中**剩余最新快照全部** `DoSave` 落库重复一次（兜底，保证不丢）。`QueueContainer` 同理 `close(queue) → wg.Wait → Range 剩余落库`。

因此关服不丢任何已变更数据（无论是否到达延时窗口）。

### 6.4 启动数据恢复（与停服对应）

- 玩家档案：按需 `repo.GetPlayer(id)` 时从 DB 读出并缓存（登录即预热），全量索引在启动时用一条 `SELECT` 摘要建好。
- 系统时间线（每日/每周/每月重置、开服）：启动 `System.StartSystemTask()` 从 `SystemParameterEnt` 载入断点，定时任务驱动，保证跨服重启重置不重。
- 业务配置 `config.InitConfig()` 一次性加载进程内存。

---

## 7. 定时任务与 Actor

### 7.1 Actor 并发（`actor` 包）

- `ActorSystem.Spawn/GetOrCreate`，每个玩家一个 ActorRef（邮箱 256），`ref.Tell(task)` 投递，`runActorLoop` 单协程串行消费 `OnMessage`（CSP）。`handleMessageSafely` 兜住单条消息 panic，不打死 actor 协程；`ActorRef.Task(fn)` 供无会话场景（每日重置、系统任务）往玩家串行队列塞任务。
- 系统级：`SharedAnonymousActor` 处理登录等匿名消息；`PlayerTaskDispatcher.DispatchPlayerTask` 按 playerId 找到玩家 Actor 串行执行离线重置等。

### 7.2 定时任务（`common/schedule` + `system`）

- 表注册 cron/表达式调度器 `Schedule(task, delayMs)`（`DefaultTaskScheduler`，支持取消）。
- 系统服务：开服、每日/每周/每月重置——读取 `SystemParameterEnt` 记录最后重置时间戳，重置时对全部在线玩家广播并补离线玩家重置。活动 `Activity.ScheduleAllActivity` 也走这套调度。

---

## 8. 优雅停服完整时序（再次强调）

1. 收到 `SIGTERM`/`os.Interrupt`/`/api/stop`，入口 break 出阻塞。
2. `node.Stop()`：`http.Server.Shutdown(3s)` 停收新 WS、`listener.Close()`，并触 `onSessionClosed` 逐个解绑在线玩家（不再有新业务进来）。
3. `s.DbService.Shutdown()`：参见 6.3，把所有待落库数据冲刷完毕。
4. 打印 `game server is closed`，进程结束。

> 协调者两点：停服不再进新玩家/task；关闭过程中变更照常入 `AsyncDBService`（其内部 stop 后入列即被 `ShutdownGraceful` 立即落库），故**不丢账**。

---

## 9. 其余入口

- `cmd/game/http.go`：后台 gin HTTP 管理（`POST /api/stop` 触发优雅停服并 `node.RunningChan` 通知主循环、`POST /api/clearDb` 清理库），为生产环境建议禁用或收紧。
- `cmd/game/pprof.go`：`pprof.addr` 配置则起 `net/http/pprof` 性能监控。
- `route_dispatch_gen.go`：静态派发表（勿手改，`go generate` 维护）。

---

## 附：关键源码坐标速查

| 关注点 | 位置 |
|---|---|
| 入口/停服 | `cmd/game/main.go` |
| 派发链 / 路由分发 | `cmd/game/dispatch.go`、`network/handler.go` |
| 会话/读解包/心跳 | `network/session/base_session.go`、`io.go`、`network/dispatch/dispatch.go`、`network/protocol/protocol.go` |
| 在线/顶号 | `internal/infra/net/online_playerer_registry.go`、`network/session/registry.go` |
| 登录 | `internal/service/player/player_service.go`（DoLogin）、`internal/infra/repository/player` |
| AS 落库 | `internal/infra/persistence/async_db_service.go`、`persist/*.go` |
| 缓存/索引 | `cache/`、`PlayerProfileService` |
| Actor | `actor/`、`cmd/game/actor.go`、`internal/service/dispatch` |
| 定时/重置 | `system/`、`schedule/` |