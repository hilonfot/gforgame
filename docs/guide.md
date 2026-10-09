# gforgame 操作使用说明

本文面向在本仓库基础上二次开发的同学，说明如何新增消息、注册处理方法、使用 actor、cache、业务配置等核心模块。所有内容均按当前代码实测整理。

- 服务端：Go 1.26 单模块，根目录 `go.mod`
- 客户端：`client/cocos`（Cocos Creator 3.8.x）、`client/go`
- 协议序列化：json（默认）/ protobuf / struct

常用命令：

```bash
make                # 编译本机 game + gate 到 bin/
go run ./cmd/game   # 启动游戏服（先配好 config/config-game.yml 的 db）
go run ./cmd/gate   # 启动网关（需先起 game）
go test ./...       # 全部单测
go generate ./cmd/game   # 改了协议/路由后必跑
```

启动顺序见 `cmd/game/main.go：initMysql → initDdl → config.InitConfig() → InitServices() → InitBuild(s) → 起网络`。**新增模块建议先在 `main.go` 的 `modules` 列表接入路由**。

---

## 一、新增一条消息 + 处理方法（核心流程）

框架采用「约定大于配置」：**不写显式处理函数表**，靠扫描方法签名自动注册（`network/handler.go` 的 `parseHandlerSignature`）。改协议后必须重新 `go generate`。

分三处改，对应 CLAUDE.md 的「三类文件」：

| 职责 | 文件 | 你要做的 |
|------|------|---------|
| 消息定义 | `internal/protos/<mod>.go` | 加 `ReqXxx`/`ResXxx` 结构体 + `cmd_ref` 字段；在 `message.go` 里加 `Cmd*` 常量 |
| 业务逻辑 | `internal/service/<mod>/<mod>_service.go` | 纯逻辑，不碰协议 |
| 路由薄层 | `internal/route/<mod>.go` | 处理器方法，组装请求→调用 service→返回响应 |

### 第 1 步：定义消息

在 `internal/protos/<mod>.go` 添加结构体。**每个消息结构体必须带 `cmd_ref` tag**，把消息关联到 `message.go` 的 Cmd 常量：

```go
type ReqFriendSearchPlayers struct {
	_   struct{} `cmd_ref:"CmdFriendReqSearchPlayers"` // 关联 Cmd 常量名
	Key string   `json:"key"`
}

type ResFriendSearchPlayers struct {
	_        struct{}    `cmd_ref:"CmdFriendResSearchPlayers"`
	Code     int         `json:"code"`
	Items    []*FriendVo `json:"items"`
}
```

- 第 1 个字段 `_ struct{} cmd_ref:"CmdXxx"` 是**必须有**的，`protocolgen` 靠它建立 消息类型⇄Cmd 映射。
- `json` tag 决定 wire 上的字段名，客户端用它对齐。
- 同时在 `message.go` 的 `const (...)` 里加绝对唯一的 `Cmd` 编号（Req 和 Res 分区间，参考现有负号=系统消息、正号=业务消息的惯例）。**`message.go` 里不要加任何注释（解析会出错）。**

### 第 2 步：在 route 写处理函数

在 `internal/route/<mod>.go` 给路由 struct 加方法，签名决定它是否成为 handler：

```go
// 让同一玩家消息串行处理的两种签名（第二个可加 index）
func (r *FriendRoute) ReqSearchPlayers(playerId string, index int32, msg *protos.ReqFriendSearchPlayers) *protos.ResFriendSearchPlayers {
	p := r.playerrepo.GetPlayer(playerId)
	items := r.service.SearchByKey(msg.Key)
	return &protos.ResFriendSearchPlayers{Code: 0, Items: items}
}
```

**签名规则**：
- 方法名必须是 `ReqXxx`，和请求结构体名一致（`ReqFriendSearchPlayers`）；
- 第一个参数 `s *network.Session` 或 `playerId string`；可选第二个 `index int32`；
- 最后一个参数是请求指针 `*protos.ReqXxx`；
- 返回值是该请求对应的响应结构体 `*protos.ResXxx`.
- `Req`→`Res`、`请求结构体→Cmd` 都由代码生成器推导。

