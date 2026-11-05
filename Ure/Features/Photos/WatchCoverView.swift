import SwiftUI

// The watch cover is a photo from the watch's material or its jobs' material.
struct WatchCoverView: View {
    @Environment(MaterialState.self) private var material
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    private var choices: [MaterialRecord] {
        let jobIDs = Set(jobs.jobs.filter { $0.watchID == watch.id }.map(\.id))
        return material.records.filter { record in
            guard record.item.kind == .photo else { return false }
            if record.item.watchID == watch.id { return true }
            if let jobID = record.item.jobID { return jobIDs.contains(jobID) }
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
                watch.archivedAt != nil || editing.isSaving || material.isLoading
                    || material.loadError != nil
                    || jobs.isLoading || jobs.loadError != nil || choices.isEmpty)
            Button("Remove Cover", action: removeCover)
                .disabled(watch.archivedAt != nil || editing.isSaving || watch.coverPhotoID == nil)
        }
    }

    private func removeCover() { material.setCover(nil, for: watch.id) }
}

private struct WatchCoverOption: View {
    @Environment(MaterialState.self) private var material
    let photo: MaterialRecord
    let watchID: UUID

    var body: some View {
        Button("\(photo.item.title) (\(photo.item.jobID == nil ? "Watch" : "Job"))", action: choose)
    }
    private func choose() { material.setCover(photo.id, for: watchID) }
}
