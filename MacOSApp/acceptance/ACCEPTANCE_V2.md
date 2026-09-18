# macOS 验收门禁 v2

基线：`801aa5d4bfa6f4dc862c8562122ee0f9296766b2`。日期：2026-09-18。

本次交付实现了门禁报告解析与缺失用例阻断，新增 **28 个精确 XCTest 方法契约**，其中 6 个已存在、22 个产品验收测试待实现。它不是产品修复已完成的证明。不要把带缺失用例的补丁单独合并主分支：与修复和真实测试同一 PR 交付，CI 全绿后合并。故意要求未完成项目红灯，防止再发布重复问题。

## 1. 执行链与证明范围

- CI：source（8 个要求的方法）→构建本次 arm64 App→packaged（5 个 Auth + 15 个界面/交互方法）→验证 App。
- Release：同一 source/packaged 门禁→生成/签名 DMG→挂载并验证 App→针对挂载包 Resources 重跑 packaged→发布。
- `macOS CI / acceptance-gate` 的实际 required check 名应以 GitHub 展示为准；ruleset 要另行配置，YAML 不会自动设置分支保护。
- 共享入口：`MacOSApp/scripts/acceptance-gate.sh` 与 `.github/actions/macos-acceptance/action.yml`；CI、Release 都调用它。
- `required-tests.json.scenarios` 是场景索引；真正机器核对的是 source/auth/packaged 中每个**精确方法名**。仅有类名、文本说明或生成一个同名空测试均不算验收。
- packaged 必须加载本次 App/挂载 DMG 的 Resources；没有资源就失败，不能回退源码。当前 WKWebView harness 不自动等于完整 App 进程测试，原生输入与认证生命周期必须接入真实生产对象或实际 App。
- 真实厂商账号不进入 CI；协议/网络边界可使用本地合成服务。合成服务通过不代表真实服务的 client、scope 和额度权限已验证。

## 2. 当前门禁漏洞及本补丁

旧脚本只检查 manifest 各列表非空，日志转换仅识别 passed/failed，把 skipped 丢掉并固定写 skipped=0。用“无关测试通过 + 必需 Auth 测试跳过”的合成日志复现过假绿灯。

本补丁：
1. 保留失败与跳过、记录已开始未完成的用例；未知 XCTest 行格式直接失败。
2. 每个阶段验证对应必需方法实际通过；缺报告、空报告、失败、error、skip、disabled、缺必需方法均失败。
3. 失败后同名重试通过仍保留失败证据，不能覆写成绿灯。
4. 保留 swift test/tee 管道失败状态；本次生成报告不能抹掉执行失败；运行前清理同名旧 XML。
5. 契约 v2 禁止用类名代替精确方法，接受 XCTest module.Class.testMethod 与 Class.testMethod 的标准命名。
6. 增加 13 项 Python 自测，source 自动运行；扩大 packaged filter 以包含新增测试类。
7. 去掉 required workflow 的 paths-ignore，设置超时；Release 验证挂载 DMG 的 Resources 后再发布，失败时 trap 卸载镜像。

这不能自动识别“测试代码只有 XCTAssertTrue(true)”等语义作弊；代码评审必须核对下面的断言/证据。也不能证明真实系统浏览器和真实厂商 API 成功，需要另附 macOS 真实环境验证。

## 3. 必需方法与验收内容

source 为第 1–8 项，auth 为第 9–13 项，packaged 为第 14–28 项。auth 在 packaged 阶段执行。

