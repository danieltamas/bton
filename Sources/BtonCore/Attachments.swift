import Foundation

extension Dispatcher {
    /// Writes each attachment into the job's scratch directory, as a new file and never through a
    /// link. A name that could leave the directory fails the job before the agent starts.
    static func attach(_ attachments: [String: String], in directory: URL) throws {
        for (name, text) in attachments {
            guard (1...64).contains(name.count), name != ".", name != "..",
                  name.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else { throw DispatchError.attachment(name) }
            let fd = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: Data(text.utf8))
            try file.close()
        }
    }

    /// The task for an agent without a system prompt of Bton's: the scratch directory its data
    /// files are in, and the code graph line, after the task in Bton's own words.
    static func told(_ prompt: String, scratch: String?, graphLine: String?) -> String {
        var lines = [prompt]
        if let scratch { lines.append("Your scratch directory is \(scratch): the data files this task names are there; put notes and temporary files there, not in /tmp.") }
        if let graphLine { lines.append(graphLine) }
        return lines.joined(separator: "\n\n")
    }
}
