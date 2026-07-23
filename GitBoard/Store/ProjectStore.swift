import Foundation
import SwiftUI

@MainActor
@Observable
final class ProjectStore {
    var projects: [Project] = []
    var selectedProjectId: String? {
        didSet {
            UserDefaults.standard.set(selectedProjectId, forKey: "selectedProjectId")
        }
    }

    // nil means "All", otherwise filter by status name
    var selectedStatusFilter: String? {
        didSet {
            UserDefaults.standard.set(selectedStatusFilter, forKey: "selectedStatusFilter")
        }
    }

    var isLoading = false
    var error: Error?
    var lastUpdated: Date?
    var currentUserLogin: String?

    private var pollingTask: Task<Void, Never>?
    private var previousItemStatuses: [String: String?] = [:]

    private let notificationService = NotificationService.shared
    private let gitHubService = GitHubService.shared

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    var pollInterval: TimeInterval = 45

    var filteredItems: [ProjectItem] {
        guard let project = selectedProject else { return [] }
        guard let filter = selectedStatusFilter else { return project.items }
        return project.items.filter { $0.status == filter }
    }

    init() {
        selectedProjectId = UserDefaults.standard.string(forKey: "selectedProjectId")
        selectedStatusFilter = UserDefaults.standard.string(forKey: "selectedStatusFilter")
    }

    func loadProjects() async {
        isLoading = true
        error = nil

        do {
            // Fetch current user login for @me support
            if currentUserLogin == nil {
                currentUserLogin = try? await gitHubService.getCurrentUserLogin()
            }

            projects = try await gitHubService.fetchProjects()

            if selectedProjectId == nil, let firstProject = projects.first {
                selectedProjectId = firstProject.id
            }

            if let selectedId = selectedProjectId {
                await loadProjectDetails(id: selectedId)
            }

            lastUpdated = Date()
        } catch {
            self.error = error
        }

        isLoading = false
    }

    func loadProjectDetails(id: String) async {
        do {
            let detailedProject = try await gitHubService.fetchProjectWithItems(id: id)

            if let index = projects.firstIndex(where: { $0.id == id }) {
                let oldItems = projects[index].items
                await detectStatusChanges(oldItems: oldItems, newItems: detailedProject.items)

                projects[index] = Project(
                    id: projects[index].id,
                    title: projects[index].title,
                    number: projects[index].number,
                    url: projects[index].url,
                    owner: projects[index].owner,
                    statusField: detailedProject.statusField,
                    items: detailedProject.items
                )
            }

            lastUpdated = Date()
        } catch {
            self.error = error
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        guard let selectedId = selectedProjectId else {
            await loadProjects()
            return
        }

        await loadProjectDetails(id: selectedId)
    }

    func startPolling() {
        stopPolling()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 45))