### 第 3 步：注册到入口

`cmd/game/main.go` 的 `modules` 列表加一行：

```go
var modules = []any{
	route.NewFriendRoute(s.Friend, s.PlayerRepo),
	route.NewXxxRoute(s.Xxx, s.PlayerRepo),   // 新增行
}
```

`bootstrap.InitRouteModules(router, modules)` 会扫描每个路由对象的方法签名并送册。route 构造函数里注入的 service 来自 `services.go`（见下）。

### 第 4 步：重新生成

```bash
go generate ./cmd/game
# 等价：go run ./internal/tools/gen all
```

会依次跑：`protocolgen`（导出 TS 客户端协议 + 生成 `internal/protos/register_gen.go`）→ `routedispatch`（读 register 生成 `cmd/game/route_dispatch_gen.go`）。**不跑这步，运行期 find 不到 handler、或报构建错误。**

再 `make game` 编译验证。

### 最小调试自检
```go
go test ./network ./...(路由相关)
go run ./cmd/game   # 看启动日志无 "Failed to register handler"
```

---

## 2. 业务配置读取（Excel 配置）

配置不是 yml，而是 `config/excel/*.xlsx`，在 `main.go` 里 `config.InitConfig()` 一次性全量加载进内存（见 `internal/config/data_manager.go`）。

### 新增一张配置表

1. 新建 `config/excel/xxx.xlsx`（列头约定：**第 3 行是列头，前面两行留作说明**，第 1 列写 `end` 表示数据结束）。
2. 在 `internal/domain/config/` 加结构体，字段用 `excel` tag 映射列名（忽略大小写，支持匿名嵌入、JSON 列 `excel:"-“` 跳过）：
```go
// player_level.go
type PlayerLevelData struct {
	Id    int32 `json:"id" excel:"id"`
	Level int32 `json:"level" excel:"level"`
	Cost  int32 `json:"cost" excel:"cost"`
	Hp    int32 `json:"hp" excel:"hp"`
}
```
3. 在 `internal/config/data_manager.go` 的 `tableConfigs` 里登记一张表：
```go
// 普通表（主键固定取 Id 字段，表名 = 类型去掉 Data 后缀小写，文件 = 表名.xlsx）
newDefaultTableLoader[domain.PlayerLevelData](nil, nil),
// 需要索引的表：map[string]string{"索引名": "字段名"}，多个字段逗号分隔即联合索引
newDefaultTableLoader[domain.AccountData](nil, map[string]string{"quality": "Quality"}),
```

### 业务查询

```go
// 单条（类型推导出表名）
info := config.QueryById[domain.PlayerLevelData](id)
// 全量
all := config.QueryAll[domain.PlayerLevelData]()
// 容器（一般需要 AfterLoad 派生结构时用）
c := config.GetContainer("quest").(*container.QuestContainer)
c.FirstMainQuestId, c.AchievementsByGroup ...
```

> 需要「配置后处理」（excel 里表达不了的结构，如成就链表）时，写一个自定义 container，重写 `AfterLoad()`，在 `data_manager.go` 改用 `newContainerTableLoader[T, C](...)`。

---

## 3. 事件总线（模块间解耦）

`common/eventbus` 提供全局事件发布/订阅，适合模块间解耦（如玩家加载、背包变化广播）。

```go
import "github.com/forfun/gforgame/common/eventbus"

// 发布
eventbus.Default().Publish(events.PlayerAfterLoad, player)

// 订阅（一般放模块 Init()）
eventbus.Default().Subscribe(events.PlayerAfterLoad, func(e *events.Event) {
	p := e.GetParam().(*playerdomain.Player)
	// ...
})
```

---

## 4. Actor 并发模型

### 适用场景
需要一个「单实体串行处理」的状态机，且多协程可能并发访问——排行榜、公会、`playerId` 维度的异步任务。

