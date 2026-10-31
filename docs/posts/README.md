# 论坛帖子

两版文案，同一套图：

| 文件 | 面向 | 语言 |
|---|---|---|
| [`enshan.md`](enshan.md) | 恩山无线论坛（国内） | 中文 |
| [`glinet-forum.md`](glinet-forum.md) | GL.iNet 官方海外论坛（forum.gl-inet.com） | English |

## 图片（`images/` 目录，按此顺序上传）

| 文件 | 内容 | 用在哪 |
|---|---|---|
| `01-menu.png` | 原生侧边栏「系统 → GL-AI助手」，证明是注入原生后台而不是另开页面 | 两版都用 |
| `02-chat.png` | 对话首页：标题、快捷提问、作者署名 | 两版都用 |
| `03-confirm.png` | 真实动作：先读 WiFi 配置，再弹确认卡（参数 + 影响 + 倒计时 44s） | 两版都用（安全章节） |
| `04-markdown.png` | 回复里的 markdown 表格 / 行内代码渲染 | 两版都用 |
| `05-settings.png` | 设置面板：API 地址、模型、Key、协议、写操作权限 | 两版都用（配置章节） |
| `06-dark.png` | 暗色主题，跟随 GL 原生主题令牌 | 两版都用 |

所有截图都已处理过：模型名替换成中性的 `deepseek-chat`，WiFi 名称用 `<SSID>` 占位，
不含网关地址、API Key、主机指纹等任何本机信息。

## 发帖注意

**恩山（Discuz）**

- 图片要在编辑器里**上传**（不要外链）：`raw.githubusercontent.com` 在国内经常打不开，
  外链图大概率显示成红叉。上传后把正文里的 `图1`～`图6` 放在对应位置。
- 标题最多约 80 字，正文里已经给了一个可直接用的标题。
- 帖子带外链，建议保留文末的「开源 / 非商业 / 免责」三行，避免被当成广告。

**GL 官方论坛（Discourse）**

- 支持 Markdown 和粘贴上传图片：把 `images/` 里的图按顺序拖进编辑器，或先上传再插到对应位置。
- 标题别带 "official"，正文里已经写明是社区项目、与 GL.iNet 官方无关。
- 可以同时发到 `Feature Requests`（作为讨论）或 `Community`；如果管理员认为放错区，按他们要求移动即可。

## 关于 Release 链接

两版文案里的下载地址都是：

```
https://github.com/XIAOZHAOXSXH/gl-ai-agent/releases
```

`main` 每推一次都会刷新当前版本那个 release，资产名带版本号（如 `gl-ai-agent_0.1.0_all.ipk`）。
版本号变化时记得同步改文案里的文件名（第 7 节的两条安装命令）。
