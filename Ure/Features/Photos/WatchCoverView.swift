import SwiftUI

struct WatchCoverView: View {
    @Environment(PhotoState.self) private var photos
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    private var choices: [PhotoRecord] {
        let jobIDs = Set(jobs.jobs.filter { $0.watchID == watch.id }.map(\.id))
        return photos.photos.filter { photo in
            if photo.item.watchID == watch.id { return true }
            if let jobID = photo.item.jobID { return jobIDs.contains(jobID) }
            return false
        }
    }

    var body: some View {
        Section("Watch cover") {
            if watch.coverPhotoID != nil {
                PhotoThumbnailView(photoID: watch.coverPhotoID).frame(height: 160)
            }
            Menu("Choose Cover") {
                ForEach(choices) { photo in WatchCoverOption(photo: photo, watchID: watch.id) }
            }
            .disabled(
                editing.isSaving || photos.isLoading || photos.loadError != nil
                    || jobs.isLoading || jobs.loadError != nil || choices.isEmpty)
            Button("Remove Cover", action: removeCover)
                .disabled(editing.isSaving || watch.coverPhotoID == nil)
            if let error = photos.operationError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private func removeCover() { photos.setCover(nil, for: watch.id) }
}

private struct WatchCoverOption: View {
    @Environment(PhotoState.self) private var photos
    let photo: PhotoRecord
    let watchID: UUID

    var body: some View {
        Button("\(photo.item.title) (\(photo.item.jobID == nil ? "Watch" : "Job"))", action: choose)
    }
    private func choose() { photos.setCover(photo.id, for: watchID) }
}
