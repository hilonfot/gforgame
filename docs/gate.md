# gforgame 网关（cmd/gate）说明

`cmd/gate` 是游戏网关进程：游戏客户端不直连逻辑服，而是先连网关，再由网关把消息转发给后端的逻辑服节点。生产环境为三段式 **客户端 → 网关 → 逻辑服**；开发环境可省略网关，客户端直连 `cmd/game`。

---

## 1. 角色与定位

- **进程**：`cmd/gate`，一个独立可执行程序。
- **对外（面向客户端）**：WebSocket 服务，承载登录鉴权与消息转发，监听地址 `serverconfig.ServerConfig.ServerUrl`（见下"配置"）。
- **对内（面向逻辑服）**：以 WebSocket 客户端身份，向后端各逻辑服节点各维持一条连接（**单连接模型**）。
- 网关只做**转发与在线管理**，不做业务逻辑。

```
        WebSocket                     WebSocket
客户端 ===========> 网关(cmd/gate) ===========> 逻辑服(cmd/game)
                           |                        |
                    登录/转发/顶号          处理业务、持久化
```

---

## 2. 启动与运行

```bash
# 编译（部署用）
make gate            # 编译本机 gate 到 bin/gate
make build-linux     # 交叉编译 linux/amd64（部署用）

# 运行
make run-gate        # 等价于 ENV=gate ./bin/gate
go run ./cmd/gate    # 或源码直接跑
```

- **环境变量 `ENV` 决定加载哪个配置文件**：`ENV=gate` → 加载 `config/config-gate.yml`，再叠加全局 `config/default.yml`（`servers` 节点表）。
- **节点归属**：`config-gate.yml` 只写 `server.id`；该 id 会在 `default.yml` 的 `servers` 里找到节点，节点的 `addr` 即网关对外监听的 **WebSocket 地址**，`type` 用于界定节点角色（见"配置"）。
- 当前仓库默认：`server.id=10001` → 对应 `type:0` 的节点 → 网关对外监听 `0.0.0.0:8010`。

## 2.1 启动流程（main.go）

1. **读配置**：`serverconfig.ServerConfig` 加载 `config/config-gate.yml` 与 `config/default.yml`。
2. **服务发现初始化**：根据 `discovery.onlylocal` 选择发现模式
   - `true`（默认缺省值）→ `startLocalServerDiscoveryHeartbeat()`：按本地配置同步一次后端连接；之后每 5 分钟再收敛一次。
   - `false` → `startServerDiscoveryHeartbeat()`：先 HTTP 拉取列表并同步，之后每 5 分钟刷新。
3. **后台协程**：
   - `startBackendSessionMonitor()`：每 3 秒巡检所有后端连接，断了走统一重连。
   - `startOutboundDispatcher()`：启动出站转发队列（见下文"出站队列"）。
4. **构建网络层**：`network.NewMessageRoute()` + 在线玩家注册表 `net.NewOnlinePlayerRegistry()`。
5. **两个派发器**
   - 客户端侧 `MyMessageDispatch` + `ClientRouter`（逻辑：解析登录、转发上行）。
   - 逻辑侧 `logicIoDispatcher`（`GateAndLogicMessageDispatch` + `LogicRouter`）：消费后端下行、转发回客户端，并在后端连接建立时上报在线玩家。
6. **启动 WebSocket 服务**：`ws.NewServer(...)`（Payload 为裸 body 模式）。
7. **阻塞等待退出**：捕获 `os.Interrupt`/`SIGTERM` 优雅关服。
8. **关服**：停发现、停巡检、停出站队列、关全部后端连接。

---

## 3. 消息流转（核心，从代码反推）

### 3.1 客户端 → 网关 → 逻辑服（上行）

```
客户端
 └─ ws 消息 → ioDispatcher → ClientRouter.MessageReceived(session, frame)
     ├─ cmd == LoginCmd()（ReqPlayerLogin 的 Cmd）
     │     └─ HandleLoginReq: 校验 → 顶号 → 绑定 → 在线注册 → transferMsgToLogic
     └─ 其它 cmd
           └─ transferMsgToLogic: 解析目标 serverID → 对外 to 后端
                 ├─ 确定 serverID:
                 │    优先 forceServerID（登录时已知）；
                 │    否则 resolvePlayerServerID → 玩家 serverId 映射 / session 属性
                 ├─ gateTransferCodec.NewTransferMessage(playerId, cmd, index, body)
                 └─ enqueueTransfer(serverID, transfer, index)  → 出站队列
```

