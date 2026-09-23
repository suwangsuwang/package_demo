import Foundation

/// 把「接口路径 + 查询参数 + 请求体」拼成 `URLRequest`。
///
/// 域名来自本地配置文件（`BuildConfig`），因此这里不写死任何 host。
/// **不做 Token 注入** —— 那是 `APIClient` 的唯一职责。
extension URLRequest {

    static func yunxiao(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        // 每次拼请求时重新读一次配置文件：文件很小，读取开销可忽略，
        // 换来「改完配置直接重试即可生效」，不必重启 App。
        let config = try BuildConfig.load()
        guard let domain = config.domainURL else {
            throw APIError.configurationMissing("yunxiaoDomain")
        }

        let url = domain.appending(path: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(path)
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let finalURL = components.url else {
            throw APIError.invalidURL(path)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
