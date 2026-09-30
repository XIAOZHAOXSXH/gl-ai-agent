# GL-AI助手 (gl-ai-agent)

自然语言配置 **GL.iNet 路由器**的 AI Agent，注入 GL 固件**原生管理界面**（SDK4，非 LuCI）。
用一句话说人话就能改 WiFi、限速、拉黑设备、排查卡顿 —— 由你自配的大模型 API 驱动。

> 页面名称：**GL-AI助手** ｜ 安装形态：**ipk / apk** ｜ 不依赖 LuCI、不新增端口、不改 nginx 配置

---

## 它长什么样

在原生后台侧边栏「系统」分组下多出一页，视觉沿用 GL 自己的设计令牌，深浅色主题自动跟随。
页面是原生 Vue 单文件组件，复用 GL 的 `gl-card` / `gl-switch` / `gl-button` 等组件与 CSS 变量。

---

## 为什么这是可行的（实测结论，不是设想）

全部结论来自在 **GL-MG1300 / GL 固件 4.10.x / OpenWrt 22.03.4 / ramips mt7621** 上的实测：

| 事实 | 影响 |
|---|---|
| 原生 UI 是 Vue **2.6.12** 单页应用，nginx + lua 提供 | 注入点在 nginx 这一侧 |
| 视图加载契约：`component = eval(await axios.get('/views/gl-sdk4-ui-<view>.common.js'))` | bundle 必须是**未压缩 `.js`**，且 **eval 的值就是组件对象** |
| GL 的 Vue 是 **runtime-only** 构建，`module`/`exports`/`require`/`Vue` 在页面全局**都不存在** | 模板必须预编译；bundle 不能依赖 CommonJS 全局 |
| 菜单来自 `/usr/share/oui/menu.d/*.json`，每次 `ui.get_menu_list` 现读 | **加文件即出现**，无需重启 |
| `oui.rpc` 用 `dofile` **惰性加载** `/usr/lib/oui-httpd/rpc/<obj>` | 新增 RPC 对象**无需重启 nginx** |
| 本机有 `lua 5.1.5` + `cjson` + `uci` + `ubus` + **`resty.http`** | Agent 内核零新增运行时 |
| 路由器可直连 `api.deepseek.com`（实测 401 = 网络通） | 不依赖电脑做代理 |

---

## 架构

```
浏览器（GL 原生后台）
  ├── /js/gl-ai-agent-boot.js        注入：极轻，永不抛错
  ├── /views/gl-sdk4-ui-gl-ai.common.js   Vue2 SFC 预编译 → eval 得到组件
  └── POST /rpc  {"params":["<sid>","gl_ai","rpc",{"m":"<method>","p":{...}}]}
                          │
        ┌─────────────────▼──────────────────────────┐
        │ /usr/lib/oui-httpd/rpc/gl_ai   ← 唯一稳定方法面 │
        │   每次调用 loadfile 后端 + 失效 glai.* 模块缓存 │
        │   ⇒ 升级后立即生效，永不要求重启 nginx          │
        └─────────────────┬──────────────────────────┘
                          │
        ┌─────────────────▼──────────────────────────┐
        │ /usr/lib/lua/glai/                          │
        │   agent.lua    循环：思考→工具→观察（有上限） │
        │   llm.lua      OpenAI / Anthropic / Gemini   │
        │                流式解析，三种协议适配          │
        │   tools.lua    工具注册表 = 单一事实源         │
        │   redact.lua   MAC/IP/密钥脱敏后才发给模型     │
        │   session.lua  会话持久化（掉电不丢）          │
        │   config.lua   配置（密钥 0600，永不回显）     │
        └─────────────────┬──────────────────────────┘
                          │  oui.rpc → ubus（与原生 UI 同一条链路）
                          ▼
     wifi · clients · firewall · network · dns · system · …
```

### 三个关键设计决定

**1. 不新增 nginx location。**
最初我加了 SSE 端点（`/gl-ai-agent/chat`），后来**主动移除**。理由：那需要 `nginx -s reload`，
而"装个插件要动 Web 服务器"在路由器上是真实风险，也容易和其它注入插件打架。
现在流式效果由 **RPC + 事件日志轮询**实现 —— **安装/升级全程不碰 nginx**。
`scripts/check-package.js` 会把"包里出现 `etc/nginx/`"判为失败，锁死这个约束。

**2. RPC 入口只暴露一个永不变化的方法面 `rpc`。**
`oui.rpc` 把方法表缓存在模块级 upvalue 里，worker 活着就一直是旧的。
如果每次加功能都新增顶层方法名，就永远需要重启 nginx 才能生效。
现在入口只有 `rpc`，它在每次调用时 `loadfile` 真正的实现并清掉 `glai.*` 的 `require` 缓存。
代价是一次 dofile，收益是**升级立即生效**。

