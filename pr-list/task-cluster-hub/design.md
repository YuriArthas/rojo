# task_id 调试集群配套设计

## 目标

- 让 Rojo 能稳定配合新的 `task_id` 调试集群使用。
- 维持 Rojo 作为数据面组件的职责，不把 hub/control plane 逻辑引入核心同步流程。
- 为 Linux 一期 server cluster 和三期 Windows 插件自拼域名提供一致的服务身份信息。

## 当前问题

- 当前一个 `serve` 进程天然是单实例、单 session、单 project 心智。
- web API 暴露的服务摘要只有 `sessionId/projectName/rootInstanceId/placeId/gameId`，没有 `task_id`、workspace 或 route identity。
- helper/plugin 侧当前默认 `placeId -> 唯一 base_url`，上层无法明确判断“现在连的是哪个 task”。
- 插件本地的近期连接信息也按 `placeId` 单键存储，不适合同 place 多 task 并存。

## 方案

### 1. 服务身份信息扩展

- 为 Rojo 的状态/摘要接口增加 task 化元数据，至少包含：
  - `task_id`
  - `workspace_path` 或 `worktree_name`
  - `public_base_url`
  - `started_at_unix_ms`
- 保留 `place_id/game_id/session_id` 等原有信息，避免上层丢失现有校验能力。

### 2. serve 元数据接线

- 通过 CLI 参数或环境变量，让外层 supervisor 把 `task_id/workspace/public_base_url` 注入当前 serve 进程。
- `/api/rojo` 或新增状态接口返回这些字段，便于 platform request script 和插件确认当前服务身份。

### 3. 插件/helper 配置兼容

- helper 最终仍可返回单个 `base_url` 给插件。
- 但 Rojo 插件看到的服务元数据必须能表达“当前连接属于哪个 task”。
- 为三期保留插件按 `task_id` 自拼域名后的确认能力。

### 4. 最新收口共识

- Rojo 继续只承担数据面职责，不持有 hub 控制面状态。
- helper 才是本机 Rojo 插件的权威配置源；Rojo 插件不应演化成控制面参与者。
- 当前可接受插件短暂持有 helper 返回的 task 身份用于一次连接，但不应继续把 `generation` 作为长期缓存主键扩散。
- Windows 三期的目标是让 Rojo 插件更像瘦客户端：向 helper 要当前有效配置，而不是自行理解 task 任期流转。
- 当前不推荐再往 Rojo 插件侧增加新的控制面 token 或会话 id；优先收敛现有字段暴露范围。

## 分期

### 一期

- 支持 task 化 route metadata 注入和读取。
- 配合 platform 的动态路由和 workspace 校验。

### 二期

- 保持与 Linux helper 联调兼容，不新增单实例假设。

### 三期

- 与 Windows 插件/Studio 链路完成最终接线。

### Windows 接力指引

- Windows 侧重点查看：
  - 本文档的“3. 插件/helper 配置兼容”“4. 最新收口共识”
  - `plugin/src/HelperClient.lua`
  - `plugin/src/App/init.lua`
- 后续修改方向：
  - 继续减少插件对控制面字段的长期缓存
  - 保持 helper 作为唯一配置来源
  - 不增加按 `place_id` 回退猜测 task 的逻辑

## 非目标

- 不在 Rojo 内引入 hub 调度、lease 或 task 心跳逻辑。
- 不把多 task 调度下沉到 Rojo 核心同步树。

## 文档改动

- `README.md`
- 任何涉及 serve 状态、helper 配置、route identity 的说明

## 验证

- `cargo test`
- 相关 serve 测试更新
- 通过 platform 新链路验证 Rojo 能正确报告 `task_id` 与 workspace 身份
