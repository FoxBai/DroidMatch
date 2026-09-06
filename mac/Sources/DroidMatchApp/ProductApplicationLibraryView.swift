import DroidMatchCore
import DroidMatchPresentation
import SwiftUI

struct ProductApplicationLibraryView: View {
    @ObservedObject var model: ApplicationLibraryModel
    @State private var searchText = ""
    @State private var viewID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppStrings.applications).font(.largeTitle.bold())
                    Text(AppStrings.applicationsDetail).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refresh) {
                    Label(AppStrings.refresh, systemImage: "arrow.clockwise")
                }.disabled(model.isBusy)
            }
            HStack {
                TextField(AppStrings.searchApplications, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !model.isBusy { model.search(searchText) } }
                Button(AppStrings.searchApplicationsAction) { model.search(searchText) }
                    .disabled(model.isBusy)
                Picker(AppStrings.applicationSort, selection: Binding(
                    get: { model.query.sortOrder }, set: { model.sort($0) })) {
                    Text(AppStrings.sortByName).tag(ApplicationLibrarySortOrder.name)
                    Text(AppStrings.recentlyUpdated).tag(ApplicationLibrarySortOrder.recentlyUpdated)
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(model.isBusy)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.phase == .ready {
                HStack {
                    Text(String(format: AppStrings.applicationCount,
                                String(model.entries.count), String(model.totalCount)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isLoadingMore { ProgressView().controlSize(.small) }
                    if model.hasMore {
                        Button(AppStrings.loadMore, action: model.loadMore).disabled(model.isBusy)
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle(AppStrings.applications)
        .onAppear {
            searchText = model.query.searchQuery
            model.attach(viewID: viewID)
        }
        .onDisappear { model.detach(viewID: viewID) }
        .onChange(of: model.query.searchQuery) { searchText = $0 }
    }

    @ViewBuilder private var content: some View {
        if model.phase == .loading || model.phase == .idle {
            ProgressView(AppStrings.loadingApplications)
        } else if let failure = model.failure {
            message(symbol: failure == .permissionRequired ? "lock.shield" : "app.badge",
                    title: failureTitle(failure), detail: failureDetail(failure))
        } else if model.entries.isEmpty {
            message(symbol: "app.dashed", title: AppStrings.noApplications,
                    detail: AppStrings.noApplicationsDetail)
        } else {
            List(model.entries) { entry in
                HStack(spacing: 14) {
                    Image(systemName: entry.isSystemApplication ? "gearshape" : "app")
                        .font(.title2).foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.displayName).font(.headline).lineLimit(1)
                            if entry.isSystemApplication {
                                Text(AppStrings.system).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.packageIdentifier).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(entry.versionName.isEmpty
                             ? String(format: AppStrings.applicationBuild, String(entry.versionCode))
                             : String(format: AppStrings.applicationVersion,
                                      entry.versionName, String(entry.versionCode)))
                            .font(.caption).lineLimit(1)
                        if let millis = entry.updatedUnixMillis {
                            HStack(spacing: 4) {
                                Text(AppStrings.applicationUpdated)
                                Text(Date(timeIntervalSince1970: Double(millis) / 1000), style: .date)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 7)
            }.listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: 420)
    }

    private func failureTitle(_ error: ApplicationLibraryError) -> String {
        switch error {
        case .permissionRequired: return AppStrings.applicationSharingOff
        case .unsupported: return AppStrings.applicationUpdateRequired
        case .refreshRequired: return AppStrings.applicationRefreshRequired
        case .invalidQuery: return AppStrings.applicationSearchInvalid
        default: return AppStrings.applicationsUnavailable
        }
    }

    private func failureDetail(_ error: ApplicationLibraryError) -> String {
        switch error {
        case .permissionRequired: return AppStrings.applicationSharingHelp
        case .unsupported: return AppStrings.applicationUpdateRequiredDetail
        case .refreshRequired: return AppStrings.applicationRefreshRequiredDetail
        case .invalidQuery: return AppStrings.applicationSearchInvalidDetail
        default: return AppStrings.applicationsUnavailableDetail
        }
    }
}