                if Task.isCancelled { break }

                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func detectStatusChanges(oldItems: [ProjectItem], newItems: [ProjectItem]) async {
        let oldStatusMap = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0.status) })

        for newItem in newItems {
            guard let oldStatus = oldStatusMap[newItem.id] else {
                continue
            }

            if oldStatus != newItem.status {
                let fromStatus = oldStatus ?? "No Status"
                let toStatus = newItem.status ?? "No Status"

                await notificationService.sendStatusChangeNotification(
                    itemTitle: newItem.title,
                    fromStatus: fromStatus,
                    toStatus: toStatus
                )
            }
        }
    }

    func selectProject(_ project: Project) async {
        selectedProjectId = project.id
        await loadProjectDetails(id: project.id)
    }

    func moveItem(_ item: ProjectItem, toStatus status: StatusOption) async {
        guard let project = selectedProject,
              let fieldId = project.statusField?.id,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - create new item with updated status
        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            status: status.name,
            statusOptionId: status.id,
            assignees: item.assignees,
            linkedPR: item.linkedPR
        )

        // Create new items array and replace the entire project to trigger @Observable update
        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            title: project.title,
            number: project.number,
            url: project.url,
            owner: project.owner,
            statusField: project.statusField,
            items: newItems
        )

        // Then sync with server
        do {
            try await gitHubService.updateItemStatus(
                projectId: project.id,
                itemId: item.id,
                fieldId: fieldId,
                optionId: status.id
            )
            lastUpdated = Date()
        } catch {
            // Revert on error - restore original project
            projects[projectIndex] = originalProject
            self.error = error
        }
    }

    func deleteItem(_ item: ProjectItem) async {
        guard let project = selectedProject else { return }

        do {
            try await gitHubService.deleteItem(projectId: project.id, itemId: item.id)
            await refresh()
        } catch {
            self.error = error
        }
    }

    func searchUsers(query: String) async -> [Assignee] {
        do {
            return try await gitHubService.searchUsers(query: query)
        } catch {
            self.error = error
            return []
        }
    }

    func addAssignee(to item: ProjectItem, user: Assignee) async {
        guard let url = item.url,
              let project = selectedProject,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - add assignee to local state
        var newAssignees = item.assignees
        if !newAssignees.contains(where: { $0.login == user.login }) {
            newAssignees.append(user)
        }

        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
            linkedPR: item.linkedPR
        )

        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            title: project.title,
            number: project.number,
            url: project.url,
            owner: project.owner,
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.addAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            self.error = error
        }
    }

    func removeAssignee(from item: ProjectItem, user: Assignee) async {
        guard let url = item.url,
              let project = selectedProject,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - remove assignee from local state
        let newAssignees = item.assignees.filter { $0.login != user.login }

        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
            linkedPR: item.linkedPR
        )

        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            title: project.title,
            number: project.number,
            url: project.url,
            owner: project.owner,
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.removeAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            self.error = error
        }
    }

    /// Parsed result from quick create input
    struct QuickCreateInput {
        let title: String
        let labels: [String]
        let assignees: [String]
    }

    /// Parse quick create input like ">title #label1 #label2 @user"
    func parseQuickCreateInput(_ input: String) -> QuickCreateInput? {
        var text = input
        guard text.hasPrefix(">") else { return nil }
        text.removeFirst()
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var labels: [String] = []
        var assignees: [String] = []
        var titleParts: [String] = []

        let words = text.components(separatedBy: .whitespaces)
        for word in words {
            if word.hasPrefix("#") && word.count > 1 {
                labels.append(String(word.dropFirst()))
            } else if word.hasPrefix("@") && word.count > 1 {
                assignees.append(String(word.dropFirst()))
            } else if !word.isEmpty {
                titleParts.append(word)
            }
        }

        let title = titleParts.joined(separator: " ")
        guard !title.isEmpty else { return nil }

        return QuickCreateInput(title: title, labels: labels, assignees: assignees)
    }

    /// Create a draft issue (no labels/assignees)
    func createDraftIssue(title: String) async {
        guard let project = selectedProject else { return }

        do {
            _ = try await gitHubService.createDraftIssue(projectId: project.id, title: title)
            await refresh()
        } catch {
            self.error = error
        }
    }

    /// Create a real issue with labels and assignees (project workflow will auto-add it)
    func createIssue(title: String, labels: [String], assignees: [String]) async {
        guard let project = selectedProject else { return }

        do {
            // Get repo from existing issues in the project
            if let repo = try await gitHubService.getProjectRepository(projectId: project.id) {
                try await gitHubService.createIssue(
                    owner: repo.owner,
                    repo: repo.repo,
                    title: title,
                    labels: labels,
                    assignees: assignees
                )
            } else {
                // No repository found, create draft issue instead
                _ = try await gitHubService.createDraftIssue(projectId: project.id, title: title)
            }
            await refresh()
        } catch {
            self.error = error
        }
    }

    /// Quick create from parsed input - always tries to create a real issue if repo is linked
    func quickCreate(_ input: QuickCreateInput) async {
        await createIssue(title: input.title, labels: input.labels, assignees: input.assignees)
    }
}