| # | 精确方法名 | 必须验证的行为 |
| --- | --- | --- |
| 1 | `AccountCatalogTests.testRandomDefaultsContainUpstreamFullPool` | 基线已有。精确保留 48 条上游随机语句；新增用户内容不覆盖默认库。 |
| 2 | `AccountCatalogTests.testUpstreamFixtureMatchesBundledRendererSnapshot` | 基线已有。打包使用的上游默认队列、choice 权重、字号和图片引用与有来源的 fixture 一致。 |
| 3 | `RateLimitModelsTests.testWhamUsageParsesPrimarySecondaryAndAdditionalBuckets` | 基线已有。解析主、次及额外 Codex 窗口；剩余额度取真实语义。 |
| 4 | `RateLimitModelsTests.testWhamUsageKeepsUnknownValuesUnknown` | 基线已有。缺字段、空响应、错误对象保留 unknown，不伪造 0/100。 |
| 5 | `RateLimitModelsTests.testInvalidPercentNeverBecomesZeroOrOneHundred` | 基线已有。拒绝非法百分比，合法 0 与 100 可区分。 |
| 6 | `BindingModelTests.testLegacyModelIDMigrationIsIdempotentAndLossless` | 待实现。modelId→accountId 的无损幂等迁移；明确 false、样式、随机库、资源与歧义绑定不丢失。 |
| 7 | `BindingModelTests.testMoneyAndSubscriptionMetricsKeepUnitsAndUnknowns` | 待实现。money/percent/quantity 类型分离、有限数校验、单位、稳定窗口 ID、0/unknown/stale；不能用第一个账户替换绑定。 |
| 8 | `BubbleStateTests.testDataRefreshPreservesStepChoiceAndDeadline` | 待实现。数据刷新不改变当前步骤、随机选择、关闭期限和用户配置；配置重置显式清除旧值。 |
| 9 | `BrowserAuthAcceptanceTests.testCodexLoginAndQuotaWithoutCLIOrCodexHome` | 待实现。没有 CLI/.codex，使用 App 原生 OAuth→本地回调→合成 token/usage 服务→账户状态/额度；不替换认证服务为直接成功 stub。 |
| 10 | `BrowserAuthAcceptanceTests.testCallbacksRejectMismatchReplayAndLateCompletion` | 待实现。state/PKCE/回调归属验证、重放、取消、超时、拒绝、迟到回调；各厂商按真实协议实现对应保护。 |
| 11 | `BrowserAuthAcceptanceTests.testRefreshAndDisconnectUseIsolatedNativeCredentials` | 待实现。原生隔离 Keychain 持久化、token 轮换 single-flight、401 有限重试、多账户与退出后的旧响应；WebView/日志无凭据。 |
| 12 | `BrowserAuthAcceptanceTests.testProviderCapabilityFlowsAndQuotaScopeFailures` | 待实现。遍历声明支持的厂商，测试浏览器授权/设备授权和 quota scope；不支持能力有明确状态，不能全降级以通过。 |
| 13 | `BrowserAuthAcceptanceTests.testSettingsShowsOneAuthFlowPerAccountAndNoCodexPaths` | 待实现。真实 Settings 账户页面每个账号一套操作，无路径/CLI/session 输入；两个同厂商账号无重复 DOM ID 和串号。 |
| 14 | `WidgetWebViewTests.testPackagedWidgetHasVisibleWhaleAcrossLayoutsAndFallback` | 基线已有。保持并加强真实资源下的人偶完整可见、底部锚点、各缩放档位及资源失败后备；无黑底/黑框。 |
| 15 | `BubbleNativeAcceptanceTests.testDefaultContinuousClicksAdvanceExactlyOnce` | 待实现。未经自定义的新安装配置，真实生产原生输入逐次推进；默认两项队列的关闭/重开与随机分支精确正确。 |
| 16 | `BubbleNativeAcceptanceTests.testSavedClickEffectsAndTapAdvanceSurviveRestart` | 待实现。通过正常设置保存 true/false 及多种效果，重启仍生效；显式 false 保留既定上游行为，不误判为输入丢失。 |
| 17 | `BubbleNativeAcceptanceTests.testFastAndSlowClicksWorkDuringPanelResize` | 待实现。快点/慢点/动画中点击各≥30次，面板展开、收起、不同缩放后仍逐次正确，无双重分发或丢失。 |
| 18 | `BubbleNativeAcceptanceTests.testDraggingAndMenuClicksDoNotAdvanceQueue` | 待实现。累计拖动不推进队列、clickCount>1 正常；侧边按钮、右键菜单可点且不被裁切，取消/失焦后可恢复。 |
| 19 | `BubbleBindingAcceptanceTests.testEnabledAccountsPopulateBalanceModuleOptions` | 待实现。余额模块来源选项来自规范账户目录；可选 Codex 窗口、DeepSeek 金额、其他支持指标；未登录状态准确。 |
| 20 | `BubbleBindingAcceptanceTests.testSavedBindingsRenderFetchedMetricsInRealClickBubble` | 待实现。模拟 HTTP→生产解析器→正常设置选源保存→真实人偶点击→断言数值/单位/窗口与时间；0/unknown/stale 都覆盖。 |
| 21 | `BubbleBindingAcceptanceTests.testDisabledDeletedAndSameProviderAccountsStayIsolated` | 待实现。两个同厂商账户、禁用、删除、窗口消失、乱序/迟到刷新不串号；失效绑定可见且不静默改指第一账户。 |
| 22 | `BubbleEditorAcceptanceTests.testQueueModuleAndRandomEditorsStayInSettingsFlow` | 待实现。队列/步骤/模块/随机语句/嵌套编辑全部普通流布局，无全屏遮罩或独立内容窗口；导航、焦点、主栏滚动可用。 |
| 23 | `BubbleEditorAcceptanceTests.testDraftSurvivesRefreshAndNavigationWithoutDuplicateHandlers` | 待实现。后台刷新/重复切页不丢草稿、不过度重建 DOM，不重复绑定监听；未保存导航有明确策略，取消可恢复。 |
| 24 | `BubbleEditorAcceptanceTests.testSaveAndRestartChangeActualClickBubble` | 待实现。设置修改、保存、重开、重启→原生点击气泡确实使用新文本/模板/字号/顺序/数据源，预览同源。 |
| 25 | `BubbleLayoutAcceptanceTests.testMultilineContentFitsSafeShapeAtEverySupportedScale` | 待实现。每个真实支持缩放档位和翻转方向测 1/3/6/10 行、多账户/长词/emoji/图文；每个可见字形行框均在 SVG 安全区内。 |
| 26 | `BubbleLayoutAcceptanceTests.testLongContentPaginatesAtReadableMinimumWithoutLosingMetrics` | 待实现。到达约定可读字号下限后分页，所有文本/指标保留且顺序正确；不靠剪裁、透明或省略伪装成功。 |
| 27 | `BubbleLayoutAcceptanceTests.testShortContentRestoresSizeWithoutMutatingSavedStyle` | 待实现。长→短→长与≥100次打开/刷新后字体恢复；用户 base 样式未被改写、DOM 不累积、异步过期回调无效。 |
| 28 | `BubbleNativeAcceptanceTests.testUpstreamRandomPoolWeightsAndClickEffectsArePreserved` | 待实现。使用真实编辑器更改随机语句、权重/库引用和已支持点击效果；注入确定性 RNG 只控制随机源，验证分支边界，不用概率抽样易抖测试。 |

