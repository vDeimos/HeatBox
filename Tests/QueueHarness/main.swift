import Engine
import Foundation

// A stand-in for the app, for one integration test: it starts a real queue
// with the real tools, adds one link, says "downloading" once data is
// arriving, and then stays alive until it is killed. The test kills it
// outright (as a crash or a forced quit would) and checks what the next
// launch finds. Usage: QueueHarness <support folder> <destination folder> <link>

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: QueueHarness <support folder> <destination folder> <link>\n".utf8))
    exit(2)
}
setvbuf(stdout, nil, _IONBF, 0)

let paths = AppPaths(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
let settings = QueueSettings(folders: FolderRules(mainFolder: arguments[2], audioFolder: arguments[2]))
let queue = JobQueue(paths: paths, worker: ToolJobWorker(tools: ToolRegistry()), settings: settings)
let link = arguments[3]

Task {
    await queue.restore()
    let id = await queue.add(JobRequest.links([link], preset: PresetCatalog.best)[0])
    print("added \(id.uuidString)")
    var announced = false
    for await jobs in await queue.updates() {
        guard let job = jobs.first(where: { $0.id == id }) else { continue }
        if !announced, case .running(.downloading) = job.state, (job.progress.fraction ?? 0) > 0.1 {
            announced = true
            print("downloading")
        }
        if !job.state.isUnfinished { print("ended \(job.state) \(job.message)") }
    }
}
dispatchMain()
