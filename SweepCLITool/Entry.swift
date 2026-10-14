import SweepCLI

/// The `sweep` binary bundled in Sweep.app/Contents/Helpers. All commands live in SweepKit's SweepCLI.
@main
struct Entry {
    static func main() async {
        await SweepCommand.main()
    }
}
