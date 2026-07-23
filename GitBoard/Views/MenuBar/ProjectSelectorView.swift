import SwiftUI

struct ProjectSelectorView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        Picker("Project", selection: Binding(
            get: { store.selectedProjectId ?? "" },
            set: { newValue in
                if let project = store.projects.first(where: { $0.id == newValue }) {
                    Task {
                        await store.selectProject(project)
                    }
                }
            }
        )) {
            ForEach(store.projects) { project in
                HStack {
                    Text(project.title)
                    if let owner = project.owner {
                        Text(owner)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(project.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(store.isLoading)
    }
}