## 4. 测试设计要求

### 原生输入
新安装默认配置与经设置保存配置分别测试；不可在每个用例开头都强行开启 tapAdvance 掩盖默认值错误。
不要在一个同步 JS for 循环内完成全部“连点”；让 run loop、动画、面板 resize 真正有机会执行。
可以通过生产 NSPanel/控制器构造 NSEvent 测试，不依赖全局辅助功能鼠标权限。只调用 JS whaleClick/nativePointerUp 不能单独满足原生路径要求。
每次输入后断言步骤/关闭/重开/效果计数；最终“还显示某一条文字”不能代替顺序正确。

### Auth
用厂商实际协议建测试服务，走生产授权管理器、真实回调验证、token 交换、原生存储、额度 HTTP 客户端和 UI。
模拟浏览器打开仅替代外部启动边界，不能用“点击桥事件出现”当登录成功；不依赖已装 CLI 或本地 auth。
不支持浏览器授权的厂商必须明确展示限制，同时保留原有可用方式；支持的适配器逐一执行契约。
Keychain 测试按测试运行隔离，结束清理自己的项；不碰用户官方 CLI 凭据。token/cookie/bearer 不写日志或 WebView。

### 数据绑定
用可区分的账号与数值，按正常 UI 选择保存，再验证真实点击内容，不能只测预览。
两个同 provider 的账号、合法 0、unknown、stale、禁用/删除、乱序回包都必须可识别。
缺少上游 modelId 的映射应提示修复，不允许悄悄选第一个账号。
迁移不能清空随机列表、图片/音效或用户字号。

