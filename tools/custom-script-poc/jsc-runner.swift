import Foundation
import JavaScriptCore
import Darwin

// Development probe only, not a production sandbox. The JS realm exports no file/network APIs.
// Inputs and the vendor bundle are read by the trusted host before executing a job.
guard CommandLine.arguments.count == 4 else { exit(64) }
let bundle = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let job = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let context = JSContext()!
var done = false
var output: String?
var exception: String?
context.exceptionHandler = { _, value in exception = value?.toString() }
let finish: @convention(block) (String) -> Void = { value in output = value; done = true }
context.setObject(finish, forKeyedSubscript: "__pocFinish" as NSString)
context.setObject(job, forKeyedSubscript: "__pocJobJSON" as NSString)
context.evaluateScript("globalThis.console={log(){},warn(){},error(){}}; globalThis.performance={now:()=>Date.now()};")
context.evaluateScript(bundle)
if let error = exception {
    print("{\"hostError\":\(String(data: try JSONEncoder().encode(error), encoding: .utf8)!)}")
    exit(1)
}
let runner = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
context.evaluateScript(runner)
// Watchdog is in the parent process; a stuck JS evaluate cannot block the app.
while !done && exception == nil {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
}
if let result = output { print(result) }
else {
    let error = exception ?? "Missing result"
    print("{\"hostError\":\(String(data: try JSONEncoder().encode(error), encoding: .utf8)!)}")
    exit(1)
}
