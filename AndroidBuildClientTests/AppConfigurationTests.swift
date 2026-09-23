import Foundation
import Testing

@testable import AndroidBuildClient

/// 接口路径的测试。
///
/// 这组断言的存在理由很具体：运行详情与 Job 相关接口**前缀不同**
/// （`/runs/{id}` 对 `/pipelineRuns/{id}/jobs/...`），
/// 用错的那一个会返回 404，而错误提示看起来像"域名或流水线 ID 配错了"，
/// 排查方向会被带偏。把字面路径钉在这里，改错立刻红。
@Suite("接口路径")
struct AppConfigurationTests {

    private static let org = "org-123"
    private static let pipeline = "5000001"

    // MARK: - 运行详情：/runs

    @Test("运行详情走 /runs/{pipelineRunId}，不是 /pipelineRuns")
    func pipelineRunUsesRunsPrefix() {
        let path = AppConfiguration.Path.pipelineRun(
            organizationId: Self.org,
            pipelineId: Self.pipeline,
            pipelineRunId: "31"
        )

        #expect(path == "/oapi/v1/flow/organizations/org-123/pipelines/5000001/runs/31")
        #expect(!path.contains("/pipelineRuns/"))
    }

    @Test("运行 ID 是拼进去的，不是常量")
    func pipelineRunPathCarriesTheRunID() {
        func path(_ runID: String) -> String {
            AppConfiguration.Path.pipelineRun(
                organizationId: Self.org,
                pipelineId: Self.pipeline,
                pipelineRunId: runID
            )
        }

        #expect(path("30") != path("31"))
        #expect(path("31").hasSuffix("/runs/31"))
        #expect(path("999").hasSuffix("/runs/999"))
    }

    // MARK: - Job / Step / 日志：/pipelineRuns

    @Test("步骤列表走 /pipelineRuns/{pipelineRunId}/jobs/{jobId}/steps")
    func stepsUsePipelineRunsPrefix() {
        let path = AppConfiguration.Path.steps(
            organizationId: Self.org,
            pipelineId: Self.pipeline,
            pipelineRunId: "31",
            jobId: "6000002"
        )

        #expect(
            path
                == "/oapi/v1/flow/organizations/org-123/pipelines/5000001"
                + "/pipelineRuns/31/jobs/6000002/steps"
        )
    }

    @Test("步骤日志走 /pipelineRuns/{pipelineRunId}/jobs/{jobId}/step/log")
    func stepLogUsesPipelineRunsPrefix() {
        let path = AppConfiguration.Path.stepLog(
            organizationId: Self.org,
            pipelineId: Self.pipeline,
            pipelineRunId: "31",
            jobId: "6000002"
        )

        #expect(
            path
                == "/oapi/v1/flow/organizations/org-123/pipelines/5000001"
                + "/pipelineRuns/31/jobs/6000002/step/log"
        )
        // `/runs/{id}/jobs/...` 实测是 404，不能被拼出来。
        #expect(!path.contains("/runs/31/jobs"))
    }

    @Test("jobId 与 buildId 都随参数变化，路径里不出现固定值")
    func jobPathsCarryTheirIdentifiers() {
        func steps(job: String) -> String {
            AppConfiguration.Path.steps(
                organizationId: Self.org,
                pipelineId: Self.pipeline,
                pipelineRunId: "31",
                jobId: job
            )
        }

        #expect(steps(job: "1") != steps(job: "2"))
        #expect(steps(job: "6000002").contains("/jobs/6000002/"))
    }

    // MARK: - 其余路径

    @Test("触发与历史记录共用 /runs（POST 与 GET 同一路径）")
    func triggerAndHistoryShareTheSamePath() {
        let path = AppConfiguration.Path.pipelineRuns(
            organizationId: Self.org,
            pipelineId: Self.pipeline
        )

        #expect(path == "/oapi/v1/flow/organizations/org-123/pipelines/5000001/runs")
    }

    @Test("流水线详情路径不带 /runs")
    func pipelineInfoPath() {
        let path = AppConfiguration.Path.pipeline(
            organizationId: Self.org,
            pipelineId: Self.pipeline
        )

        #expect(path == "/oapi/v1/flow/organizations/org-123/pipelines/5000001")
    }

    @Test("用户信息路径与组织无关")
    func currentUserPath() {
        #expect(AppConfiguration.Path.currentUser == "/oapi/v1/platform/user")
    }

    // MARK: - 常量

    @Test("日志读取固定 offset=0、limit=10000，不按行数分段")
    func stepLogWindowIsWholeLog() {
        #expect(AppConfiguration.stepLogOffset == 0)
        #expect(AppConfiguration.stepLogLimit == 10_000)
    }

    @Test("日志标记与 Gradle 脚本的输出一致")
    func logMarkers() {
        #expect(AppConfiguration.LogMarker.uploadCompleted == "上传完成->")
        #expect(AppConfiguration.LogMarker.qrCodeAddress == "二维码地址->")
    }
}
