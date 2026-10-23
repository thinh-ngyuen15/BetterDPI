import AppKit

if CommandLine.arguments.count > 1 {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
} else {
    BetterDPIApp.main()
}
