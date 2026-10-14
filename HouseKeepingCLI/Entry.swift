import SweepCLI

/// The `housekeeping` binary bundled in House Keeping.app/Contents/Helpers. All commands live in SweepKit's SweepCLI.
@main
struct Entry {
    static func main() async {
        await SweepCommand.main()
    }
}
