# 慕容显示增强 v2.9.39
## v2.9.39

1. **补回 WebUI 启动加载页的样式**：v2.9.37 提交时带进了启动遮罩的 DOM
   （`#boot-overlay`）与显示/隐藏逻辑，但配套的 CSS 一直没有进入仓库，导致那个
   全屏加载页渲染成一个无样式的空 div —— 看起来就是"加载页没有了"。本版补齐
   `.boot-overlay` / `.boot-spinner` / `.boot-text` / `.boot-hint` 与旋转动画，
   并把 `style.css` / `main.js` 的缓存串号推到 `2.9.39-web3`。
2. 自适应刷新率相关的其它行为不变（原厂 LTPS 空闲降到 60Hz、完美禁用 ADFR
   锁定所选刷新率）。

