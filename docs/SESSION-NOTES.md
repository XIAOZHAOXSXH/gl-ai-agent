# 开发进度与交接（SESSION 2026-09-30）

面向下次继续开发：当前能跑到哪、哪些是实测结论、下一步做什么。

---

## 一、当前状态：端到端可用，本轮回归全绿

真机 `192.168.8.1`（GL-MG1300 / GL 固件 4.10.1，恢复出厂后已重装）上已验证通过：

| 验证 | 命令 | 结果 |
|---|---|---|
| 后端静态 + 运行时自检 | 推送后 `sh /tmp/glai-check.sh` | 12 个 Lua 语法 OK、15 工具、schema 零空 `required`、selftest **7/7** |
| 安装生命周期 | `node scripts/test-install.js` | 全部文件就位 → **未加任何 nginx 配置** → 注入 1 次 → 重装幂等 → 卸载后 md5 复原 |
| 浏览器全流程 | `GL_API_KEY=… node scripts/verify-e2e.js` | **12/12** |
| 确认闸门 | `GL_API_KEY=… node scripts/verify-approval.js` | **7/7** |
| 打包 | `build-ipk.js` / `build-apk.js` / `check-package.js` | ipk 与 apk 均 **RESULT: OK** |
| Lint | `lint-shell.js` / `lint-lua.js` | shell 51 文件 0 问题；Lua 需本机或 CI 装 lua5.1 |

真实对话示例（`deepseek-flash`，网关 `https://api.moleapi.com/v1`）：

```
step 1 → tool_call wifi_get_config → tool_result done
step 2 → "GL-MG1300-caa（5G 是 GL-MG1300-caa-5G）"
```

确认卡拦截示例：

```
tool_call wifi_set_ssid_or_password (risk:medium)
confirm  args:{band:"2g", kind:"main", ssid:"GL-Test-2G"}
[用户点取消] → done(reason:"declined") → saved
模型："改动没有执行——在确认环节被取消了，我没有重试。"
```

设备复查 `uci show wireless | grep GL-Test-2G` 为空 —— **从未发生写入**。

---

## 二、下一步

1. **配置模型 API 后跑一次真实写入**。设备恢复出厂后 key 已清空，且确认闸门测试全程只做"拒绝"，
   所以**"批准后真正写入"这条路径尚未在真机验证**。建议先在可改字段上试（如时区），再试 WiFi。
2. **CI 的 apk 校验**：APKv3 是 ADB 容器、本地无法解码（见第三节"打包"），已改成
   `apk add --root` 装进临时根 + `check-package.js --installed-root` 断言真实落盘文件。
   下一次 CI 要确认：`alpine:3.23` 里 `apk mkpkg` 产出的包能被 `apk add --root --initdb` 装上，
   且 23 个文件与权限全部符合（尤其是 `usr/lib/oui-httpd/rpc/gl_ai` 的 0755）。
3. **会话历史 UI**：后端 `list_sessions` / `get_session` / `delete_session` 已就绪，界面未接。
4. **仓库推送**：已完成 —— https://github.com/XIAOZHAOXSXH/gl-ai-agent
   （仓库简介与 topics 仍需在网页端填）。

---

## 三、关键实测结论（省得重新踩）

### 界面注入

- 视图加载契约：`component = eval(await axios.get('/views/gl-sdk4-ui-<view>.common.js'))`
  - 请求的是**未压缩 `.js`**，所以 `.js` 与 `.gz` 都要装（nginx `gzip_static` 只在原文件存在时生效）
  - **eval 的值必须就是组件对象**。webpack 的 `library` 包裹会返回 Module 包装 → 挂载成空组件
  - `build-ui.js` 因此把产物包成 `(function(){…return window['GL_AI_VIEW_BUNDLE'].default})()`
- 页面全局**没有** `module` / `exports` / `require` / `Vue`；GL 的 Vue 是 **runtime-only** 构建，模板必须预编译
- 菜单来自 `/usr/share/oui/menu.d/*.json`，每请求现读，加文件即生效
- 视图内 i18n 用 `gl_ai.*` 键；菜单标题键是 `menu_gl_ai`

### 后端

- `/rpc` 惰性加载 RPC 对象，**加文件即生效，无需重启 nginx**
- 但 `oui.rpc` 把方法表缓存在模块级 upvalue 里，worker 活着就是旧的 → 入口只暴露一个永不变化的 `rpc` 方法，每次调用 `loadfile` 真实现
- `require` 也有缓存，所以入口还要清掉 `package.loaded` 里的 `glai.*`

### 四条必须遵守的约束（每条都真实踩过）

