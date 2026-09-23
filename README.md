# AndroidBuildClient

macOS 原生客户端（SwiftUI + Swift 6），用于登录阿里云 Flow 流水线、触发 Android Test 环境打包，
并从流水线步骤日志中提取 APK 下载地址与二维码地址。

**当前进度：第一阶段（骨架）已完成。** 真实阿里云登录、Flow API、钉钉发送均未实现，见文末「第一阶段边界」。

## 环境要求

- macOS 27.0+
- Xcode 27.0+（Swift 6 严格并发）
- 无第三方依赖，不需要 CocoaPods / SPM 拉取

## 运行

```bash
open AndroidBuildClient.xcodeproj
```

在 Xcode 中选择 `AndroidBuildClient` scheme → Run。或者命令行：

```bash
xcodebuild -project AndroidBuildClient.xcodeproj -scheme AndroidBuildClient \
  -destination 'platform=macOS' -configuration Debug build

xcodebuild -project AndroidBuildClient.xcodeproj -scheme AndroidBuildClient \
  -destination 'platform=macOS' test
```

## 目录结构

```
AndroidBuildClient/
  App/                    AndroidBuildClientApp.swift, AppModel.swift, RootView.swift
  Features/Login/         LoginView.swift, LoginViewModel.swift
  Features/Build/         BuildView.swift, BuildViewModel.swift
  Core/Network/           APIClient.swift, APIClientProtocol.swift, APIError.swift
  Core/Authentication/    AuthService.swift, AuthServiceProtocol.swift, KeychainService.swift
  Core/Flow/              FlowService.swift, FlowServiceError.swift, StepLog.swift
  Core/Configuration/     AppConfiguration.swift
  Models/                 BuildResult.swift, BuildStatus.swift
AndroidBuildClientTests/  FlowServiceLogParsingTests.swift
tools/                    generate_xcodeproj.py
```

调用链：View → ViewModel → Service → APIClient。没有 Repository / UseCase / Coordinator / DI 容器。

> `Core/Flow/` 不在原始目录建议里，但 BuildViewModel 需要调用 FlowService，所以单独成目录。

## 关于 .xcodeproj

`AndroidBuildClient.xcodeproj` 由 `tools/generate_xcodeproj.py` 生成，并且**已提交到仓库**。
之所以用脚本生成，是因为 pbxproj 里对象 ID 交叉引用较多，手写易错。

**增删源文件后**，编辑脚本顶部的 `APP_GROUPS` / `TEST_FILES`，然后重新生成：

```bash
python3 tools/generate_xcodeproj.py
```

脚本只依赖 Python 标准库，不需要安装任何东西。若新增了编译阶段文件却没更新 `APP_GROUPS`，
脚本会直接 assert 失败——这是刻意为之：空的 Sources 阶段会产出「能编译但没有 `.swiftmodule`」
的空壳 target，并在测试时报出难以定位的 `Unable to resolve module dependency`。

## 日志解析规则

第一阶段唯一实现的真实逻辑，位于 `Core/Flow/FlowService.swift` 的协议扩展中，
不依赖网络，因此可以脱离凭据单测：

- 取日志中**最后一次**出现的 `上传完成->` 之后、直到空白字符为止的内容作为 APK 下载地址
- 取 `二维码地址->` 同理，作为二维码图片地址
- 标记不存在、或标记后没有内容 → 对应字段为 `nil`（`BuildResult` 允许两个字段独立为空）

`BuildView` 里有一个「日志解析验证（第一阶段）」折叠区，可以粘贴日志即时看到解析结果，
不需要登录也不需要流水线。其中示例日志用的是占位域名 `apk.example.com`。

## 第一阶段边界

按规格第 18 章，以下内容**未实现且不打算在本阶段实现**：

- 真实阿里云登录（`AuthService.signIn` 抛 `notImplemented`）
- 真实 Flow API 调用（`FlowService` 的三个网络方法均抛 `notImplemented`）
- 钉钉发送、Android Gradle 改动、数据库、第三方 UI/网络库

具体表现：点「开始打包」会得到「状态：构建失败」以及文案「触发流水线尚未接入真实流水线接口（第二阶段）。」，
这是预期的占位行为，不是缺陷。

`AppConfiguration` 中的 `flowBaseURL` / `organizationID` / `testPipelineID` 全部为 `nil`——
原始 API 地址、organizationId 与认证信息需在第二阶段提供，未做任何猜测性填写。

登录页提供了「跳过登录，查看打包页面」按钮，仅用于本阶段能走到 Home 页面；
接入真实登录后应当移除。

## 第二阶段待办

1. 真实登录（`AuthService` + `KeychainService` 落盘）
2. 触发流水线 / 查询状态 / 拉取 Step Log 的真实请求与响应结构（`StepLog` 已按已验证的
   `{ last, logs, more }` 结构建好模型）
3. 补全 `AppConfiguration` 的端点配置
4. 移除登录页的跳过按钮
