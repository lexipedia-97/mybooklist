import SwiftUI
import Foundation

private let googleBooksAPIKey = "AIzaSyCpjQE9c-O_U8EcBmUTSw-0Pkh4szAumeY"

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var savedEntries: [String: ReadingEntry] = [:]
    @State private var selectedEntry: ReadingEntry?
    @State private var entryPendingDeletion: ReadingEntry?
    @State private var isConfirmingDeletion = false
    @State private var isShowingSearch = false
    @State private var message: String?

    private let readingStore = ReadingLocalStore()

    private var sortedEntries: [ReadingEntry] {
        savedEntries.values.sorted { first, second in
            first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if sortedEntries.isEmpty {
                    ContentUnavailableView {
                        Label("Sua lista esta vazia", systemImage: "books.vertical")
                    } description: {
                        Text("Adicione livros pela busca para acompanhar seu progresso de leitura.")
                    } actions: {
                        Button("Buscar livros") {
                            isShowingSearch = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(sortedEntries) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            ReadingEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                entryPendingDeletion = entry
                                isConfirmingDeletion = true
                            } label: {
                                Label("Excluir", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Minha Leitura")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSearch = true
                    } label: {
                        Label("Buscar", systemImage: "plus")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding()
                }
            }
            .task {
                loadSavedEntries()
            }
            .refreshable {
                loadSavedEntries()
            }
            .sheet(isPresented: $isShowingSearch) {
                BookSearchView(savedEntries: savedEntries) { entry in
                    save(entry, showsSuccessMessage: true)
                }
            }
            .sheet(item: $selectedEntry) { entry in
                BookDetailView(book: entry.book, initialEntry: entry, saveButtonTitle: "Salvar") { updatedEntry in
                    save(updatedEntry, showsSuccessMessage: true)
                }
            }
            .confirmationDialog(
                "Excluir livro da lista?",
                isPresented: $isConfirmingDeletion,
                titleVisibility: .visible,
                presenting: entryPendingDeletion
            ) { entry in
                Button("Excluir \"\(entry.title)\"", role: .destructive) {
                    confirmDeletion(of: entry)
                }

                Button("Cancelar", role: .cancel) {
                    entryPendingDeletion = nil
                }
            } message: { _ in
                Text("Esta acao remove o livro e sua opiniao deste dispositivo.")
            }
        }
    }

    private func loadSavedEntries() {
        savedEntries = readingStore.fetchEntries()
    }

    private func save(_ entry: ReadingEntry, showsSuccessMessage: Bool) {
        savedEntries[entry.bookID] = entry
        readingStore.saveEntries(savedEntries)

        if showsSuccessMessage {
            Task {
                await showTemporaryMessage("Livro salvo.")
            }
        }
    }

    private func confirmDeletion(of entry: ReadingEntry) {
        savedEntries.removeValue(forKey: entry.bookID)
        readingStore.saveEntries(savedEntries)
        entryPendingDeletion = nil
        selectedEntry = nil

        Task {
            await showTemporaryMessage("Livro excluido da lista.")
        }
    }

    private func showTemporaryMessage(_ text: String) async {
        message = text
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled {
            message = nil
        }
    }
}

struct BookSearchView: View {
    let savedEntries: [String: ReadingEntry]
    let onSave: (ReadingEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var books: [Book] = []
    @State private var selectedBook: Book?
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let googleBooksService = GoogleBooksService()

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Busque um livro",
                        systemImage: "magnifyingglass",
                        description: Text("Digite o titulo ou autor para pesquisar no Google Books.")
                    )
                } else if isSearching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Buscando livros")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                } else if books.isEmpty {
                    ContentUnavailableView(
                        "Nenhum livro encontrado",
                        systemImage: "books.vertical",
                        description: Text("Tente procurar por outro titulo ou autor.")
                    )
                } else {
                    ForEach(books) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            BookRow(book: book, entry: savedEntries[book.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Buscar Livros")
            .searchable(text: $searchText, prompt: "Buscar livros")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding()
                }
            }
            .task(id: searchText) {
                await searchBooks()
            }
            .sheet(item: $selectedBook) { book in
                BookDetailView(book: book, initialEntry: savedEntries[book.id], saveButtonTitle: savedEntries[book.id] == nil ? "Adicionar" : "Salvar") { entry in
                    onSave(entry)
                }
            }
        }
    }

    private func searchBooks() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            books = []
            isSearching = false
            errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil

        do {
            try await Task.sleep(for: .milliseconds(350))
            let results = try await googleBooksService.searchBooks(matching: query)
            guard !Task.isCancelled else { return }
            books = results.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch is CancellationError {
            return
        } catch {
            books = []
            errorMessage = "Nao foi possivel buscar agora."
        }

        isSearching = false
    }
}