1. **不能用 `pcall` 包住会 yield 的调用**（ubus、模型请求）。会得到
   `attempt to yield across metamethod/C-call boundary`。
   `xpcall` 同样不行。错误检测改用"步骤标记 + 下次轮询发现"。
2. **不能把 Agent 跑在 `ngx.timer` 里**。定时器上下文禁用子请求，而
   `clients.get_list` 等 RPC 内部用 `ngx.location.capture`，会报
   `./files/rpc.lua:183: API disabled in the current context`。
   现在改为**协作式分步**：前端每次 `poll` 推进一个工作单元。
3. **JSON Schema 的 `required` 不能是空数组**。Lua 空表经 cjson 编码成 `{}`，
   网关直接 400。无参数的工具就完全不发 `properties` / `required`。
   `scripts/glai-check.sh` 与 `selftest` 都会检查这一条。
4. **`ngx.sleep` 会让出协程，多 worker 下文件锁与共享状态都不可靠**。设备上 nginx 有多个 worker，
   所以"用户的选择"用**终态标记文件** `/tmp/gl-ai-agent/decided/<turn>` 表达，`poll` 入口优先检查它，
   而不是指望某个 worker 观察到 approvals 文件的更新。

### 两个 Lua 语言陷阱（各踩一次）

- **`local` 作用域**：`M.sweep_approvals`（文件前部）调用 `load_state`（文件后部定义的 local）
  会解析成全局 nil，运行期直接崩。已改为自包含。
- **`pcall` 返回值**：`local ok, v = pcall(f)` 成功时 `v` 是**结果**而非 nil。
  写成 `if not v then` 会把每次成功都当失败 —— 这个 bug 曾让所有工具调用都报 "malformed arguments"。

### 打包

- **GL/OpenWrt 22.03 的 `.ipk` 是 gzip 包裹的 tar**（内含 `./debian-binary`、`./data.tar.gz`、`./control.tar.gz`），
  **不是 ar**。opkg 对 ar 形式直接报 "Malformed package file"。
- **`.apk` 也是 gzip tar**，所以不能靠魔数区分两者 —— 校验器改为**按内容判断**
  （有 `.PKGINFO` 是 apk，有 `data.tar.gz` 是 ipk）。
- **APKv2 的真实布局（已用 Alpine 3.20 `lua5.1-lzlib` 实物核对）**：
  载荷直接位于压缩包**根目录**（`usr/…`，**没有** `data/` 前缀），维护脚本是根目录下的
  **点前缀成员**（`.post-install`、`.pre-deinstall`），并且**每个成员前面都带一个 PAX 扩展头**
  （`PaxHeaders/<真名>`）。三条最初全写错了，`scripts/check-package-formats.js` 现在按实物形状固化。
  本地回退打包（`build-apk.js` 的 APKv2 分支）已同步修正。
- **APKv3（apk-tools 3）是 ADB 容器，不是 tar**（已用 OpenWrt 25.12 `6rd-13.apk` 实物核对）：
  文件以 `ADBd` 开头，之后是 deflate 压缩的 ADB，全文件**找不到任何 gzip / zstd / ustar 字节**，
  唯一的可读字符串就是 `ADBd` 本身。所以**不要在 Node 里解析 apk v3**（CI 曾因此误判格式、白折腾几轮）：
  CI 的做法是把包 `apk add --root /tmp/apkroot --initdb --allow-untrusted --no-scripts` 装进临时根，
  再用 `check-package.js --installed-root` 对**真实落盘的文件和权限**做断言。
  校验器在没有外部清单时会明确报 FAIL 并提示传 `--installed-root`，不会假装读过。
- **Windows 自带 bsdtar**：不支持 `--owner` / `--group` / `--mtime` / `--mode`，且 `fs.chmodSync` 是空操作
  （文件恒为 0666）。所以 `lib/tar.js` 探测 tar 能力：GNU tar 可用就用它，否则**自己写 ustar** 并显式写入
  每个文件的模式 —— 否则 RPC 对象到不了可执行位，真机装不上。CI 是 Linux，走 GNU tar 分支。
  同理，`--installed-root` 在 Windows 上读到的权限位不可信，校验器会报 "unknown" 并跳过权限断言。
- tar 的 155 字节 **prefix 字段只有 ustar 用**；GNU 格式用 `././@LongLink` 存长名，
  在 GNU 包里读 prefix 会取到垃圾字节。**PAX 头（type `x`）必须按元数据跳过**，
  否则 `PaxHeaders/.PKGINFO` 会被当成真的 `.PKGINFO`（名字以真名结尾，正则必然误中）。