### 3.2 登录处理（HandleLoginReq）

1. 解码 `ReqPlayerLogin`，取 `playerId`、`serverId`。
2. 校验：两者非空，且 `isBackendServerConfigured(serverId)`（后端已在配置/发现中，类型为逻辑服）。
3. **顶号处理**：若该 `serverID_playerID` 已有其它连接 → 给旧连接发 `ReplacingLoginPush`（"被顶号"推送）后关闭。
4. 绑定：为 session 设置 `serverId`、`sessionPlayerKey`（`<serverId>_<playerId>`），把玩家写入在线注册表与全局会话表。
5. 记录 `playerID → serverID` 映射（`playerServerIDMap`）。
6. 把登录请求作为普通转发消息发给目标逻辑服。

### 3.3 逻辑服 → 网关 → 客户端（下行）

```
后端 session 收到数据 → consumeBackendSession → logicIoDispatcher.OnMessageReceived
  └─ LogicRouter.MessageReceived
      ├─ cmd == TransferCmd()(TransferGateToLogic 的 Cmd)
      │     └─ forwardTransferToClient:
      │           ├─ 取 playerId / cmd / index / body
      │           ├─ resolveBackendServerID(该后端 session) → serverID
      │           ├─ 由 serverID_playerID 找到客户端 session
      │           ├─ 用客户端 codec 重新编码
      │           └─ session.SendRaw 原样发回客户端
      └─ 其它非法/未知 → 忽略
```

### 3.4 下线

`MyMessageDispatch 的 OnSessionClosed` 触发（仅当自己确实是该玩家的当前会话，规避顶号竞态）：

1. 判断 `sessionPlayerKey` 是否仍为当前绑定 → 是则：
   - `notifyLogicPlayerLogout`：给后端发 `NotifyPlayerLogoutToGame`，清理逻辑服在线状态。
   - `unbindPlayerServer`：删除玩家 → 服务器映射。
2. 从在线注册表 `RemoveOnlinePlayer`。

---

## 4. 后端连接池与重连（plugin 模型）

- `backendPools`：以 `serverID` 为键的**单连接池**；每个逻辑服节点只有一条后端连接。
- **收敛**：`reconcileBackendPools(desired)` 对比“期望集合”：
  - 新增 → `ensureBackendPool` 拨号；更新 → 关旧连新；消失 → 关闭+清理。
- **拨号** `connectBackendSession`：
  - 用 `client.WebSocketClient` 建连接，`session.SetAttr("serverId", serverID)`，`SetOwnerId` 用占位 id（后端无玩家 id，Send 要求 id 非空）。
  - 成功后才替换旧连接（避免空窗），提升后触发 `notifyOutboundDispatcher`。
- **消费** `consumeBackendSession` 常驻：`session.DieChan()`(连接关闭) 与 `DataReceivedChan()`(下行帧)。
- **重连** `scheduleReconnect`：延迟 1500ms 后重连，失败则限流打日志并再次调度；已移除节点不重连。
- **巡检** `checkBackendSessions`：每 3 秒；发现连接已死 → 清理并调度重连。

---

## 5. 出站队列（缓冲与容错）

`startOutboundDispatcher` 启动一个专用 goroutine 消费 `outboundQueue`（容量 4096），把转发消息放入 `LimitedList`（上限 4096）后逐个 `sendTransferToBackend`：

- 后端连接不可用→ 保留在 pending，等 `outboundNotify`/重连兑现后重发。
- 超过上限时丢弃最旧的一条并打日志（防止无限堆积）。
- `enqueueTransfer` 在队列满时阻塞写（不丢消息）。

> 这个设计与 README“服务器故障时网关缓存消息、恢复后补发”一致——客户端无需重连即可继续通信。

---

## 6. 协议适配与跨语言

协议通过接口解耦（`gateway/contract`）：