**3. 工具注册表是单一事实源。**
一张 Lua 表同时驱动：给 LLM 的 function schema、RPC 执行映射、UI 展示、风险分级与确认策略。
新增能力只改一处，不会出现"schema 和实现对不上"。

---

## 安全设计

- **能力即权限**：模型只能从注册表选工具，无法凭空执行命令。
- **三级权限**：`readonly` / `ask`（默认，只读自动放行、写操作弹确认）/ `auto`。
- **参数二次校验**：类型、范围、正则、CIDR 在 Lua 侧按 schema 校验，不信任模型输出。
- **隐私脱敏**：MAC 转稳定令牌（`M1`、`M2`…，本地保留映射以便后续调用解析回来）、
  IP 只保留末段、密码字段一律替换为 `(set)`。客户端名单不会原样发给第三方模型。
- **提示注入隔离**：工具结果、SSID、日志一律作为数据处理，系统提示明确要求不得当作指令。
- **密钥保护**：`/etc/gl-ai-agent/config.json` 权限 0600，UI 只回显后 4 位，**刻意不做成 conffile**
  （避免包管理器对密钥做指纹与变更询问）。
- **预算熔断**：单轮工具步数、工具结果截断、历史窗口三重上限。

---

## 安装

```sh
# OpenWrt 22.03 / GL 固件 4.x（opkg）
opkg install gl-ai-agent_<version>_all.ipk

# OpenWrt 24.10+（apk-tools v3）
apk add --allow-untrusted gl-ai-agent-<version>.apk
```

安装后打开 `http://<路由地址>` → 侧边栏「系统」→ **GL-AI助手**。

卸载会**只剥离自己注入的 `<script>` 标签**，而不是整文件还原 —— 这样不会连带撤销
glinjector 等其它插件对同一页面的改动。实测卸载后 `gl_home.html` 与安装前完全一致。

---

## 开发

```sh
npm install

npm run build:ui        # 编译 Vue SFC → SDK4 视图 bundle（.js + .gz）
npm run build:ipk       # 打 ipk
npm run build:apk       # 打 apk（CI 上用真 apk-tools v3；本地无 apk 时退化为 APKv2）

npm run check:bundle    # 校验 bundle 满足 eval 契约
npm run check:package   # 校验包结构与内容
npm run deploy          # 直接推到设备（开发快循环，不重启 nginx）
npm run verify:ui       # 真机浏览器端到端验证 + 截图
```

脚本一览：

| 脚本 | 作用 |
|---|---|
| `scripts/build-ui.js` | webpack + vue-loader 编译；**产出 eval 契约要求的形状** |
| `scripts/check-eval-contract.js` | 用真实浏览器验证 `eval(code)` 返回组件 |
| `scripts/verify-ui.js` | 登录真机 → 打开页面 → 截图 + 收集 console 错误 |
| `scripts/test-install.js` | 真机 install → 校验 → 重装幂等 → 卸载 → 校验复原 |
| `scripts/deploy.js` | 开发直推 |

### 为什么 bundle 长这样

GL 的加载器是 `component = eval(responseText)`，而页面里没有 `module`/`exports`。
所以 `build-ui.js` 把 webpack 产物包成
`(function(){ …原样…; return window['GL_AI_VIEW_BUNDLE'].default })()`，
既不依赖任何 CommonJS 全局，也让 eval 的值正好是组件对象。
`check-eval-contract.js` 在真实浏览器里断言这一点，改坏了会立刻失败。

---

## 兼容性

- **纯 Lua + 静态资源，无原生编译产物** → 任何架构（mipsel / aarch64 / armv7）通用。
- 能力探测：`system.get_info` 的 `hardware_feature` 表 + `rpc/` 目录枚举，
  动态决定哪些工具对本机可用，而非机型硬编码。
- 语言：简中 / 繁中 / 英 / 日 / 德 / 西 / 意。
- 与 glinjector 等第三方注入插件共存互不干扰。

---

## 目录结构

```
package/
  data/                        安装到路由器的文件树
    usr/lib/oui-httpd/rpc/gl_ai  RPC 入口（稳定方法面）
    usr/lib/lua/glai/*.lua       Agent 内核
    usr/share/oui/menu.d/        菜单注册
    usr/share/gl-validator.d/    参数白名单
    www/views/                   视图 bundle（.js + .gz）
    www/i18n/                    7 种语言
    www/js/gl-ai-agent-boot.js   页面注入
  control/                     ipk 控制文件与安装脚本
src/ui/                        Vue 2 单文件组件
scripts/                       构建、校验、部署、验证
docs/DESIGN.md                 功能设计方案
```

## 许可

MIT