### 核心 API（`actor/` 包）

| 类型 | 说明 |
|------|------|
| `ActorSystem` | actor 注册表 + 生命管理 |
| `ActorRef` | 对外句柄：`Tell`(异步) / `Ask`(同步) / `Task`(调起函数) / `Stop` |
| `BaseActor` | 内嵌后获得按消息类型分发的能力 |
| `RegisterCmd[T]` | 强类型注册消息处理函数 |

### 三件事的用法

**① 定义 Actor + 消息**，看 `internal/service/rank/rank_actor.go`：

```go
type RankActor struct {
	*actor.BaseActor
	ranks *treemap.Map
}
func NewRankActor(...) *RankActor {
	a := &RankActor{BaseActor: actor.NewBaseActor()}
	actor.RegisterCmd(a.BaseActor, a.handleAdd) // 注册：类型为键
	return a
}
func (a *RankActor) handleAdd(cmd *container.AddCmd) actor.Message {
	a.ranks.Put(cmd.Key, cmd.Value)
	return &container.AddResp{}
}
// OnStart/OnStop 生命周期钩子
```

`Container/AddCmd ` 定义在 `rank/container`：**每个 Cmd 配一个 Resp**，一段目录。

**② 对外门面（业务侧无感知 actor）**，*不直接拿 onMessage*，用 `container.ConcurrentRankContainer` 封装：

```go
func (c *ConcurrentRankContainer) Add(key, value any) {
	_, _ = c.ref.Ask(&AddCmd{Key: key, Value: value})
}
```

**③ 装进系统**需要 `GetOrCreate`（惰性创建 + 幂等复用）：

```go
ref := sys.GetOrCreate(actor.NewActorPath("game","rank",fmt.Sprintf("%d",rankType)), func() actor.Actor {
	return NewRankActor(rankType, cap)
})
```

`NewActorPath(namespace, kind, id)` 生成 `"game/rank/1"`，`sys.Find(prefix)`/`FindByPrefix` 可定位。

### Ask 与 Tell 的选择

- **Ask**：同步等结果，适合读（排行榜 Get）。`maxAskTimeout=3s` 兜底。
- **Tell**：异步 fire-and-forget，适合写。邮箱满丢（返回 error）。
- 两者都以**同一邮箱 channel FIFO 队列**保证串行。

> ⚠️ 铁律：**Ask 不能嵌套调用**（在某个 actor 的 OnMessage 里再 Ask 同一个或互相 ask）会自阻塞。跨 actor 协作用 Tell 或用隔离的消息。

### 玩家串行任务的轻量用法：PlayerTaskDispatcher

不用 spawn 整个玩家 actor，直接用「按 playerId 串行队列」：

```go
// dispatch/player_task_dispatcher.go
s.playerTaskDispatcher.DispatchPlayerTask(friendId, func() {
	// 这段逻辑在"该玩家"的 actor 队列里串行执行
	xs := s.service.QueryMyFriendVos(p.Id)
})
```

要表现为 `DispatchPlayerTask` 需要的玩家 actor 的 ref 已存在（由登录相关流程 spawn），否则只打日志。适合好友红点等离线任务。

---

## 5. Cache（缓存 + 异步落库）

### 用法一：CacheManager 内存缓存（读多写少）

注册一份"回源函数"，缓存 miss 自动从 DB 加载，30 分钟过期清理：

```go
// Init 里注册回源（cache miss 时从 db 加载）
r.cacheManager.Register("player", func(key string) (any, error) {
	player := r.inner.GetPlayerByID(key)
	eventbus.Default().Publish(events.PlayerAfterLoad, player)
	return player, nil
})

// 业务
cache, _ := r.cacheManager.GetCache("player")
p := cache.Get(playerId)          // miss 自动调回源
cache.Set(playerId, player)       // 更新缓存
```

每个表一个独立 `Cache`（`expiry 30min` / `cleanupInterval 10s`）。

