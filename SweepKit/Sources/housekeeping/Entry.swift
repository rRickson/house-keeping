import SweepCLI

@main
struct Entry {
    static func main() async {
        await SweepCommand.main()
    }
}
