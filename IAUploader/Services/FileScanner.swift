import Foundation

struct ScannedFile: Sendable, Hashable {
    let url: URL
    let rootName: String?
    let relativePath: String
    let byteSize: Int64
}

struct FileScanResult: Sendable {
    var files: [ScannedFile] = []
    var unreadable: [String] = []
}

enum FileScanner {
    /// Recursively expands files and folders into upload candidates.
    /// Folders keep their own name as the first path component so that the
    /// structure of a dropped directory is preserved in the item, exactly
    /// like `webkitRelativePath` in a browser directory upload.
    static func scan(urls: [URL], includeHidden: Bool) -> FileScanResult {
        let fileManager = FileManager.default
        var result = FileScanResult()

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let resourceValues = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])

            if resourceValues?.isDirectory == true {
                let rootName = standardizedURL.lastPathComponent
                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey]
                let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                guard let enumerator = fileManager.enumerator(
                    at: standardizedURL,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: { _, _ in true }
                ) else {
                    result.unreadable.append(rootName)
                    continue
                }

                let basePath = standardizedURL.path
                for case let child as URL in enumerator {
                    let standardizedChild = child.standardizedFileURL
                    let childValues = try? standardizedChild.resourceValues(forKeys: Set(keys))
                    if childValues?.isSymbolicLink == true { continue }
                    guard childValues?.isRegularFile == true else { continue }
                    if standardizedChild.lastPathComponent == ".DS_Store" { continue }
                    if childValues?.isHidden == true && !includeHidden { continue }

                    let childPath = standardizedChild.path
                    let relative: String
                    if childPath.hasPrefix(basePath + "/") {
                        relative = String(childPath.dropFirst(basePath.count + 1))
                    } else {
                        relative = standardizedChild.lastPathComponent
                    }
                    result.files.append(ScannedFile(
                        url: child,
                        rootName: rootName,
                        relativePath: "\(rootName)/\(relative)",
                        byteSize: Int64(childValues?.fileSize ?? 0)
                    ))
                }
            } else if resourceValues?.isRegularFile == true {
                result.files.append(ScannedFile(
                    url: url,
                    rootName: nil,
                    relativePath: url.lastPathComponent,
                    byteSize: Int64(resourceValues?.fileSize ?? 0)
                ))
            } else {
                result.unreadable.append(url.lastPathComponent)
            }
        }

        result.files.sort { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        return result
    }
}
