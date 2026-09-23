import Foundation

/// 当前 Token 对应的 Yunxiao 用户。
///
/// 接口：`GET /oapi/v1/platform/user`
/// ```json
/// {
///   "id": "用户 ID",
///   "name": "用户姓名",
///   "email": "用户邮箱",
///   "lastOrganization": "最近使用的组织",
///   "createdAt": "2024-04-08T08:00:51.512Z"
/// }
/// ```
///
/// ⚠️ 上面是**字段名与类型**的说明，值一律用占位符 —— 本仓库是公开的，
/// 不要在这里贴真实响应（真实响应里带着姓名和公司邮箱）。
///
/// 字段名与类型已通过真实请求确认。这个类型同时承担两件事：
/// 展示当前登录者，以及**证明 Token 有效** —— Token 无效时这个接口会返回 401/403。
struct YunxiaoUser: Sendable, Equatable, Decodable {
    let id: String
    let name: String
    let email: String
    let lastOrganization: String
    let createdAt: String
}
