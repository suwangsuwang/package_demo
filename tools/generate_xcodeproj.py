#!/usr/bin/env python3
"""生成 AndroidBuildClient.xcodeproj/project.pbxproj。

一次性脚本：改动文件列表后重新运行即可。之所以用脚本而不是手写 pbxproj，
是因为对象 ID 交叉引用很多，手写容易出错。
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_DIR = "AndroidBuildClient"
TEST_DIR = "AndroidBuildClientTests"
APP_TARGET = "AndroidBuildClient"
TEST_TARGET = "AndroidBuildClientTests"
BUNDLE_ID = "com.wangsu.AndroidBuildClient"
DEPLOYMENT_TARGET = "27.0"

_counter = 0


def uid():
    global _counter
    _counter += 1
    return "AB{:022X}".format(_counter)


# ---------------------------------------------------------------- 目录结构

# (group 路径片段, [文件名])
APP_GROUPS = [
    ("App", ["AndroidBuildClientApp.swift", "AppModel.swift", "RootView.swift"]),
    ("Features/Token", ["TokenSetupView.swift", "TokenSetupViewModel.swift"]),
    (
        "Features/Build",
        [
            "BuildView.swift",
            "BuildViewModel.swift",
            "BuildLogParser.swift",
            "BuildResultView.swift",
            "BuildResultViewModel.swift",
            "HistoryView.swift",
            "HistoryViewModel.swift",
        ],
    ),
    (
        "Core/Network",
        ["APIClient.swift", "APIError.swift", "YunxiaoEndpoint.swift"],
    ),
    (
        "Core/Authentication",
        ["AuthService.swift", "KeychainService.swift", "TokenStore.swift"],
    ),
    (
        "Core/Flow",
        [
            "BuildService.swift",
            "FlowService.swift",
            "FlowServiceError.swift",
            "PipelineRunStatus.swift",
            "StepLog.swift",
        ],
    ),
    ("Core/Configuration", ["AppConfiguration.swift", "BuildConfig.swift"]),
    (
        "Core/Codeup",
        ["CodeupService.swift", "CodeupServiceError.swift", "RepositoryMatcher.swift"],
    ),
    ("Core/Platform", ["URLLauncher.swift"]),
    (
        "Models",
        [
            "BuildArtifacts.swift",
            "BuildResult.swift",
            "BuildRunIdentity.swift",
            "BuildState.swift",
            "CodeupBranch.swift",
            "CodeupRepository.swift",
            "PipelineInfo.swift",
            "PipelineRun.swift",
            "PipelineRunDetail.swift",
            "PipelineStep.swift",
            "YunxiaoUser.swift",
        ],
    ),
]

TEST_FILES = [
    "TestSupport.swift",
    "KeychainServiceTests.swift",
    "APIClientTests.swift",
    "AppConfigurationTests.swift",
    "CodeupServiceTests.swift",
    "RepositoryMatcherTests.swift",
    "FlowServiceTests.swift",
    "BuildServiceTests.swift",
    "BuildViewModelTests.swift",
    "BuildResultViewModelTests.swift",
    "BuildRunIdentityTests.swift",
    "BuildLogParserTests.swift",
]


def check_file_lists():
    """校验上面的清单与磁盘一致。

    清单里写错一个文件名，Xcode 只会报一句难懂的编译错误，
    所以在生成前就把"列了不存在的文件"和"漏列了磁盘上的文件"挡住。
    """
    listed = {os.path.join(PROJECT_DIR, *path.split("/"), name)
              for path, files in APP_GROUPS for name in files}
    listed |= {os.path.join(TEST_DIR, name) for name in TEST_FILES}

    on_disk = set()
    for directory in (PROJECT_DIR, TEST_DIR):
        for root, _, files in os.walk(os.path.join(ROOT, directory)):
            for name in files:
                if name.endswith(".swift"):
                    on_disk.add(os.path.relpath(os.path.join(root, name), ROOT))

    missing = sorted(on_disk - listed)
    stale = sorted(listed - on_disk)
    assert not missing, f"磁盘上有文件没写进清单：{missing}"
    assert not stale, f"清单里有文件在磁盘上不存在：{stale}"


check_file_lists()


def nested_groups(specs):
    """把 "A/B" 形式的路径折叠成嵌套的 PBXGroup 树。

    返回 (顶层子对象 ID 列表, 分组对象表, 顶层 (id, name) 对)。
    """
    tree = {}
    for path, files in specs:
        node = tree
        for part in path.split("/"):
            node = node.setdefault(part, {"__files__": {}})
        node["__files__"].update({name: None for name in files})

    objects = {}

    def walk(node):
        """返回 (该节点下的 (id, name) 列表, 递归收集到的所有文件节点)。

        目录在前、文件在后，和 Xcode 自己的排序一致。
        """
        pairs = []
        files = []
        for name in sorted(k for k in node if k != "__files__"):
            child = node[name]
            gid = uid()
            sub_pairs, sub_files = walk(child)
            objects[gid] = {
                "isa": "PBXGroup",
                "children": [i for i, _ in sub_pairs],
                "path": name,
                "sourceTree": "<group>",
            }
            pairs.append((gid, name))
            files.extend(sub_files)
        # 根节点自身不对应任何目录，因此可能没有 __files__。
        for filename in sorted(node.get("__files__", ())):
            fid = uid()
            objects[fid] = {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "path": filename,
                "sourceTree": "<group>",
            }
            pairs.append((fid, filename))
            files.append((fid, filename))
        return pairs, files

    top_pairs, file_pairs = walk(tree)
    return [i for i, _ in top_pairs], objects, file_pairs


app_child_ids, group_objects, app_pairs = nested_groups(APP_GROUPS)

# 测试目录是扁平的
test_file_objects = {}
test_pairs = []
for filename in TEST_FILES:
    fid = uid()
    test_file_objects[fid] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "sourcecode.swift",
        "path": filename,
        "sourceTree": "<group>",
    }
    test_pairs.append((fid, filename))

# ---------------------------------------------------------------- 对象表

objects = {}
objects.update(group_objects)
objects.update(test_file_objects)

def add(obj_id, value):
    objects[obj_id] = value


# --- 产品文件引用
app_product_ref = uid()
add(app_product_ref, {
    "isa": "PBXFileReference",
    "explicitFileType": "wrapper.application",
    "includeInIndex": 0,
    "path": f"{APP_TARGET}.app",
    "sourceTree": "BUILT_PRODUCTS_DIR",
})

test_product_ref = uid()
add(test_product_ref, {
    "isa": "PBXFileReference",
    "explicitFileType": "wrapper.cfbundle",
    "includeInIndex": 0,
    "path": f"{TEST_TARGET}.xctest",
    "sourceTree": "BUILT_PRODUCTS_DIR",
})

# --- 源文件构建条目
def build_files(pairs):
    ids = []
    for fid, _ in pairs:
        bid = uid()
        add(bid, {
            "isa": "PBXBuildFile",
            "fileRef": fid,
        })
        ids.append(bid)
    return ids


app_build_file_ids = build_files(app_pairs)
test_build_file_ids = build_files(test_pairs)

# 编译阶段为空会产出"能编译但没有 .swiftmodule"的空壳 target，
# 测试 target 随后会以 "Unable to resolve module dependency" 失败。
# 这里直接拦住。
assert app_build_file_ids, f"{APP_TARGET} 的 Sources 阶段为空，检查 APP_GROUPS"
assert test_build_file_ids, f"{TEST_TARGET} 的 Sources 阶段为空，检查 TEST_FILES"

# --- 构建阶段
app_sources = uid()
add(app_sources, {
    "isa": "PBXSourcesBuildPhase",
    "buildActionMask": 2147483647,
    "files": app_build_file_ids,
    "runOnlyForDeploymentPostprocessing": 0,
})

app_frameworks = uid()
add(app_frameworks, {
    "isa": "PBXFrameworksBuildPhase",
    "buildActionMask": 2147483647,
    "files": [],
    "runOnlyForDeploymentPostprocessing": 0,
})

app_resources = uid()
add(app_resources, {
    "isa": "PBXResourcesBuildPhase",
    "buildActionMask": 2147483647,
    "files": [],
    "runOnlyForDeploymentPostprocessing": 0,
})

test_sources = uid()
add(test_sources, {
    "isa": "PBXSourcesBuildPhase",
    "buildActionMask": 2147483647,
    "files": test_build_file_ids,
    "runOnlyForDeploymentPostprocessing": 0,
})

test_frameworks = uid()
add(test_frameworks, {
    "isa": "PBXFrameworksBuildPhase",
    "buildActionMask": 2147483647,
    "files": [],
    "runOnlyForDeploymentPostprocessing": 0,
})

test_resources = uid()
add(test_resources, {
    "isa": "PBXResourcesBuildPhase",
    "buildActionMask": 2147483647,
    "files": [],
    "runOnlyForDeploymentPostprocessing": 0,
})

# --- 构建配置：工程级
def project_settings(debug):
    settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEAD_CODE_STRIPPING": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "macosx",
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        # app target 由测试 target `@testable import`，必须产出 .swiftmodule。
        "SWIFT_INSTALL_MODULE": "YES",
        "SWIFT_INSTALL_MODULE_FOR_DEPENDENCIES": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
        "SWIFT_VERSION": "6.0",
    }
    if debug:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        })
    else:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
        })
    return settings


def target_settings(debug):
    return {
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        # 内部工具：关闭沙盒，避免第二阶段下载/保存 APK 时受容器限制。
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "",
        "INFOPLIST_KEY_NSPrincipalClass": "NSApplication",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }


def test_target_settings(debug):
    return {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}Tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP_TARGET}.app/Contents/MacOS/{APP_TARGET}",
    }


def configs(settings_debug, settings_release):
    ids = {}
    for label, settings in (("Debug", settings_debug), ("Release", settings_release)):
        cid = uid()
        add(cid, {
            "isa": "XCBuildConfiguration",
            "buildSettings": settings,
            "name": label,
        })
        ids[label] = cid
    list_id = uid()
    add(list_id, {
        "isa": "XCConfigurationList",
        "buildConfigurations": [ids["Debug"], ids["Release"]],
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Release",
    })
    return list_id


project_config_list = configs(project_settings(True), project_settings(False))
app_config_list = configs(target_settings(True), target_settings(False))
test_config_list = configs(test_target_settings(True), test_target_settings(False))

# --- 目标依赖
container_proxy = uid()
add(container_proxy, {
    "isa": "PBXContainerItemProxy",
    "containerPortal": "{PROJECT_ID}",
    "proxyType": 1,
    "remoteGlobalIDString": "{APP_TARGET_ID}",
    "remoteInfo": APP_TARGET,
})

# --- 目标
app_target_id = uid()
add(app_target_id, {
    "isa": "PBXNativeTarget",
    "buildConfigurationList": app_config_list,
    "buildPhases": [app_sources, app_frameworks, app_resources],
    "buildRules": [],
    "dependencies": [],
    "name": APP_TARGET,
    "productName": APP_TARGET,
    "productReference": app_product_ref,
    "productType": "com.apple.product-type.application",
})

# 依赖对象必须在 app_target_id 生成之后再建
target_dependency = uid()
add(target_dependency, {
    "isa": "PBXTargetDependency",
    "target": app_target_id,
    "targetProxy": container_proxy,
})

test_target_id = uid()
add(test_target_id, {
    "isa": "PBXNativeTarget",
    "buildConfigurationList": test_config_list,
    "buildPhases": [test_sources, test_frameworks, test_resources],
    "buildRules": [],
    "dependencies": [target_dependency],
    "name": TEST_TARGET,
    "productName": TEST_TARGET,
    "productReference": test_product_ref,
    "productType": "com.apple.product-type.bundle.unit-test",
})

objects[container_proxy]["remoteGlobalIDString"] = app_target_id

# --- 分组：主组 / 产品组
products_group = uid()
add(products_group, {
    "isa": "PBXGroup",
    "children": [app_product_ref, test_product_ref],
    "name": "Products",
    "sourceTree": "<group>",
})

app_group = uid()
add(app_group, {
    "isa": "PBXGroup",
    "children": app_child_ids,
    "path": PROJECT_DIR,
    "sourceTree": "<group>",
})

test_group = uid()
add(test_group, {
    "isa": "PBXGroup",
    "children": [i for i, _ in test_pairs],
    "path": TEST_DIR,
    "sourceTree": "<group>",
})

main_group = uid()
add(main_group, {
    "isa": "PBXGroup",
    "children": [app_group, test_group, products_group],
    "sourceTree": "<group>",
})

# --- 工程
project_id = uid()
add(project_id, {
    "isa": "PBXProject",
    "attributes": {
        "BuildIndependentTargetsInParallel": 1,
        "LastSwiftUpdateCheck": 2700,
        "LastUpgradeCheck": 2700,
        "TargetAttributes": {
            app_target_id: {"CreatedOnToolsVersion": "27.0"},
            test_target_id: {"CreatedOnToolsVersion": "27.0", "TestTargetID": app_target_id},
        },
    },
    "buildConfigurationList": project_config_list,
    "compatibilityVersion": "Xcode 14.0",
    "developmentRegion": "en",
    "hasScannedForEncodings": 0,
    "knownRegions": ["en", "Base"],
    "mainGroup": main_group,
    "minimizedProjectReferenceProxies": 1,
    "preferredProjectObjectVersion": 77,
    "productRefGroup": products_group,
    "projectDirPath": "",
    "projectRoot": "",
    "targets": [app_target_id, test_target_id],
})

objects[container_proxy]["containerPortal"] = project_id

# ---------------------------------------------------------------- 序列化

SECTION_ORDER = [
    "PBXBuildFile",
    "PBXContainerItemProxy",
    "PBXFileReference",
    "PBXFrameworksBuildPhase",
    "PBXGroup",
    "PBXNativeTarget",
    "PBXProject",
    "PBXResourcesBuildPhase",
    "PBXSourcesBuildPhase",
    "PBXTargetDependency",
    "XCBuildConfiguration",
    "XCConfigurationList",
]

SECTION_TITLES = {
    "PBXBuildFile": "PBXBuildFile section",
    "PBXContainerItemProxy": "PBXContainerItemProxy section",
    "PBXFileReference": "PBXFileReference section",
    "PBXFrameworksBuildPhase": "PBXFrameworksBuildPhase section",
    "PBXGroup": "PBXGroup section",
    "PBXNativeTarget": "PBXNativeTarget section",
    "PBXProject": "PBXProject section",
    "PBXResourcesBuildPhase": "PBXResourcesBuildPhase section",
    "PBXSourcesBuildPhase": "PBXSourcesBuildPhase section",
    "PBXTargetDependency": "PBXTargetDependency section",
    "XCBuildConfiguration": "XCBuildConfiguration section",
    "XCConfigurationList": "XCConfigurationList section",
}

# 文件名表，用于给对象加 /* 注释 */
names = {}
for fid, name in app_pairs + test_pairs:
    names[fid] = name
names[app_product_ref] = f"{APP_TARGET}.app"
names[test_product_ref] = f"{TEST_TARGET}.xctest"
names[app_target_id] = APP_TARGET
names[test_target_id] = TEST_TARGET


def comment_for(obj_id, value):
    isa = value["isa"]
    if obj_id in names:
        return names[obj_id]
    if isa == "PBXBuildFile":
        return names.get(value["fileRef"], "")
    if isa in ("PBXNativeTarget", "PBXTargetDependency"):
        return ""
    if isa == "XCBuildConfiguration":
        return value["name"]
    if isa == "XCConfigurationList":
        return "Build configuration list"
    return ""


def fmt_value(value, indent):
    pad = "\t" * indent
    if isinstance(value, dict):
        inner = "".join(
            f"{pad}\t{k} = {fmt_value(v, indent + 1)};\n" for k, v in sorted(value.items())
        )
        return "{\n" + inner + pad + "}"
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        inner = "".join(f"{pad}\t{fmt_value(v, indent + 1)},\n" for v in value)
        return "(\n" + inner + pad + ")"
    if isinstance(value, str):
        if value == "":
            return '""'
        # 需要引号的字符集
        safe = all(c.isalnum() or c in "._/$" for c in value)
        return value if safe else '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))
    return str(value)


lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]

for section in SECTION_ORDER:
    ids = [i for i, v in objects.items() if v["isa"] == section]
    if not ids:
        continue
    lines.append(f"\n/* Begin {SECTION_TITLES[section]} */")
    for obj_id in sorted(ids):
        value = objects[obj_id]
        comment = comment_for(obj_id, value)
        head = f"\t\t{obj_id}"
        if comment:
            head += f" /* {comment} */"
        lines.append(f"{head} = {fmt_value(value, 2)};")
    lines.append(f"/* End {SECTION_TITLES[section]} */")

lines.append("\t};")
lines.append(f"\trootObject = {project_id} /* Project object */;")
lines.append("}")

out_dir = os.path.join(ROOT, f"{APP_TARGET}.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
content = "\n".join(lines) + "\n"
# containerPortal 需要指向 PBXProject 的 ID，而该 ID 在 ContainerItemProxy 之后才生成，
# 所以先用占位符，序列化时再回填。
content = content.replace("{PROJECT_ID}", project_id)
with open(os.path.join(out_dir, "project.pbxproj"), "w") as handle:
    handle.write(content)

# ---------------------------------------------------------------- scheme

# scheme 里的 BlueprintIdentifier 必须等于 target 的对象 ID。它不随 pbxproj 一起生成的话，
# 一旦增删文件导致 ID 变化，Xcode 就找不到可运行目标 —— 而命令行 `xcodebuild` 靠
# BlueprintName 兜底仍然能跑通，于是问题只在"从 Xcode 点 Run"时暴露，很难定位。
# 所以这里和 pbxproj 用同一批变量一起产出，杜绝漂移。
SCHEME_DIR = os.path.join(out_dir, "xcshareddata", "xcschemes")
os.makedirs(SCHEME_DIR, exist_ok=True)


def buildable_reference(target_id, name, buildable_name):
    return f"""               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{buildable_name}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{APP_TARGET}.xcodeproj">"""


scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
{buildable_reference(app_target_id, APP_TARGET, f"{APP_TARGET}.app")}
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
{buildable_reference(test_target_id, TEST_TARGET, f"{TEST_TARGET}.xctest")}
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
{buildable_reference(app_target_id, APP_TARGET, f"{APP_TARGET}.app")}
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
{buildable_reference(app_target_id, APP_TARGET, f"{APP_TARGET}.app")}
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

scheme_path = os.path.join(SCHEME_DIR, f"{APP_TARGET}.xcscheme")
with open(scheme_path, "w") as handle:
    handle.write(scheme)

print(f"wrote {out_dir}/project.pbxproj ({len(objects)} objects)")
print(f"wrote {scheme_path}")
