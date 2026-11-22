import AppKit
import Foundation
import GuardCore

func printUsage() {
    print("""
    lol-guard - Lightweight 24/7 macOS app & lobby guard

    Usage:
      lol-guard [options]

    Options:
      --config <path>   Path to JSON config (default: ~/.config/lol-guard/config.json)
      --once            Run a single check and exit
      --dry-run         Log actions without hiding or terminating processes
      --status          Print current status and exit
      --help, -h        Show this help message
    """)
}

var configPath = defaultConfigPath()
var runOnce = false
var dryRun = false
var showStatus = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--config":
        guard let val = args.next() else {
            fputs("Error: --config requires a path\n", stderr)
            exit(1)
        }
        configPath = val
    case "--once":
        runOnce = true
    case "--dry-run":
        dryRun = true
    case "--status":
        showStatus = true
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        fputs("Unknown argument: \(arg)\n", stderr)
        printUsage()
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let guardService = LoLGuard(configPath: configPath, dryRun: dryRun)

if showStatus {
    guardService.printStatus()
    exit(0)
}

if runOnce {
    guardService.evaluateOnce()
    exit(0)
}

guardService.startDaemon()
RunLoop.main.run()