### 用法二：持久化是真走 DB
CLAUDE.md 说"数据变更先更新缓存，定期全量落库"。稳定持久化由 `internal/infra/persistence/AsyncDBService` + GORM PO 负责。以玩家的 `SavePlayer` 为例：**先 `cache.Set` 更新内存，再调 `inner.SavePlayerToDb` 异步落库**。若要定时刷脏，走 `schedule`（例：`rank` 用 `NewDefaultTaskScheduler`）。

---

## 6. Service 的 DI 装配（dig）

`internal/bootstrap/services.go` 用 `go.uber.org/dig` 做依赖注入。新增一个 service 时：

1. 定义构造函数，入参用 `dig.In`、返回值用 `dig.Out`：
```go
type FriendServiceParams struct{ dig.In; PlayerRepo *playerrepo.PlayerRepository; CacheManager *cache.Manager }
func NewFriendService(p FriendServiceParams) *FriendService
```
2. 在 `registerServices` 加一行 `c.Provide(NewFriendService)`；若指针就进 `Services` struct；若是接口，用 `c.Provide(func(...) XxxInterface {...})` 转函数。
3. `Services` struct 里加字段，route 构造函数即注入它。

> `InitServiceModules()` 会反射遍历 Services 指针字段，自动调用实现了 `ServiceModule.Init()` 的服务的 `Init()`（用于初始化订阅、缓存回源等）。

---

## 8. 端到端演练：新增一个「抽卡」业务模块

把前面几节串起来，从零加一个 `gacha` 模块（客户端请求 → server 处理 → 返回 + 配置读取）。全程照 friend 模块的既有结构写，共 6 个文件，改 3 处。

### Step 0 · 规划文件清单

```
internal/protos/gacha.go                 # 消息结构体
internal/service/gacha/gacha_service.go # 业务逻辑
internal/route/gacha.go                # 路由薄层
internal/domain/config/gacha.go        # 配置 PO（读 excel）
internal/config/container/gacha_container.go  # 可选：配置容器
internal/bootstrap/services.go         # 修改：注册 service
cmd/game/main.go                       # 修改：加 route
config/excel/gacha.xlsx                # 配置表
```

### Step 1 · 定义消息（protos）

```go
// internal/protos/gacha.go
// ReqGachaDraw 抽卡请求
type ReqGachaDraw struct {
	_     struct{} `cmd_ref:"CmdGachaDrawReq"` // 必须
	Pool  int32    `json:"pool"`
	Times int32    `json:"times"`
}

// ResGachaDraw 抽卡响应
type ResGachaDraw struct {
	_        struct{} `json:"-"`
	Code     int32    `json:"code"`
	ItemIds  []int32  `json:"itemIds"`
}

// ResGachaPush 服务器主动推送（新手）——也要 cmd_ref，但不需要 Req
type ResGachaPush struct {
	_ struct{} `cmd_ref:"CmdGachaPush"`
}
```

记得在 `message.go` 里加常量（**不加注释**）：
```go
CmdGachaDrawReq = 4201
CmdGachaDrawRes = 4251
CmdGachaPush    = 4298
```

### Step 2 · service（`internal/service/gacha/gacha.go`）

只写业务，不碰协议。构造参数用 `dig.In` 注入依赖：

```go
package gacha

type GachaService struct {
	conf *container.GachaContainer
}

type GachaServiceParams struct {
	dig.In
	Conf *container.GachaContainer
}
func NewGachaService(p GachaServiceParams) *GachaService {
	return &GachaService{conf: p.Conf}
}

// 抽 N 次，返回掉落道具 id 列表
func (s *GachaService) Draw(pool, times int32) []int32 {
	// 从配置容器查询对应池子，循环出 N 个掉落
	ids := make([]int32, 0, times)
	for i := int32(0); i < times; i++ {
		ids = append(ids, s.conf.NextDrop(pool))
	}
	return ids
}
```

（`GachaContainer` 见 Step 4。）

### Step 3 · route（`internal/route/gacha.go`）