struct ReadingEntryRow: View {
    let entry: ReadingEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(url: entry.thumbnailURL)
                .frame(width: 54, height: 78)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)

                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Label(entry.status.rawValue, systemImage: entry.status.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(entry.status.tint)

                if !entry.opinion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.opinion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct BookRow: View {
    let book: Book
    let entry: ReadingEntry?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(url: book.thumbnailURL)
                .frame(width: 54, height: 78)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let publishedYear = book.publishedYear {
                    Text(publishedYear)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let entry {
                    Label(entry.status.rawValue, systemImage: entry.status.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.status.tint)
                }
            }

            Spacer(minLength: 8)

            if entry != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Ja esta na lista")
            }
        }
        .padding(.vertical, 6)
    }
}

struct BookDetailView: View {
    let book: Book
    let saveButtonTitle: String
    let onSave: (ReadingEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: ReadingStatus
    @State private var opinion: String
    @State private var isSaving = false

    init(book: Book, initialEntry: ReadingEntry?, saveButtonTitle: String, onSave: @escaping (ReadingEntry) -> Void) {
        self.book = book
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        _status = State(initialValue: initialEntry?.status ?? .pending)
        _opinion = State(initialValue: initialEntry?.opinion ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        BookCover(url: book.thumbnailURL)
                            .frame(width: 78, height: 116)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.title)
                                .font(.title3.weight(.semibold))

                            if !book.authors.isEmpty {
                                Text(book.authors.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }

                            if let publishedYear = book.publishedYear {
                                Text(publishedYear)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Status da leitura") {
                    Picker("Status", selection: $status) {
                        ForEach(ReadingStatus.allCases) { status in
                            Label(status.rawValue, systemImage: status.systemImage)
                                .tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Opiniao") {
                    TextField("Escreva sua opiniao sobre o livro", text: $opinion, axis: .vertical)
                        .lineLimit(4...12)
                }
            }
            .navigationTitle("Livro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSaving = true
                        onSave(makeEntry())
                        isSaving = false
                        dismiss()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(saveButtonTitle)
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func makeEntry() -> ReadingEntry {
        ReadingEntry(
            bookID: book.id,
            title: book.title,
            authors: book.authors,
            publishedYear: book.publishedYear,
            thumbnailURL: book.thumbnailURL,
            status: status,
            opinion: opinion,
            updatedAt: Date()
        )
    }
}

struct BookCover: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "book.closed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct Book: Identifiable, Hashable {
    let id: String
    let title: String
    let authors: [String]
    let publishedYear: String?
    let thumbnailURL: URL?
}

enum ReadingStatus: String, CaseIterable, Identifiable, Codable {
    case pending = "Pendente"
    case reading = "Lendo"
    case finished = "Finalizado"
    case abandoned = "Abandonado"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pending: "clock"
        case .reading: "book.pages"
        case .finished: "checkmark.circle"
        case .abandoned: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .orange
        case .reading: .blue
        case .finished: .green
        case .abandoned: .red
        }
    }
}

struct ReadingEntry: Identifiable, Hashable, Codable {
    var id: String { bookID }
    let bookID: String
    let title: String
    let authors: [String]
    let publishedYear: String?
    let thumbnailURL: URL?
    var status: ReadingStatus
    var opinion: String
    var updatedAt: Date
}

struct GoogleBooksService {
    func searchBooks(matching query: String) async throws -> [Book] {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "30"),
            URLQueryItem(name: "printType", value: "books"),
            URLQueryItem(name: "key", value: googleBooksAPIKey)
        ]

        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
        return payload.items.map(\.book).filter { !$0.title.isEmpty }
    }
}

struct ReadingLocalStore {
    private let storageKey = "readingEntries"

    func fetchEntries() -> [String: ReadingEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }

        do {
            let entries = try JSONDecoder().decode([ReadingEntry].self, from: data)
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.bookID, $0) })
        } catch {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return [:]
        }
    }

    func saveEntries(_ entries: [String: ReadingEntry]) {
        do {
            let sortedEntries = entries.values.sorted { first, second in
                first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
            }
            let data = try JSONEncoder().encode(sortedEntries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            assertionFailure("Could not save reading entries locally: \(error.localizedDescription)")
        }
    }
}

private extension ReadingEntry {
    var book: Book {
        Book(
            id: bookID,
            title: title,
            authors: authors,
            publishedYear: publishedYear,
            thumbnailURL: thumbnailURL
        )
    }
}

struct GoogleBooksResponse: Decodable {
    let items: [GoogleBookItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([GoogleBookItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

struct GoogleBookItem: Decodable {
    let id: String
    let volumeInfo: VolumeInfo

    var book: Book {
        Book(
            id: id,
            title: volumeInfo.title ?? "",
            authors: volumeInfo.authors ?? [],
            publishedYear: volumeInfo.publishedDate?.prefix(4).description,
            thumbnailURL: volumeInfo.imageLinks?.bestURL
        )
    }
}

struct VolumeInfo: Decodable {
    let title: String?
    let authors: [String]?
    let publishedDate: String?
    let imageLinks: ImageLinks?
}

struct ImageLinks: Decodable {
    let smallThumbnail: String?
    let thumbnail: String?

    var bestURL: URL? {
        let rawURL = thumbnail ?? smallThumbnail
        let secureURL = rawURL?.replacingOccurrences(of: "http://", with: "https://")
        return secureURL.flatMap(URL.init(string:))
    }
}

#Preview {
    ContentView()
}

