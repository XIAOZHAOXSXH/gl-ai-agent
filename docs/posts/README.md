# 论坛帖子

两版文案，同一套图。风格按两边真实帖子的写法来：不写"功能介绍—特性列表—路线图"那种结构，
就是一个人把折腾过程说一遍，技术细节和坑放在前面，缺点直接承认。

| 文件 | 面向 | 语言 | 格式 |
|---|---|---|---|
| [`enshan.md`](enshan.md) | 恩山无线论坛 | 中文 | **纯文本**，直接粘进 Discuz |
| [`glinet-forum.md`](glinet-forum.md) | GL.iNet 官方海外论坛（forum.gl-inet.com） | English | Markdown（Discourse 原生支持） |

## 图片（`images/` 目录）

| 文件 | 内容 | 恩山 | GL 论坛 |
|---|---|---|---|
| `01-menu.png` | 原生侧边栏「系统 → GL-AI助手」 | 图1 | ✔ |
| `02-chat.png` | 对话首页、作者署名 | 图2 | — |
| `03-confirm.png` | 先只读配置，再弹确认卡（倒计时 44s） | 图3 | ✔ |
| `04-markdown.png` | 回复里的表格渲染 | 图4 | ✔ |
| `05-settings.png` | 设置面板 | 图5 | — |
| `06-dark.png` | 暗色主题 | 图6 | — |

截图都是在当前版本上实拍的：模型名换成了中性的 `deepseek-chat`，WiFi 名称是 `<SSID>`，
没有网关地址、Key、主机指纹。

## 发帖注意

**恩山（Discuz X3.5）**

- 正文是**纯文本**，没有 `#` 标题、没有 `**加粗**`、没有 markdown 表格 —— Discuz 不渲染这些，
  粘过去会原样显示成一堆符号。中文序号、缩进命令、`［图N：说明］` 这些可以直接用。
- 图片必须**上传**再插入（`raw.githubusercontent.com` 在国内基本打不开，外链图会是红叉）。
  把正文里的 `［图1：…］` 整行换成上传后的图片即可。
- 标题带了 `【原创】` 前缀，恩山的习惯叫法；正文里已经写明"非GL官方、自用为主"，避免被当广告。

**GL 论坛（Discourse）**

- 支持 Markdown，把 `images/` 里的三张图拖进编辑器，插到对应位置就行。
- 标题是陈述句，不带 "official"；正文第二段就写明不是外挂页面、不改 nginx 配置，
  这点 GL 官方的人看帖子会关心。
- 结尾主动请人报"哪个模型不好用"，比"求测试"更容易得到回复。

## Release 链接

两版都指向：

```
https://github.com/XIAOZHAOXSXH/gl-ai-agent/releases
```

`main` 每推一次会刷新当前版本那个 release。**版本号变了记得改文案里的两个包名**
（`gl-ai-agent_0.1.0_all.ipk` / `gl-ai-agent-0.1.0-r1.apk`）。
