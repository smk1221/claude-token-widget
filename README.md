<p align="center">
  <img src="icon_1024.png" width="140" alt="TokenWidget icon">
</p>

<h1 align="center">Claude Token 用量小组件 🦀</h1>

<p align="center">
macOS 原生桌面悬浮小组件 · Liquid Glass 毛玻璃质感 · 实时显示 Claude 用量与套餐限额<br>
自带一只心情随用量变化的桌宠小螃蟹
</p>

---

## 安装(3 行命令)

```bash
git clone https://github.com/smk1221/claude-token-widget.git
cd claude-token-widget && ./build.sh
open ~/Applications/TokenWidget.app
```

**要求**:macOS 13+;Xcode 命令行工具(没装的话执行 `xcode-select --install`,一次即可)。
本地编译,无需处理 macOS「未验证开发者」拦截。

首次使用:点击小组件里的「**使用 Claude 账号登录**」→ 浏览器授权 → 自动完成。每个人用自己的 Claude 账号,数据互不相干。

> 💡 「今日费用」和活动图读取的是本机 Claude Code 的对话日志,最适合 Claude Code 用户;套餐用量进度条对所有 Claude 订阅用户有效。

## 功能

- **今日费用**:每 2 秒增量读取 `~/.claude/projects/**/*.jsonl`,按官方定价折算美元(含缓存读 0.1×、缓存写 1.25×/2× 精确计价),对话时实时跳动,带 LIVE 呼吸灯
- **活动图**:近 60 分钟每分钟 token 柱状图,可切换近 7 天每日费用统计
- **套餐用量**(官方接口,与 Claude 设置里 Usage 页同源):当前会话 / 本周全部模型 / 本周分模型三条进度条 + 重置倒计时,≥90% 变红,每 60 秒刷新
- **菜单栏常驻**:实时显示会话百分比 + 迷你进度条,颜色随用量变化(绿→黄→橙→红);左键弹出/收起面板,右键菜单(刷新 / 开机自启 / 退出)
- **90% 预警**:会话用量达 90% 时屏幕顶部弹出液态玻璃提示,3 秒后消散分解,每个窗口只提醒一次
- **全局热键 ⌃⌥T**:显示/隐藏(系统级注册,无需任何权限,不干扰打字)

## 桌宠小螃蟹 🦀

卡片顶上住着一只纯矢量绘制的小螃蟹,心情跟真实用量联动:

| 状态 | 触发条件 | 表现 |
|---|---|---|
| 😌 待机 | 无任务 | 眨眼、摇摆、闲逛、随机开合钳子 |
| ⚡ 打工 | 2 分钟内有 token 消耗 | 双钳交替敲击 |
| 😓 疲惫 | 会话用量 ≥80% | 头上冒汗 |
| 😱 恐慌 | 会话用量 ≥95% | 张嘴发抖狂奔 |
| 💤 睡觉 | 30 分钟无活动 | 闭眼飘 💤 |

单击→跳跃+说话(报费用/百分比/倒计时/俏皮话);双击→转圈;悬停→举钳夹击打招呼;窗口重置时自动庆祝。

## 隐私与安全

- 登录用与 Claude Code 完全相同的**官方 OAuth(PKCE)流程**,只申请 `user:profile user:inference` 最小权限
- 令牌仅保存在本机 `~/.claude/widget-token.json`(权限 600),自动续期,**绝不离开你的电脑**
- 若本机装有 Claude Code CLI 并已登录,会直接复用其凭证,无需重复登录
- 诊断日志 `~/Library/Logs/TokenWidget.log` 只记录状态码与用量数字,不含任何凭证
- 全部代码就一个 Swift 文件,欢迎审计

## 常用操作

| 操作 | 方式 |
|---|---|
| 显示 / 隐藏 | ⌃⌥T,或点菜单栏图标,或点面板右上 ✕(仅隐藏) |
| 移动位置 | 直接拖动面板,位置自动记忆 |
| 真正退出 | 右键菜单栏图标 → 退出 |
| 重新打开 | Spotlight 搜「TokenWidget」,或勾选右键菜单里的「开机自启」 |
| 改热键 / 定价 / 配色 | 改 `TokenWidget.swift` 后重新 `./build.sh` |
| 重新生成图标 | `swift IconGen.swift && ./build.sh` |

## 定价表(美元 / 百万 token,用于「今日费用」)

| 模型 | 输入 | 输出 |
|---|---|---|
| Fable 5 / Mythos 5 | $10 | $50 |
| Opus 4.x | $5 | $25 |
| Sonnet 4.6 / 5 | $3 | $15 |
| Haiku 4.5 | $1 | $5 |

缓存读取 = 0.1× 输入价;缓存写入 = 1.25×(5 分钟 TTL)/ 2×(1 小时 TTL)输入价。官方调价后请同步修改 `TokenWidget.swift` 里的 `Pricing`。

## License

MIT