### 页内编辑
断言 computed position/backdrop/主栏几何与实际点击导航，不仅是节点父子关系。
覆盖所有嵌套编辑入口、保存/取消、刷新时草稿、重启。正常文件选择器不算“内容编辑弹窗”。

### 字体与溢出
从现有设置枚举全部档位。检查真实可见字形的行框、图片边界、全文与分页顺序、字号下限。
至少记录泡泡 SVG 主体安全区、可见文本行框、基础/应用字号与页面截图；光测容器 scrollHeight 或截图一张不能替代完整断言。
自动字号调整不能写回用户配置，短内容恢复，异步资源加载后重算且不推进步骤。
极长内容应有可读的续页，不以 overflow:hidden/透明度/字体趋近 0 使几何测试绿灯。

## 5. 证据与运行

建议产物目录：`$RUNNER_TEMP/ai-balance-whale-acceptance`。
现有 source.log/source.xml、packaged.log/packaged.xml 和新增 gate-parser.log/source-static.log；DMG 二次结果在 dmg/。
产品测试需要补充截图、几何 JSON、脱敏配置、source SHA 和资源 hash（本补丁没有假造这些产品证据）。
upload-artifact 保留 always()，CI 失败也上传已有诊断，不得记录真实登录态。

Apple Silicon macOS 仓库根目录：
```bash
python3 -m unittest discover -s MacOSApp/acceptance -p 'test_acceptance_report.py' -v
bash MacOSApp/scripts/acceptance-gate.sh source
SIGNING_MODE=ad-hoc bash MacOSApp/scripts/build.sh
WHALE_WIDGET_RESOURCE_ROOT="$PWD/MacOSApp/dist/AI Balance Whale.app/Contents/Resources" bash MacOSApp/scripts/acceptance-gate.sh packaged
```

执行顺序不要用 continue-on-error 绕过前一步。source 目前应因 3 个新增纯逻辑方法缺失而失败；其他阶段还有 19 个待实现方法。不要删掉要求来“恢复 CI”。

在本次交付环境（Linux）已验证门禁解析器 13 项自测和 shell 语法；无法运行 Swift/AppKit、系统浏览器、arm64 App、DMG 安装或真实账号授权。所有对应产品结果仍未验证。

## 6. 产品修复时需要同步清理的旧约束

- verify-source.sh 仍要求 CLI 文案、CodexAppServerClient 等旧实现。实现对应新行为测试后删除这些过时 grep；不要靠死代码满足它们。
- 旧 testPackagedSettingsMountsUpstreamEditorDirectly 的弹窗样式断言需要更新；保留有用回归，不保留错误目标。
- 原生测试目前的 target 依赖需要调整。最小化抽取生产逻辑为可测试模块，不可复制一套假实现。
- Release 说明必须写 App-owned browser OAuth、Keychain 和 WHAM usage；不得把旧的 local stdio app-server 作为 macOS App 运行前提。
- 发布到真实 GitHub 需要仓库写权限。本交付没有推送、配置 ruleset 或发布 Release。
