import AppKit
import MogoCore
import SwiftUI

/// 평가원 수능 홈페이지에서 시험지를 받아 목록에 넣는 창.
/// 1단계: 시험·학년도·영역 고르기 → 받기. 2단계(고를 게 있을 때만): 받은 파일 중 목록에 넣을 것 고르기.
struct KICEDownloadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var exam: KICEExam = .suneung
    @State private var years: [Int] = []
    @State private var year: Int?
    @State private var rows: [KICERow] = []
    @State private var checked: Set<String> = []
    @State private var includeAnswers = false
    @State private var loading = false
    @State private var error: String?
    @State private var progress: String?
    /// 2단계: 받은 파일과 고른 파일
    @State private var results: [Downloaded] = []
    @State private var picked: Set<URL> = []
    /// 최신 학년도에 아직 시험지가 없으면 한 해 앞으로 한 번만 옮긴다.
    @State private var autoStepped = false

    struct Downloaded: Identifiable, Hashable {
        let url: URL
        let area: String
        let isAnswer: Bool
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/모고 프린트", isDirectory: true)

    private struct RowsKey: Hashable { let exam: KICEExam; let year: Int? }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("평가원 기출 받기").font(.title2.bold())
            if results.isEmpty { chooseView } else { pickView }
        }
        .padding(22)
        .frame(width: 540, height: 560)
        .task(id: exam) { await loadYears() }
        .task(id: RowsKey(exam: exam, year: year)) { await loadRows() }
    }

    // MARK: 1단계

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("시험", selection: $exam) {
                    ForEach(KICEExam.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                Picker("학년도", selection: $year) {
                    ForEach(years, id: \.self) { Text("\(String($0))학년도").tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(years.isEmpty)
            }

            Group {
                if loading {
                    ProgressView("평가원 홈페이지에서 목록을 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("다시 시도") { Task { await loadYears() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    Text("이 시험은 아직 올라온 시험지가 없어요.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { row in
                        Toggle(isOn: Binding(
                            get: { checked.contains(row.area) },
                            set: { if $0 { checked.insert(row.area) } else { checked.remove(row.area) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.area)
                                Text(row.papers.map(\.title).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(maxHeight: .infinity)

            Toggle("정답표도 받기", isOn: $includeAnswers)
            Text("받은 파일은 다운로드 폴더의 '모고 프린트' 폴더에 저장돼요. 시험지 저작권은 한국교육과정평가원에 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("받기") { Task { await download() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty || progress != nil || loading)
            }
        }
    }

    // MARK: 2단계

    private var pickView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("목록에 넣을 파일을 고르세요").font(.headline)
            Text("탐구는 응시할 과목만 고르면 돼요. 받은 파일은 모두 다운로드 폴더에 남아 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(areas(of: results), id: \.self) { area in
                    Section(area) {
                        ForEach(results.filter { $0.area == area }) { item in
                            Toggle(isOn: Binding(
                                get: { picked.contains(item.url) },
                                set: { if $0 { picked.insert(item.url) } else { picked.remove(item.url) } }
                            )) {
                                Text(item.name + (item.isAnswer && !item.name.contains("정답") ? " (정답)" : ""))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            HStack {
                Button("Finder에서 보기") {
                    if let y = year { NSWorkspace.shared.activateFileViewerSelecting([KICEArchive.folder(exam, year: y, base: Self.baseDir)]) }
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("목록에 추가") {
                    model.add(urls: results.filter { picked.contains($0.url) }.map(\.url), keepOrder: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty)
            }
        }
    }

    private func areas(of items: [Downloaded]) -> [String] {
        var out: [String] = []
        for i in items where !out.contains(i.area) { out.append(i.area) }
        return out
    }

    // MARK: 불러오기·받기

    private func loadYears() async {
        loading = true
        error = nil
        autoStepped = false
        do {
            years = try await KICEArchive.years(exam)
            if year == nil || !years.contains(year!) { year = years.first }
        } catch {
            self.error = "평가원 홈페이지에 연결하지 못했어요.\n인터넷 연결을 확인한 뒤 다시 시도하세요."
            loading = false
        }
    }

    private func loadRows() async {
        guard let y = year else { return }
        loading = true
        error = nil
        do {
            let found = try await KICEArchive.rows(exam, year: y)
            // 최신 학년도에 아직 시험지가 없으면(예: 시험 전) 한 해 앞으로 옮긴다.
            if found.isEmpty, !autoStepped, y == years.first, years.count > 1 {
                autoStepped = true
                year = years[1]
                return
            }
            rows = found
            checked = Set(found.map(\.area).filter { ["국어", "수학", "영어", "한국사"].contains($0) })
        } catch {
            rows = []
            self.error = "목록을 불러오지 못했어요: \(error.localizedDescription)"
        }
        loading = false
    }

    private func download() async {
        guard let y = year else { return }
        let dir = KICEArchive.folder(exam, year: y, base: Self.baseDir)
        var got: [Downloaded] = []
        var manySubjects = Set<String>()
        do {
            for row in rows where checked.contains(row.area) {
                if row.hasManySubjects { manySubjects.insert(row.area) }
                for a in row.papers + (includeAnswers ? row.answers : []) {
                    progress = "\(row.area) 받는 중…"
                    let saved = try await KICEArchive.save(a, exam: exam, year: y, to: dir)
                    got += saved.map { Downloaded(url: $0, area: row.area, isAnswer: a.kind == .answer) }
                }
            }
        } catch {
            progress = nil
            self.error = "받지 못했어요: \(error.localizedDescription)"
            return
        }
        progress = nil

        let defaults = KICEArchive.preselect(got.map { ($0.url, $0.area) }, manySubjectAreas: manySubjects,
                                             variant: model.options.variant)
        if defaults.count == got.count {
            model.add(urls: got.map(\.url), keepOrder: true)
            dismiss()
        } else {
            picked = defaults
            results = got
        }
    }
}