| 接口 | 作用 |
|------|------|
| `ClientLoginAdapter` | 登录协议的最小契约（`LoginCmd` / 解码具体登录体 / 顶号推送） |
| `TransferCodec` | 网关与逻辑服之间转发包的契约（`TransferCmd` / 构造 / 解析） |

当前实现 `internal/gatewayadapter/proto_gate_adapter.go`（针对本项目 `protos`）：

- `LoginCmd() = protos.CmdReqPlayerLogin`
- `TransferCmd() = protos.CmdTransferMsgGateToLogic`
- 转发包结构 `protos.TransferGateToLogic{ PlayerId, Cmd, Index, Body []byte }`
- 顶号推送 `protos.PushReplacingLogin`

> 若逻辑服是其它语言（如 Java 版 jforgame），只需新写一套实现 `contract` 的 adapter，对齐这里的协议即可；其余转移、队列、重连无不同。

---

## 7. 配置

网关用 `config/config-gate.yml` + `config/default.yml`（+ 可选 `config-<env>.yml`）。

`config/config-gate.yml` 通常只有网关自身标识：

```yaml
server:
  id: 10001        # 网关节点 ID
```

`config/default.yml` 的 `servers` 是节点总表（网关/逻辑服混排，用 `useGateMode` 与 `type` 区分角色），网关只关心与自身 `server.id` 相同的节点，以及 `type` 属于逻辑服的节点：

```yaml
servers:
  - id: 10001         # 网关自身节点（config-gate.yml 中 server.id=10001）
    type: 0           # type:0 = 网关
    useGateMode: true
    addr: 0.0.0.0:8010   # 网关对外 WebSocket 监听地址（ServerUrl）
    httpAddr: 0.0.0.0:8090
  - id: 1001
    type: 1           # type:1 = 逻辑服（logicServerType）
    useGateMode: true
    addr: 127.0.0.1:8011   # 网关后端连接地址
    httpAddr: 0.0.0.0:8091
```

- `useGateMode`：该节点是否走网关模式（`true` = 客户端经此进程）。
- `type`：角色编号。`logicServerType = 1`（见 `gate_state.go`）。网关用 `GetServerTypeByID` 判断某 id 是不是后端、用 `GetServersByType(1)` 取后端节点集合。
- `server.id` 对应的节点 `addr` 是**网关自己的**监听地址（`ServerUrl`），其余 `type:1` 节点的 `addr` 是后端地址。

**服务发现**（可选 `Extra`）：

```yaml
discovery:
  onlylocal: false        # false=HTTP 动态发现；缺省/true=本地配置
  apiurl: http://admin/discover/server/list   # 动态发现接口
```

`server_discovery.go` 用 HTTP GET 拉取 `{code, data.servers:[{id,name,ip,port,httpPort,useGate}]}`，过滤掉 `id==0`、缺 `ip`、`useGate==0` 的行，转成 `DynamicServerNode` 后 `SyncDynamicServers` 全量同步，并 `reconcileBackendPools` 收敛连接。每 `serverDiscoveryRefreshInterval`(5 分钟) 刷新一次。

---

## 8. 常见配置动作

| 场景 | 做法 |
|------|------|
| 加一个新的逻辑服节点监听 | 在 `servers` 加 `type:1` 的条目 或 由动态发现 push 即可；网关下轮收敛自动连上 |
| 去掉后端节点 | 从配置/发现列表移除；网关下轮收敛自动断开 |
| 网关连不上某后端 | 自动处理：连接断开后延迟 1500ms 重连，同时每 3s 巡检兜底，直至恢复 |
| 消息发不出去 | 检查 `isBackendServerConfigured` 的服务器类型/ip 是否有效 |

---

## 9. 关键代码文件（cmd/gate 内）

| 文件 | 职责 |
|------|------|
| `main.go` | 入口、启动/关服、服务发现选择 |
| `gate_client_router.go` | 客户端侧 router / 登录 / 顶号 / 下线 / 上行转发 |
| `gate_logic_router.go` | 后端侧 router / 下行回发 / 上线上报 / 后端派发器 |
| `gate_backend_pool.go` | 后端连接池、收敛、重连、巡检 |
| `gate_outbound_queue.go` | 出站转发队列（缓冲 + 重发） |
| `gate_state.go` | 全局状态、常量、协议对象 |
| `server_discovery.go` | HTTP 服务发现（动态节点） |