import Foundation
import UniformTypeIdentifiers

/// The mediatypes accepted by the Internet Archive item metadata schema.
enum Mediatype: String, CaseIterable, Identifiable, Codable, Sendable {
    case texts
    case audio
    case movies
    case software
    case image
    case data
    case web
    case etree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .texts: return "Texts"
        case .audio: return "Audio"
        case .movies: return "Video"
        case .software: return "Software"
        case .image: return "Images"
        case .data: return "Data"
        case .web: return "Web"
        case .etree: return "Live Music"
        }
    }

    var symbol: String {
        switch self {
        case .texts: return "book.closed"
        case .audio: return "waveform"
        case .movies: return "film"
        case .software: return "shippingbox"
        case .image: return "photo"
        case .data: return "tablecells"
        case .web: return "globe"
        case .etree: return "music.mic"
        }
    }

    var summary: String {
        switch self {
        case .texts: return "Books, documents, PDFs, and other readable text."
        case .audio: return "Music, spoken word, podcasts, and other audio."
        case .movies: return "Video files, films, and recorded events."
        case .software: return "Applications, games, and source code."
        case .image: return "Photographs, artwork, and still images."
        case .data: return "Datasets, archives, and structured data."
        case .web: return "Web archives and saved sites (WARC/ARC)."
        case .etree: return "Live music recordings for the Live Music Archive."
        }
    }

    /// The collection used by archive.org's own upload form for this mediatype.
    /// Users can always override it; collection privileges are account-specific.
    var defaultCollection: String {
        switch self {
        case .texts: return "opensource"
        case .audio: return "opensource_audio"
        case .movies: return "opensource_movies"
        case .software: return "open_source_software"
        case .image: return "opensource_image"
        case .data: return "opensource_media"
        case .web: return "opensource_media"
        case .etree: return "etree"
        }
    }

    static func inferred(from urls: [URL]) -> Mediatype? {
        var votes: [Mediatype: Int] = [:]
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
            let mediatype: Mediatype
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                mediatype = .movies
            } else if type.conforms(to: .audio) {
                mediatype = .audio
            } else if type.conforms(to: .image) {
                mediatype = .image
            } else if type.conforms(to: .sourceCode) || type.conforms(to: .executable) {
                mediatype = .software
            } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
                mediatype = .data
            } else if type.conforms(to: .text) || type.conforms(to: .pdf) {
                mediatype = .texts
            } else if type.conforms(to: .html) || type.conforms(to: .xml) {
                mediatype = .web
            } else {
                continue
            }
            votes[mediatype, default: 0] += 1
        }
        return votes.max { lhs, rhs in lhs.value < rhs.value }?.key
    }
}

enum CollectionCatalog {
    /// Collections offered as suggestions in the metadata editor.
    static let suggestions: [(id: String, name: String)] = [
        ("opensource", "Community Texts"),
        ("opensource_audio", "Community Audio"),
        ("opensource_movies", "Community Video"),
        ("opensource_image", "Community Images"),
        ("opensource_media", "Community Data"),
        ("open_source_software", "Community Software"),
        ("etree", "Live Music Archive"),
        ("test_collection", "Test Collection (30 days)")
    ]
}

enum LanguageCatalog {
    static let languages: [(code: String, name: String)] = [
        ("eng", "English"), ("spa", "Spanish"), ("fra", "French"), ("deu", "German"),
        ("ita", "Italian"), ("por", "Portuguese"), ("nld", "Dutch"), ("rus", "Russian"),
        ("jpn", "Japanese"), ("zho", "Chinese"), ("ara", "Arabic"), ("hin", "Hindi"),
        ("ben", "Bengali"), ("kor", "Korean"), ("pol", "Polish"), ("swe", "Swedish"),
        ("nor", "Norwegian"), ("dan", "Danish"), ("fin", "Finnish"), ("tur", "Turkish"),
        ("ukr", "Ukrainian"), ("ell", "Greek"), ("heb", "Hebrew"), ("ces", "Czech"),
        ("hun", "Hungarian"), ("ron", "Romanian"), ("ind", "Indonesian"), ("vie", "Vietnamese"),
        ("tha", "Thai"), ("cat", "Catalan"), ("lat", "Latin"), ("san", "Sanskrit"),
        ("mul", "Multiple languages"), ("und", "Undetermined")
    ]
}

enum LicenseCatalog {
    static let licenses: [(name: String, url: String)] = [
        ("Creative Commons Zero (CC0 1.0)", "https://creativecommons.org/publicdomain/zero/1.0/"),
        ("Creative Commons BY 4.0", "https://creativecommons.org/licenses/by/4.0/"),
        ("Creative Commons BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/"),
        ("Creative Commons BY-NC 4.0", "https://creativecommons.org/licenses/by-nc/4.0/"),
        ("Creative Commons BY-NC-SA 4.0", "https://creativecommons.org/licenses/by-nc-sa/4.0/"),
        ("Creative Commons BY-ND 4.0", "https://creativecommons.org/licenses/by-nd/4.0/"),
        ("Creative Commons BY-NC-ND 4.0", "https://creativecommons.org/licenses/by-nc-nd/4.0/"),
        ("Public Domain Mark 1.0", "https://creativecommons.org/publicdomain/mark/1.0/")
    ]
}
