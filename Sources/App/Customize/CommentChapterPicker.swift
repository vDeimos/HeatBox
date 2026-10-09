// CommentChapterPicker.swift: choose which comment's chapter list to use.
//
// Finding the lists is the engine's (`CommentChapters.find`); the download
// later finds the picked comment again by its id.

import Engine
import SwiftUI

struct CommentChapterPicker: View {
    @ObservedObject var model: DownloadModel
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chapters from a comment")
                    .font(p.font(15, .semibold))
                    .foregroundColor(p.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            RowDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.commentsLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading the top comments…")
                                .font(p.font(13))
                                .foregroundColor(p.subtext)
                        }
                    } else if let problem = model.comments?.problem {
                        Text(problem)
                            .font(p.font(13))
                            .foregroundColor(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let found = model.comments {
                        Grouped {
                            choice(id: nil, title: "Choose for me",
                                   line: "The longest list, then the most liked, at the time of the download.", chapters: [])
                            ForEach(found.candidates) { candidate in
                                RowDivider()
                                choice(id: candidate.id, title: candidate.author,
                                       line: Messages.commentPickerLine(chapters: candidate.chapters.count, likes: candidate.likes),
                                       chapters: candidate.chapters)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            HStack {
                Spacer()
                Button("Done") { model.closePanel() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .frame(width: 620, height: 520)
        .background(p.base)
    }

    private func choice(id: String?, title: String, line: String, chapters: [CommentChapter]) -> some View {
        let on = model.draft?.chapterComment == id
        return Button {
            model.draft?.chapterComment = id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RadioMark(on: on).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(p.font(13, .semibold))
                        .foregroundColor(p.text)
                    Text(line)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                    if !chapters.isEmpty {
                        Text(chapters.prefix(6).map { "\(TimeText.clock($0.start))  \($0.title)" }.joined(separator: "\n")
                             + (chapters.count > 6 ? "\n…" : ""))
                            .font(p.mono(11))
                            .foregroundColor(p.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(7)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(line)")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : [.isButton])
    }
}
