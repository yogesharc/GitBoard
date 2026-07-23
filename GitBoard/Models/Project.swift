import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let number: Int
    let url: String
    var owner: String?
    var statusField: StatusField?
    var items: [ProjectItem]

    init(id: String, title: String, number: Int, url: String, owner: String? = nil, statusField: StatusField? = nil, items: [ProjectItem] = []) {
        self.id = id
        self.title = title
        self.number = number
        self.url = url
        self.owner = owner
        self.statusField = statusField
        self.items = items
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusOptions: [StatusOption] {
        statusField?.options ?? []
    }

    func items(forStatus status: String?) -> [ProjectItem] {
        items.filter { $0.status == status }
    }

    func itemCount(forStatus status: String) -> Int {
        items.filter { $0.status == status }.count
    }

    var noStatusItems: [ProjectItem] {
        items.filter { $0.status == nil }
    }

    var statusCounts: [(status: StatusOption, count: Int)] {
        statusOptions.map { option in
            (option, itemCount(forStatus: option.name))
        }
    }
}

struct ProjectsListResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let viewer: Viewer
    }

    struct Viewer: Codable {
        let projectsV2: ProjectsConnection
        let organizations: OrganizationsConnection?
    }

    struct OrganizationsConnection: Codable {
        let nodes: [OrganizationNode]
    }

    struct OrganizationNode: Codable {
        let login: String
        let projectsV2: ProjectsConnection
    }

    struct ProjectsConnection: Codable {
        let nodes: [ProjectNode]
    }

    struct ProjectNode: Codable {
        let id: String
        let title: String
        let number: Int
        let url: String
    }
}

struct ProjectDetailResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let node: ProjectNode
    }

    struct ProjectNode: Codable {
        let title: String
        let fields: FieldsConnection
        let items: ItemsConnection
    }

    struct FieldsConnection: Codable {
        let nodes: [FieldNode]
    }

    struct FieldNode: Codable {
        let id: String?
        let name: String?
        let options: [OptionNode]?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case options
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            options = try container.decodeIfPresent([OptionNode].self, forKey: .options)
        }
    }

    struct OptionNode: Codable {
        let id: String
        let name: String
        let color: String
    }

    struct ItemsConnection: Codable {
        let nodes: [ItemNode]
    }

    struct ItemNode: Codable {
        let id: String
        let content: ItemContent?
        let fieldValueByName: FieldValue?

        struct ItemContent: Codable {
            let typename: String
            let title: String
            let number: Int?
            let url: String?
            let state: String?
            let assignees: AssigneesConnection?
            let closedByPullRequestsReferences: PRConnection?

            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case title
                case number
                case url
                case state
                case assignees
                case closedByPullRequestsReferences
            }
        }

        struct AssigneesConnection: Codable {
            let nodes: [AssigneeNode]
        }

        struct AssigneeNode: Codable {
            let login: String
            let avatarUrl: String
            let name: String?
        }

        struct PRConnection: Codable {
            let nodes: [PRNode]
        }

        struct PRNode: Codable {
            let number: Int
            let title: String
            let url: String
            let merged: Bool
            let closed: Bool
        }

        struct FieldValue: Codable {
            let name: String?
            let optionId: String?
        }
    }
}

struct UserSearchResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let search: SearchConnection
    }

    struct SearchConnection: Codable {
        let nodes: [UserNode]
    }

    struct UserNode: Codable {
        let login: String?
        let avatarUrl: String?
        let name: String?
    }
}

struct GetUserResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let user: UserNode?
    }

    struct UserNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String
        let name: String?
    }
}
