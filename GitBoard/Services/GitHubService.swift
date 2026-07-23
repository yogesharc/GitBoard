import Foundation

enum GitHubError: Error, LocalizedError {
    case ghCLINotFound
    case notAuthenticated
    case graphQLError(String)
    case decodingError(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .ghCLINotFound:
            return "GitHub CLI (gh) not found. Please install it from https://cli.github.com"
        case .notAuthenticated:
            return "Not authenticated with GitHub. Run 'gh auth login' in Terminal."
        case .graphQLError(let message):
            return "GitHub API error: \(message)"
        case .decodingError(let message):
            return "Failed to parse response: \(message)"
        case .processError(let message):
            return "Process error: \(message)"
        }
    }
}

actor GitHubService {
    static let shared = GitHubService()

    private var ghPath: String?

    private init() {}

    private func findGHPath() async throws -> String {
        if let path = ghPath {
            return path
        }

        let possiblePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                ghPath = path
                return path
            }
        }

        let whichResult = try await runCommand("/usr/bin/which", arguments: ["gh"])
        let path = whichResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            ghPath = path
            return path
        }

        throw GitHubError.ghCLINotFound
    }

    private func runCommand(_ command: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw GitHubError.processError(errorString)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    func getAuthToken() async throws -> String {
        let ghPath = try await findGHPath()
        let result = try await runCommand(ghPath, arguments: ["auth", "token"])
        let token = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if token.isEmpty {
            throw GitHubError.notAuthenticated
        }

        return token
    }

    func isAuthenticated() async -> Bool {
        do {
            _ = try await getAuthToken()
            return true
        } catch {
            return false
        }
    }

    func getCurrentUserLogin() async throws -> String {
        let data = try await executeGraphQL(query: GraphQLQueries.currentUser)

        struct ViewerResponse: Codable {
            let data: DataContainer
            struct DataContainer: Codable {
                let viewer: Viewer
            }
            struct Viewer: Codable {
                let login: String
            }
        }

        let response = try JSONDecoder().decode(ViewerResponse.self, from: data)
        return response.data.viewer.login
    }

    func executeGraphQL(query: String, variables: [String: String] = [:]) async throws -> Data {
        let ghPath = try await findGHPath()

        var arguments = ["api", "graphql", "-f", "query=\(query)"]

        for (key, value) in variables {
            arguments.append("-f")
            arguments.append("\(key)=\(value)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = arguments

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw GitHubError.graphQLError(errorString)
        }

        return data
    }

    func fetchProjects() async throws -> [Project] {
        let data = try await executeGraphQL(query: GraphQLQueries.listProjects)

        do {
            let response = try JSONDecoder().decode(ProjectsListResponse.self, from: data)

            // Personal projects (owner = nil)
            var allProjects = response.data.viewer.projectsV2.nodes.map { node in
                Project(
                    id: node.id,
                    title: node.title,
                    number: node.number,
                    url: node.url,
                    owner: nil
                )
            }

            // Organization projects
            if let orgs = response.data.viewer.organizations {
                for org in orgs.nodes {
                    let orgProjects = org.projectsV2.nodes.map { node in
                        Project(
                            id: node.id,
                            title: node.title,
                            number: node.number,
                            url: node.url,
                            owner: org.login
                        )
                    }
                    allProjects.append(contentsOf: orgProjects)
                }
            }

            return allProjects
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    func fetchProjectWithItems(id: String) async throws -> Project {
        let data = try await executeGraphQL(
            query: GraphQLQueries.projectWithItems,
            variables: ["id": id]
        )

        do {
            let response = try JSONDecoder().decode(ProjectDetailResponse.self, from: data)
            let node = response.data.node

            let statusField = node.fields.nodes
                .first { $0.name == "Status" && $0.options != nil }
                .map { field in
                    StatusField(
                        id: field.id ?? "",
                        name: field.name ?? "Status",
                        options: field.options?.map { option in
                            StatusOption(id: option.id, name: option.name, color: option.color)
                        } ?? []
                    )
                }

            let items = node.items.nodes.compactMap { itemNode -> ProjectItem? in
                let contentData = itemNode.content

                let contentType: ItemContentType
                switch contentData?.typename {
                case "Issue": contentType = .issue
                case "PullRequest": contentType = .pullRequest
                default: contentType = .draftIssue
                }

                let issueState: IssueState?
                let prState: PullRequestState?

                if contentType == .issue {
                    issueState = contentData?.state.flatMap { IssueState(rawValue: $0) }
                    prState = nil
                } else if contentType == .pullRequest {
                    issueState = nil
                    prState = contentData?.state.flatMap { PullRequestState(rawValue: $0) }
                } else {
                    issueState = nil
                    prState = nil
                }

                let assignees = contentData?.assignees?.nodes.map { node in
                    Assignee(login: node.login, avatarUrl: node.avatarUrl, name: node.name)
                } ?? []

                // Parse linked PR if available (only for issues closed by PRs)
                let linkedPR: LinkedPR?
                if let prNode = contentData?.closedByPullRequestsReferences?.nodes.first {
                    linkedPR = LinkedPR(
                        number: prNode.number,
                        title: prNode.title,
                        url: prNode.url,
                        merged: prNode.merged,
                        closed: prNode.closed
                    )
                } else {
                    linkedPR = nil
                }

                return ProjectItem(
                    id: itemNode.id,
                    contentId: contentData?.url,  // Use URL as proxy for content ID
                    contentType: contentType,
                    title: contentData?.title ?? "Untitled",
                    number: contentData?.number,
                    url: contentData?.url,
                    issueState: issueState,
                    prState: prState,
                    status: itemNode.fieldValueByName?.name,
                    statusOptionId: itemNode.fieldValueByName?.optionId,
                    assignees: assignees,
                    linkedPR: linkedPR
                )
            }

            return Project(
                id: id,
                title: node.title,
                number: 0,
                url: "",
                statusField: statusField,
                items: items
            )
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    func updateItemStatus(projectId: String, itemId: String, fieldId: String, optionId: String) async throws {
        _ = try await executeGraphQL(
            query: GraphQLQueries.updateItemStatus,
            variables: [
                "projectId": projectId,
                "itemId": itemId,
                "fieldId": fieldId,
                "optionId": optionId
            ]
        )
    }

    func deleteItem(projectId: String, itemId: String) async throws {
        _ = try await executeGraphQL(
            query: GraphQLQueries.deleteItem,
            variables: [
                "projectId": projectId,
                "itemId": itemId
            ]
        )
    }

    func searchUsers(query: String) async throws -> [Assignee] {
        let data = try await executeGraphQL(
            query: GraphQLQueries.searchUsers,
            variables: ["query": query]
        )

        do {
            let response = try JSONDecoder().decode(UserSearchResponse.self, from: data)
            return response.data.search.nodes.compactMap { node in
                guard let login = node.login, let avatarUrl = node.avatarUrl else { return nil }
                return Assignee(login: login, avatarUrl: avatarUrl, name: node.name)
            }
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    func getUserId(login: String) async throws -> String {
        let data = try await executeGraphQL(
            query: GraphQLQueries.getUser,
            variables: ["login": login]
        )

        do {
            let response = try JSONDecoder().decode(GetUserResponse.self, from: data)
            guard let user = response.data.user else {
                throw GitHubError.graphQLError("User not found")
            }
            return user.id
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    func addAssignee(issueUrl: String, userLogin: String) async throws {
        // Extract owner/repo/number from URL like https://github.com/owner/repo/issues/123
        guard let components = parseIssueUrl(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }

        let ghPath = try await findGHPath()

        // Use gh CLI to add assignee (simpler than GraphQL for this)
        _ = try await runCommand(ghPath, arguments: [
            "issue", "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repo)",
            "--add-assignee", userLogin
        ])
    }

    func removeAssignee(issueUrl: String, userLogin: String) async throws {
        guard let components = parseIssueUrl(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }

        let ghPath = try await findGHPath()

        _ = try await runCommand(ghPath, arguments: [
            "issue", "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repo)",
            "--remove-assignee", userLogin
        ])
    }

    private func parseIssueUrl(_ url: String) -> (owner: String, repo: String, number: Int)? {
        // Parse https://github.com/owner/repo/issues/123 or https://github.com/owner/repo/pull/123
        let pattern = #"github\.com/([^/]+)/([^/]+)/(issues|pull)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges == 5 else {
            return nil
        }

        guard let ownerRange = Range(match.range(at: 1), in: url),
              let repoRange = Range(match.range(at: 2), in: url),
              let numberRange = Range(match.range(at: 4), in: url),
              let number = Int(url[numberRange]) else {
            return nil
        }

        return (String(url[ownerRange]), String(url[repoRange]), number)
    }

    /// Create a draft issue in a project
    func createDraftIssue(projectId: String, title: String) async throws -> String {
        let data = try await executeGraphQL(
            query: GraphQLQueries.addDraftIssue,
            variables: [
                "projectId": projectId,
                "title": title
            ]
        )

        struct Response: Codable {
            let data: DataContainer
            struct DataContainer: Codable {
                let addProjectV2DraftIssue: DraftIssueResult
            }
            struct DraftIssueResult: Codable {
                let projectItem: ProjectItem
            }
            struct ProjectItem: Codable {
                let id: String
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data.addProjectV2DraftIssue.projectItem.id
    }

    /// Create a real issue using gh CLI (project workflow will auto-add it)
    func createIssue(
        owner: String,
        repo: String,
        title: String,
        labels: [String] = [],
        assignees: [String] = []
    ) async throws {
        let ghPath = try await findGHPath()

        var arguments = [
            "issue", "create",
            "--repo", "\(owner)/\(repo)",
            "--title", title,
            "--body", ""  // Required when not running interactively
        ]

        if !labels.isEmpty {
            arguments.append("--label")
            arguments.append(labels.joined(separator: ","))
        }

        if !assignees.isEmpty {
            arguments.append("--assignee")
            arguments.append(assignees.joined(separator: ","))
        }

        _ = try await runCommand(ghPath, arguments: arguments)
    }

    /// Get issue node ID from URL using gh CLI (simpler than GraphQL)
    private func getIssueId(from url: String) async throws -> String {
        guard let components = parseIssueUrl(url) else {
            throw GitHubError.graphQLError("Invalid issue URL: \(url)")
        }

        let ghPath = try await findGHPath()

        // Use gh api to get the issue node_id
        let result = try await runCommand(ghPath, arguments: [
            "api",
            "repos/\(components.owner)/\(components.repo)/issues/\(components.number)",
            "--jq", ".node_id"
        ])

        let nodeId = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if nodeId.isEmpty {
            throw GitHubError.graphQLError("Could not get issue ID")
        }
        return nodeId
    }

    /// Get issue node ID from URL (unused - keeping for reference)
    private func getIssueIdGraphQL(from url: String) async throws -> String {
        guard let components = parseIssueUrl(url) else {
            throw GitHubError.graphQLError("Invalid issue URL: \(url)")
        }

        let query = """
            query($owner: String!, $repo: String!, $number: Int!) {
                repository(owner: $owner, name: $repo) {
                    issue(number: $number) {
                        id
                    }
                }
            }
            """

        // Note: GraphQL requires actual Int type, not String
        let ghPath = try await findGHPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "api", "graphql",
            "-f", "query=\(query)",
            "-F", "owner=\(components.owner)",
            "-F", "repo=\(components.repo)",
            "-F", "number=\(components.number)"  // -F for non-string types
        ]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        struct Response: Codable {
            let data: DataContainer
            struct DataContainer: Codable {
                let repository: Repository
            }
            struct Repository: Codable {
                let issue: Issue
            }
            struct Issue: Codable {
                let id: String
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data.repository.issue.id
    }

    /// Get the linked repository for a project by looking at existing issues
    func getProjectRepository(projectId: String) async throws -> (owner: String, repo: String)? {
        // Fetch project items and extract repo from the first issue URL
        let data = try await executeGraphQL(
            query: GraphQLQueries.projectWithItems,
            variables: ["id": projectId]
        )

        let response = try JSONDecoder().decode(ProjectDetailResponse.self, from: data)

        // Find the first item with a valid issue/PR URL
        for item in response.data.node.items.nodes {
            if let url = item.content?.url,
               let components = parseIssueUrl(url) {
                return (components.owner, components.repo)
            }
        }

        return nil
    }
}
