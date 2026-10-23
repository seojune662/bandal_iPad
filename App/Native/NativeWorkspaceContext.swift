import Foundation

/// The visible workspace is independent of the course that owns an open file.
/// Project identity comes from its manifest, so moving its folder keeps its tabs.
struct NativeWorkspaceContext: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case course, project }
    var kind: Kind
    var courseID: String
    var projectID: String? = nil
    var rootRelPath: String = ""
    var title: String
    var linkedCourseID: String? = nil

    var id: String { kind == .course ? "course:" + courseID : "project:" + (projectID ?? courseID + ":" + rootRelPath) }
    var binding: NativeLearningBinding? { kind == .project ? NativeLearningBinding(courseID: courseID, rootRelPath: rootRelPath) : nil }
    var request: [String: Any] {
        var value: [String: Any] = ["id": id, "kind": kind.rawValue, "courseId": courseID, "rootRelPath": rootRelPath, "title": title]
        if let projectID { value["projectId"] = projectID }
        if let linkedCourseID { value["linkedCourseId"] = linkedCourseID }
        return value
    }
    static func course(_ course: NativeCourse) -> Self { .init(kind: .course, courseID: course.id, title: course.name) }
    static func project(_ summary: NativeLearningSummary, courses: [NativeCourse] = []) -> Self {
        .init(kind: .project, courseID: summary.binding.courseID, projectID: summary.projectId,
              rootRelPath: summary.binding.rootRelPath, title: summary.displayName(courses: courses), linkedCourseID: summary.linkedCourseId)
    }
    static func project(snapshot: [String: Any]) -> Self? {
        guard let raw = snapshot["binding"] as? [String: Any], let course = raw["courseId"] as? String,
              let root = raw["rootRelPath"] as? String, let project = snapshot["projectId"] as? String else { return nil }
        return .init(kind: .project, courseID: course, projectID: project, rootRelPath: root,
                     title: snapshot["name"] as? String ?? "프로젝트", linkedCourseID: snapshot["linkedCourseId"] as? String)
    }
    @MainActor static func loadProject(store: NativeWorkspaceStore, binding: NativeLearningBinding) async throws -> Self {
        let snapshot = try await store.invoke("learning:get", ["binding": binding.request]) as? [String: Any] ?? [:]
        guard let context = project(snapshot: snapshot) else { throw DesktopRuntimeError("프로젝트를 불러오지 못했습니다.") }
        return context
    }
    func contains(path: String) -> Bool { rootRelPath.isEmpty || path == rootRelPath || path.hasPrefix(rootRelPath + "/") }
}

struct NativeLearningDocumentTarget: Codable, Hashable {
    enum Kind: String, Codable { case article, artifact, overview }
    var projectID: String
    var binding: NativeLearningBinding
    var kind: Kind
    var entityID: String
    var id: String { "learning:" + projectID + ":" + kind.rawValue + ":" + entityID }

    func document(title: String) -> NativeDocumentReference {
        .init(courseID: binding.courseID, relativePath: binding.rootRelPath, title: title, kind: "learning", learningTarget: self)
    }
}