```go
package route

type GachaRoute struct {
	service *gacha.GachaService
}
func NewGachaRoute(service *gacha.GachaService) *GachaRoute {
	return &GachaRoute{service: service}
}

// 签名严格要求：首参 session 或 playerId，可带 index，末参 *ReqXxx，返回 *ResXxx
func (r *GachaRoute) ReqGachaDraw(playerId string, index int32, msg *protos.ReqGachaDraw) *protos.ResGachaDraw {
	ids := r.service.Draw(msg.Pool, msg.Times)
	return &protos.ResGachaDraw{Code: 0, ItemIds: ids}
}
```

### Step 4 · 业务配置（Excel）

**a)** `config/excel/gacha.xlsx`，列头第 3 行：`id | pool | item | weight`（留前两行说明）。

**b)** domain（`internal/domain/config/gacha.go`）：
```go
type GachaData struct {
	Id     int32  `excel:"id"`
	Pool   int32  `excel:"pool"`
	Item   int32  `excel:"item"`
	Weight int32  `excel:"weight"`
}
```

**c)** 在 `data_manager.go` 的 `tableConfigs` 登记（需要按 `pool` 分组，用索引）：
```go
newDefaultTableLoader[domain.GachaData](nil, map[string]string{"pool": "Pool"}),
```

**d)** 若要在 service 里好查，注册一个轻量容器（`internal/config/container/gacha_container.go`）：
```go
type GachaContainer struct {
	*data.Container[int32, domain.GachaData]
}
func (s *GachaContainer) Draw(pool int32) int32 {
	recs := s.GetRecordsByIndex("pool", pool)
	// 按 weight 随机一条返回
	return recs[0].Item
}
```
> data_manager 里把它挂到 `newContainerTableLoader[domain.GachaData](func() *container.GachaContainer{return &container.GachaContainer{}}, nil)`。

> 简化可选：不想要容器，service 直接 `config.QueryById[domain.GachaData]` 也行。

### Step 5 · 装配（bootstrap + main）

**a)** `internal/bootstrap/services.go`：
```go
_ = c.Provide(gacha.NewGachaService)            // registerServices 里加一行
Gacha *gacha.GachaService                      // Services struct 加字段
```

**b)** `cmd/game/main.go` 的 `modules` 列表：
```go
route.NewGachaRoute(s.Gacha),   // 加一行
```

### Step 6 · 重新生成 + 编译

```bash
go generate ./cmd/game   # 生成 register_gen.go + route_dispatch_gen.go + TS 协议
make game                 # 编译
go run ./cmd/game         # 看启动日志 "Loaded table [gacha] with N records"，路由无报错
```

客户端就能 `send({cmd: 4201, pool:1, times:3})` 调用抽卡了。

### 验证清单

| 检查点 | 命令 / 现象 |
|--------|------------|
| 协议注册 | `register_gen.go` 出现 `protocol.RegisterMessage(4201, &ReqGachaDraw{})` |
| 转发器 | `route_dispatch_gen.go` 有其 `ReqGachaDraw`→`ResGachaDraw` 分发 |
| 配置加载 | 启动日志列出 `gacha` 表条数 |
| 字段映射 | 改错 `excel` tag 会字段读不到（回源为 0） |

---

## 9. 常见坑位

| 坑 | 说明 |
|----|------|
| 改了协议没 `go generate` | handler 找不到 / 构建报错。协议和路由文件**才**能手工改，`register_gen.go`/`route_dispatch_gen.go` 是自动生成勿手改 |
| `message.go` 注释 | 会解析出错，别在里面写注释 |
| 消息没带 `cmd_ref` | protocolgen 认不出来，register 里没有它，路由注册不进去 |
| Ask 嵌套 | 同 actor/互 Ask 会死锁，用 Tell |
| 多人并发改同一 entity | 没走 actor/Dispatcher，竞赛条件自己兜 |
| 配置表字段没 `excel` tag | 加载时字段读取不到（`ignoreUnknownFields` 为 true 会吞掉） |