### 其它

- 本地网络上游有自签证书劫持 → `verify_tls: false` 才能连出去
- 前端表单在配置加载完成前不可保存/测试，否则默认值会覆盖已存配置（这个 bug 真实存在过）
- 模型 `deepseek-flash` 可用；`deepseek-chat` 在该网关返回 503
- **模型会先说话再调工具**，所以自动化测试判断"回合结束"要看 busy 标志，不能看"有没有文字"
- **每次恢复出厂后 SSH 主机指纹会变**，脚本里的 `GL_HOSTKEY` 要同步更新

---

## 四、安全须知（两次事故记录）

1. **不要动系统服务**。一次 `reboot` 撞上 procd 的 `ujail` 在 libubox 里段错误，导致进 uboot 重刷。
2. **`ubusd` 会假死**：进程在、socket 在，但不再应答，GL 登录接口因此 500。
   修法（无需重启路由器）：替换 `ubusd` → 重启 `gl-ngx-session`。参见
   `deploy/probe/fix-ubus-noreboot.sh`。
3. **不要用 `Set-Content -Encoding UTF8` 回写源文件**：PowerShell 5 会加 BOM，
   Lua 第 1 行就报错；也会破坏中文字面量。用文件编辑工具，或改完检查前 3 字节。
4. 每轮开始先跑 `node scripts/reset-device.js`，它会清理 `/tmp` 残留并报告设备健康度。

---

## 五、常用命令

```sh
node scripts/build-ui.js                     # 编译视图 bundle
node scripts/build-ipk.js                    # 打 ipk
node scripts/build-apk.js                    # 打 apk
node scripts/check-package.js dist/*.ipk     # 校验包内容
node scripts/check-package.js x.apk --installed-root /tmp/apkroot   # apk v3：对装好的目录断言
node scripts/check-package-formats.js        # 5 种容器 + 清单模式的回归
node scripts/deploy.js                       # 开发直推（不重启 nginx）
node scripts/deploy.js --uninstall           # 完全卸载
node scripts/reset-device.js                 # 清理 /tmp 并报告设备状态
node scripts/glai-check.sh                   # （推送到设备后执行）后端静态+运行时自检

GL_API_KEY=sk-… node scripts/verify-e2e.js        # 浏览器全流程
GL_API_KEY=sk-… node scripts/verify-approval.js   # 确认闸门
```

环境变量：`GL_HOST`（默认 192.168.8.1）、`GL_PASSWORD`、`GL_HOSTKEY`、`GL_API_KEY`。

---

## 六、目录

```
package/data/            安装到路由器的文件树
  usr/lib/oui-httpd/rpc/gl_ai    RPC 入口（唯一稳定方法面 rpc）
  usr/lib/lua/glai/
    agent.lua      单步执行：step_begin / step_pending（可恢复状态机）
    turns.lua      轮次驱动、确认闸门、锁与标记
    events.lua     turn 事件日志（前端按字节偏移增量读取）
    llm.lua        OpenAI / Responses / Anthropic / Gemini，流式与非流式
    tools.lua      工具注册表（单一事实源）
    redact.lua     MAC/IP/密钥脱敏
    session.lua    会话持久化
    config.lua     配置（密钥 0600，永不回显）
    rpc.lua        oui.rpc 薄封装
  www/views/       视图 bundle（.js + .gz）
  www/js/          注入脚本
  www/i18n/        7 种语言
src/ui/GlAiView.vue   前端页面
scripts/
  lib/tar.js        打包归档（GNU tar 优先，否则自带 ustar 写入器）
  build-ui.js       编译视图 bundle
  build-ipk.js      ipk（gzip tar 容器，非 ar）
  build-apk.js      apk（CI 用真 apk mkpkg；本地退化为 APKv2）
  check-bundle.js   断言 eval 契约
  check-package.js  按内容判定容器类型并断言内容
  lint-lua.js       Lua 5.1 语法
  lint-shell.js     BusyBox ash 兼容性
  deploy.js / reset-device.js / test-install.js
  verify-ui.js / verify-e2e.js / verify-approval.js / verify-menu.js
docs/DESIGN.md        功能设计方案
docs/SESSION-NOTES.md 本文
deploy/
  diagnostics/        真机诊断（ubus 修复、trace 查看、turn 冒烟、确认闸门探针）
  packaging-probes/   打包格式与视图加载契约的取证脚本
```

`deploy/diagnostics/restore-and-reboot.sh` 就是那个把路由器送进 uboot 的脚本，留着是为了保留现场记录 ——
不要直接运行。

