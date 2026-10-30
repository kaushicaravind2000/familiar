import Foundation

/// `fam guard <parent-pid> <program> <arguments>…`: runs <program> as a child and stops it when the parent process
/// exits, however it exits. The app starts its llama-server helpers through this, so a crash or a force quit doesn't
/// leave a model of up to ~2.7 GB running until the next launch. macOS has no "die with my parent" switch, so the
/// guard watches the parent (kqueue, through a dispatch source) and passes SIGTERM and SIGINT on to the child.
func runGuard(_ arguments: [String]) -> Never {
    guard arguments.count >= 2, let parent = pid_t(arguments[0]) else {
        FileHandle.standardError.write(Data("usage: fam guard <parent-pid> <program> [arguments…]\n".utf8))
        exit(2)
    }
    let program = arguments[1]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.dropFirst(1).map { strdup($0) }
    argv.append(nil)
    var child: pid_t = 0
    let spawned = posix_spawn(&child, program, nil, nil, argv, environ)   // stdout and stderr are inherited
    guard spawned == 0 else {
        FileHandle.standardError.write(Data("fam guard: can't start \(program) (\(spawned))\n".utf8))
        exit(1)
    }

    var stopping = false
    func stopChild() {
        guard !stopping else { return }
        stopping = true
        kill(child, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { kill(child, SIGKILL) }   // if it doesn't go quietly
    }
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { stopChild() }
        source.resume()
        return source
    }
    let parentGone = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    parentGone.setEventHandler { stopChild() }
    parentGone.resume()
    if kill(parent, 0) != 0 { stopChild() }   // gone before the watch started
    let childGone = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
    childGone.setEventHandler {
        var status: Int32 = 0
        waitpid(child, &status, 0)
        exit((status >> 8) & 0xff)
    }
    childGone.resume()
    withExtendedLifetime((signals, parentGone, childGone)) { dispatchMain() }
}
