import Foundation
import JournalData
import JournalDomain
import JournalGroups
import PilgrimAPI

/// Group prayer lines imported from a prayer note keep their answered mark in step with the
/// topic: the journal's toggle marks the group line, the author's mark in the post detail
/// marks the topic, and a feed refresh pushes the journal's state where the two differ. The
/// links stay on the device (`GroupPrayerLinkStore`); the server only ever gets the marks.
extension AppModel {
    /// What the group composer imports from: my prayer notes, newest first.
    var groupPrayerNoteSource: GroupPrayerNoteSource {
        GroupPrayerNoteSource(
            notes: { [weak self] in self?.groupPrayerNotes() ?? [] },
            didPost: { [weak self] post, sources in
                self?.linkPostedPrayerItems(post, sources: sources)
            })
    }

    func groupPrayerNotes() -> [GroupPrayerNote] {
        ((try? allPrayerEntries()) ?? [])
            .map(GroupPrayerNote.init)
            .filter { !$0.sections.isEmpty }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func linkPostedPrayerItems(_ post: PostResponse, sources: [Int: GroupPrayerTopicSource]) {
        groupPrayerLinks.add(
            sources.sorted { $0.key < $1.key }.map { index, source in
                GroupPrayerLink(
                    postID: post.id, groupID: post.groupId, itemIndex: index,
                    entryID: source.entryID, topicID: source.topicID, expiresAt: post.expiresAt)
            })
    }

    /// Called when `groups` is set.
    func connectGroupPrayerLinks() {
        groups?.onFeedRefreshed = { [weak self] posts in self?.catchUpGroupPrayerLinks(posts) }
        groups?.onPrayerItemAnswered = { [weak self] post, index in
            self?.applyGroupPrayerItemAnswered(post, index: index)
        }
    }

    /// Journal → group: marks every live group line imported from the topic.
    func pushPrayerTopicStatus(entryID: UUID, topicID: UUID, status: PrayerStatus) {
        let links = groupPrayerLinks.links().filter {
            $0.entryID == entryID && $0.topicID == topicID
        }
        pushAnswered(links.map { ($0, status == .answered) })
    }

    /// Group → journal: the author marked line `index` of `post`; the linked topic follows
    /// without another call for that line (lines of the same topic in other posts do follow).
    func applyGroupPrayerItemAnswered(_ post: PostResponse, index: Int) {
        guard let items = post.items, items.indices.contains(index) else { return }
        let answered = items[index].answeredAt != nil
        let links = groupPrayerLinks.links()
        for link in links where link.postID == post.id && link.itemIndex == index {
            setPrayerTopicStatus(
                entryID: link.entryID, topicID: link.topicID,
                status: answered ? .answered : .ongoing, syncsGroups: false)
            pushAnswered(
                links.filter {
                    $0.entryID == link.entryID && $0.topicID == link.topicID
                        && $0.postID != post.id
                }.map { ($0, answered) })
        }
        groupPrayerLinks.updateExpiry(postID: post.id, to: post.expiresAt)
    }

    /// Catch-up after a feed refresh: a linked line of mine whose topic is answered in the
    /// journal but not in the group gets marked. Only that direction: another device's mark in
    /// the group may reach this device's journal (CloudKit) after the group does, and catching
    /// up the other way would undo it. Un-marking goes through the journal toggle itself.
    /// Only my posts with links are looked at; the calls run off the feed.
    func catchUpGroupPrayerLinks(_ posts: [PostResponse]) {
        let mine = posts.filter(\.isMine)
        guard !mine.isEmpty else { return }
        let links = groupPrayerLinks.links()
        guard !links.isEmpty else { return }
        var pushes: [(GroupPrayerLink, Bool)] = []
        for post in mine {
            let postLinks = links.filter { $0.postID == post.id }
            guard !postLinks.isEmpty, let items = post.items else { continue }
            groupPrayerLinks.updateExpiry(postID: post.id, to: post.expiresAt)
            for link in postLinks where items.indices.contains(link.itemIndex) {
                guard let record = try? repository.entry(id: link.entryID),
                    record.deletedAt == nil,
                    let topic = record.details.prayerTopics?.first(where: { $0.id == link.topicID })
                else { continue }
                if topic.status == .answered, items[link.itemIndex].answeredAt == nil {
                    pushes.append((link, true))
                }
            }
        }
        pushAnswered(pushes)
    }

    /// Best effort: a failed call is fixed by the next catch-up.
    private func pushAnswered(_ pushes: [(link: GroupPrayerLink, answered: Bool)]) {
        guard let api = groups?.api, !pushes.isEmpty else { return }
        let previous = groupPrayerSyncTask
        groupPrayerSyncTask = Task { [weak self] in
            await previous?.value
            for (link, answered) in pushes {
                guard
                    let post = try? await api.setPrayerItemAnswered(
                        postID: link.postID, index: link.itemIndex, answered: answered)
                else { continue }
                self?.groupPrayerLinks.updateExpiry(postID: post.id, to: post.expiresAt)
                GroupContentEvents.shared.send(.postUpdated(post))
            }
        }
    }
}
